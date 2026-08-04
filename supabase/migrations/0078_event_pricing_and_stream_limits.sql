-- Create-event pricing floors & stream limits.
--
-- Free events stay available for SINGLE-camera streams only. Any priced event
-- must clear a per-event break-even floor computed from the real cost drivers
-- (Stripe fees, egress per viewer-hour, ingest per camera-hour) against the
-- platform's half of the split. Streams are additionally capped at 8 hours.
-- Every constant lives in app_config, so re-tuning after a real LiveKit invoice
-- is a data change rather than a deploy.
--
-- Grandfathering: the rules are enforced on INSERT and on UPDATEs that actually
-- touch price / camera_count / the scheduled window. Already-published events
-- are left alone until someone edits one of those fields.

-- ── 1) Pricing + limit knobs on the app_config singleton (0041) ───────────────
alter table public.app_config
  add column if not exists min_ticket_cents int not null default 100
    check (min_ticket_cents >= 0),
  add column if not exists egress_cents_per_viewer_hour numeric not null default 27
    check (egress_cents_per_viewer_hour >= 0),
  add column if not exists ingest_cents_per_cam_hour numeric not null default 40
    check (ingest_cents_per_cam_hour >= 0),
  add column if not exists stripe_pct numeric not null default 0.029
    check (stripe_pct >= 0 and stripe_pct < 1),
  add column if not exists stripe_fixed_cents int not null default 30
    check (stripe_fixed_cents >= 0),
  add column if not exists floor_assumed_tickets int not null default 10
    check (floor_assumed_tickets > 0),
  add column if not exists max_stream_minutes int not null default 480
    check (max_stream_minutes > 0);

-- The app mirrors the floor locally for live hints in the create flow.
-- app_config already carries a read-to-everyone RLS policy (0041); this makes
-- the grant for the new columns explicit.
grant select on public.app_config to anon, authenticated;

-- ── 2) The floor itself ───────────────────────────────────────────────────────
-- Worst case per ticket: one viewer who watches the entire show (egress), plus
-- this ticket's share of ingest across `floor_assumed_tickets` buyers, plus
-- Stripe's per-transaction fixed fee. That cost has to come out of the
-- platform's share of the ticket, after Stripe's percentage. Rounded up to the
-- nearest 50c and never below min_ticket_cents.
create or replace function public.compute_min_ticket_cents(
  p_duration_minutes int,
  p_camera_count     int
) returns int
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  c        public.app_config%rowtype;
  v_hours  numeric;
  v_cams   int;
  v_cost   numeric;  -- platform cost attributable to a single ticket, in cents
  v_margin numeric;  -- platform's slice of each ticket, net of Stripe's percent
begin
  select * into c from public.app_config where id = 1;
  if not found then
    return 100;
  end if;

  v_hours := greatest(coalesce(p_duration_minutes, 60), 1) / 60.0;
  v_cams  := greatest(coalesce(p_camera_count, 1), 1);

  v_cost := c.stripe_fixed_cents
          + c.egress_cents_per_viewer_hour * v_hours
          + (c.ingest_cents_per_cam_hour * v_cams * v_hours)
            / c.floor_assumed_tickets;

  v_margin := (1 - c.creator_revenue_share) - c.stripe_pct;
  if v_margin <= 0 then
    return c.min_ticket_cents;  -- misconfigured split: fall back to the floor
  end if;

  return greatest(
    (ceil((v_cost / v_margin) / 50.0) * 50)::int,
    c.min_ticket_cents
  );
end;
$$;

comment on function public.compute_min_ticket_cents(int, int) is
  'Break-even ticket floor in cents for a stream of the given duration and camera count. Constants live in app_config.';

-- Signed-in hosts only (the create flow is authenticated); anon has no reason
-- to price an event. Same posture as the client-called RPC list in 0060.
revoke execute on function public.compute_min_ticket_cents(int, int)
  from public, anon;
grant execute on function public.compute_min_ticket_cents(int, int)
  to authenticated;

