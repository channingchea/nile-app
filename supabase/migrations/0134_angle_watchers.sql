-- 0134: viewers per angle (studio-edits plan, phase 5).
--
-- Each signed-in viewer keeps one row per show saying which camera they are
-- watching, refreshed on every angle change and once a minute. The Studio asks
-- angle_counts() every 15 s and shows "👁 N" on each camera tile. Counts are
-- for the host and crew only — viewers never see them.
create table if not exists public.angle_watchers (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id  uuid not null references public.profiles(id) on delete cascade,
  slot_id  uuid references public.event_cameras(id) on delete set null,
  seen_at  timestamptz not null default now(),
  primary key (event_id, user_id)
);

create index if not exists angle_watchers_event_seen on public.angle_watchers (event_id, seen_at);

alter table public.angle_watchers enable row level security;
-- No direct access: viewers write through angle_heartbeat, crew read through
-- angle_counts.

-- A viewer reports the angle they are on. [p_slug] is events.livekit_room;
-- p_slot null = an angle with no slot (or nothing yet).
create or replace function public.angle_heartbeat(p_slug text, p_slot uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_uid uuid := auth.uid();
  v_event uuid;
begin
  if v_uid is null then return; end if;
  select id into v_event from events where livekit_room = p_slug;
  if v_event is null then return; end if;
  if p_slot is not null and not exists (
    select 1 from event_cameras where id = p_slot and event_id = v_event
  ) then
    p_slot := null;
  end if;
  insert into angle_watchers (event_id, user_id, slot_id, seen_at)
  values (v_event, v_uid, p_slot, now())
  on conflict (event_id, user_id)
  do update set slot_id = excluded.slot_id, seen_at = excluded.seen_at;
end
$$;

revoke all on function public.angle_heartbeat(text, uuid) from public, anon;
grant execute on function public.angle_heartbeat(text, uuid) to authenticated;

-- Viewers per slot seen in the last 90 s. Host, crew and admins only.
create or replace function public.angle_counts(p_slug text)
returns table (slot_id uuid, viewers int)
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_uid uuid := auth.uid();
  v_event record;
begin
  select id, host_id into v_event from events where livekit_room = p_slug;
  if not found then return; end if;
  if not (
    v_event.host_id = v_uid
    or exists (select 1 from event_operators o where o.event_id = v_event.id and o.operator_id = v_uid)
    or (select is_admin())
  ) then
    return;
  end if;
  return query
    select w.slot_id, count(*)::int
      from angle_watchers w
     where w.event_id = v_event.id
       and w.slot_id is not null
       and w.seen_at > now() - interval '90 seconds'
       and w.user_id <> v_event.host_id
     group by w.slot_id;
end
$$;

revoke all on function public.angle_counts(text) from public, anon;
grant execute on function public.angle_counts(text) to authenticated;

-- Nightly: nobody is "watching" anything a day later.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'purge-angle-watchers';
    perform cron.schedule(
      'purge-angle-watchers',
      '17 4 * * *',
      $c$delete from public.angle_watchers where seen_at < now() - interval '1 day'$c$
    );
  end if;
end $$;
