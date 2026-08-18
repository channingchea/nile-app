-- 0127 — P4 #38 from the 2026-08-16 platform review: notification preferences
-- with no quiet hours, and one toggle that exists in the database but was
-- never rendered.
--
-- `tip_received` has been on this table and honoured by notif_enabled() since
-- tipping shipped — the switch simply never made it into the screen. A host
-- taking tips through a three-hour show therefore gets a push per tip and no
-- way to stop it. That half is a client fix; this migration is the other half.
--
-- Quiet hours suppress the PUSH, not the notification. The row is still
-- written, so everything is waiting in the app when they look — what changes
-- is whether their phone lights up at 3am.
--
-- Timezone, honestly: we store a UTC offset in minutes rather than an IANA
-- zone, because getting a real IANA name out of Flutter needs a native plugin
-- and this is a comfort feature, not a billing one. The app refreshes the
-- offset whenever the notification screen is opened, so a DST change costs at
-- most one hour of drift until the next visit. If quiet hours ever gate
-- something that matters, replace this with a real zone.

alter table public.notification_preferences
  add column if not exists quiet_hours_start time,
  add column if not exists quiet_hours_end   time,
  add column if not exists quiet_hours_utc_offset_minutes integer not null default 0;

comment on column public.notification_preferences.quiet_hours_start is
  'Local wall-clock time push starts being held. NULL (with _end) = quiet hours off.';
comment on column public.notification_preferences.quiet_hours_utc_offset_minutes is
  'The user''s UTC offset in minutes when they last opened notification settings. Deliberately not an IANA zone — see migration 0127.';

-- Windows that wrap midnight are the normal case (22:00 → 07:00), so the
-- comparison has to handle start > end rather than assuming a simple between.
create or replace function public.in_quiet_hours(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
    when p.quiet_hours_start is null or p.quiet_hours_end is null then false
    -- Same-day window: 13:00 → 14:00 is quiet only between those times.
    when p.quiet_hours_start <= p.quiet_hours_end then
      local_now.t >= p.quiet_hours_start and local_now.t < p.quiet_hours_end
    -- Wrapping window: 22:00 → 07:00 is quiet at 23:00 AND at 03:00.
    else
      local_now.t >= p.quiet_hours_start or local_now.t < p.quiet_hours_end
  end
  from notification_preferences p
  cross join lateral (
    select ((now() at time zone 'UTC')
            + make_interval(mins => p.quiet_hours_utc_offset_minutes))::time as t
  ) local_now
  where p.user_id = p_user_id;
$$;

-- send-push is the only caller, on the service role.
revoke execute on function public.in_quiet_hours(uuid) from public, anon, authenticated;