-- ── 3) Server-side enforcement ────────────────────────────────────────────────
-- Error codes the app maps to friendly copy:
--   multicam_requires_ticket · price_below_minimum · duration_exceeds_max
create or replace function public.enforce_event_pricing_limits()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_max_minutes int;
  v_minutes     int;
  v_floor       int;
begin
  select max_stream_minutes into v_max_minutes
    from public.app_config where id = 1;
  v_max_minutes := coalesce(v_max_minutes, 480);

  -- Duration cap (only checkable when both ends of the window are set).
  if new.scheduled_at is not null and new.end_at is not null then
    v_minutes := ceil(
      extract(epoch from (new.end_at - new.scheduled_at)) / 60.0
    )::int;
    if v_minutes > v_max_minutes then
      raise exception 'duration_exceeds_max'
        using hint = 'Streams are capped at '
                     || (v_max_minutes / 60) || ' hours.';
    end if;
  end if;

  -- Multi-camera streams cost real money to run; they can't be free.
  if coalesce(new.camera_count, 1) > 1 and coalesce(new.price, 0) = 0 then
    raise exception 'multicam_requires_ticket'
      using hint = 'Multi-camera streams need a ticket price.';
  end if;

  -- Any priced event has to clear its own break-even floor.
  if coalesce(new.price, 0) > 0 then
    v_floor := public.compute_min_ticket_cents(
      coalesce(v_minutes, 60),
      coalesce(new.camera_count, 1)
    );
    if new.price < v_floor then
      raise exception 'price_below_minimum'
        using hint = 'Minimum for this event is $'
                     || to_char(v_floor / 100.0, 'FM999990.00') || '.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_enforce_event_pricing_limits_ins on public.events;
create trigger trg_enforce_event_pricing_limits_ins
  before insert on public.events
  for each row
  execute function public.enforce_event_pricing_limits();

-- On update, fire only when a field the rules depend on actually moves, so
-- grandfathered events survive unrelated edits (title, cover, status changes).
drop trigger if exists trg_enforce_event_pricing_limits_upd on public.events;
create trigger trg_enforce_event_pricing_limits_upd
  before update on public.events
  for each row
  when (
    new.price           is distinct from old.price
    or new.camera_count is distinct from old.camera_count
    or new.scheduled_at is distinct from old.scheduled_at
    or new.end_at       is distinct from old.end_at
  )
  execute function public.enforce_event_pricing_limits();

-- Trigger functions run as the table owner; no client role needs EXECUTE (0060).
revoke execute on function public.enforce_event_pricing_limits()
  from public, anon, authenticated;

-- ── 4) Auto-end backstop for the hard cap ─────────────────────────────────────
-- 0056 ends a live show once its purchased duration (measured from started_at)
-- runs out. That leaves one hole: a live row with no end_at never expires. Add
-- an absolute stop at max_stream_minutes past started_at so nothing streams
-- forever, and keep the cron as the backstop for the in-app auto-end.
create or replace function public.auto_end_expired_events(p_grace_minutes int default 2)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count       integer;
  v_max_minutes integer;
begin
  select max_stream_minutes into v_max_minutes
    from public.app_config where id = 1;
  v_max_minutes := coalesce(v_max_minutes, 480);

  with expired as (
    update public.events
       set status = 'ended',
           ended_at = now()
     where status = 'live'
       and (
         -- Purchased duration, measured from the actual start (0056).
         (end_at is not null
          and coalesce(
                started_at + (end_at - scheduled_at),
                end_at
              ) < now() - make_interval(mins => p_grace_minutes))
         -- Absolute cap: nothing streams past max_stream_minutes, even when the
         -- row has no end_at.
         or (started_at is not null
             and started_at < now()
                 - make_interval(mins => v_max_minutes + p_grace_minutes))
       )
    returning id
  )
  select count(*) into v_count from expired;
  return v_count;
end;
$$;

comment on function public.auto_end_expired_events(int) is
  'Cron-invoked: ends live events after their purchased duration measured from started_at (fallback end_at), and hard-stops any live event past app_config.max_stream_minutes.';
