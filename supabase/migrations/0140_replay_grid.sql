-- 0140: replays with graphics and elements (studio live elements, phase 6).
--
-- Next to the existing combined recording (kept as the backup), each show is
-- recorded a second time through Nile's own recorder page: one grid of the
-- on-air cameras and element angles, in the host's order. The page reports
-- where each tile sits and every overlay change, with the moment in the video
-- it happened, so the app's replay screen draws graphics and elements over the
-- right tile. Nothing here is read by clients directly — the `livekit`
-- function's `replay-grid` action serves it behind the replay access gate.

create table public.replay_grids (
  id                  uuid primary key default gen_random_uuid(),
  replay_id           uuid not null references public.replays(id) on delete cascade,
  event_id            uuid not null references public.events(id) on delete cascade,
  egress_id           text unique,
  status              text not null default 'recording'
                        check (status in ('recording', 'ready', 'failed')),
  playback_path       text,
  duration_ms         bigint,
  -- The recorder page proves itself with this (it travels in the page URL).
  recorder_key        uuid not null unique default gen_random_uuid(),
  -- Wall clock when the page started recording = video time 0. Server-side
  -- marks (vote totals) are placed on the video with it.
  recorder_started_at timestamptz,
  created_at          timestamptz not null default now()
);

create index replay_grids_event on public.replay_grids (event_id, status, created_at desc);

alter table public.replay_grids enable row level security;

-- What the replay needs to redraw the overlays.
--   start  {wall}               page started recording
--   tiles  [{s, el, r:[x,y,w,h]}] tile layout (fractions of the frame)
--   meta   {...}                room metadata (graphics, elements, layout, show)
--   tally  {elementId, tally}   vote totals (server-written, placed by `at`)
--   end    {}                   page stopped
-- `seq` is the page's own counter, so a retried upload is never stored twice.
create table public.replay_marks (
  id        bigserial primary key,
  grid_id   uuid not null references public.replay_grids(id) on delete cascade,
  seq       int check (seq between 0 and 20000),
  offset_ms int check (offset_ms >= 0),
  at        timestamptz not null default now(),
  kind      text not null check (kind in ('start', 'tiles', 'meta', 'tally', 'end')),
  data      jsonb not null check (octet_length(data::text) <= 65536)
);

create unique index replay_marks_seq on public.replay_marks (grid_id, seq) where seq is not null;
create index replay_marks_grid on public.replay_marks (grid_id, id);

alter table public.replay_marks enable row level security;

-- Retention: the grid file goes with its replay (rows cascade with it).
create or replace function public.purge_expired_replays(p_retention_days integer default 30)
returns integer
language plpgsql
security definer
set search_path to 'public', 'storage', 'pg_temp'
as $function$
declare
  v_count integer;
begin
  perform set_config('storage.allow_delete_query', 'true', true);

  with victims as (
    select r.id, r.event_id, r.playback_path
      from public.replays r
     where r.created_at < now() - make_interval(days => p_retention_days)
  ),
  gone_grids as (
    delete from storage.objects o
     using public.replay_grids g, victims v
     where g.replay_id = v.id
       and o.bucket_id = 'replays'
       and o.name = g.playback_path
    returning o.name
  ),
  gone as (
    delete from storage.objects o
     using victims v
     where o.bucket_id = 'replays'
       and o.name = v.playback_path
    returning o.name
  ),
  purged as (
    delete from public.replays r
     using victims v
     where r.id = v.id
       -- Keep the row (and retry next run) if the object is still there. Losing
       -- the row is losing the only pointer to the file.
       and (
         v.playback_path is null
         or v.playback_path in (select name from gone)
         or not exists (
           select 1 from storage.objects o
            where o.bucket_id = 'replays' and o.name = v.playback_path
         )
       )
    returning r.id, r.event_id
  ),
  -- B10, unchanged: an event with no replay behind it must stop advertising one.
  cleared as (
    update public.events e
       set replay_published_at = null,
           replay_price = null
      from purged p
     where e.id = p.event_id
    returning e.id
  )
  select count(*) into v_count from purged;

  return v_count;
end;
$function$;

-- Stuck grid recordings fail with the same timeout as the main one.
create or replace function public.fail_stuck_replays(p_timeout_hours integer default 10)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_count integer;
  v_max   integer;
  v_floor integer;
begin
  -- Never fail a recording that could still legitimately be running: the hard
  -- stream cap plus an hour for egress finalization.
  select max_stream_minutes into v_max from app_config where id = 1;
  v_floor := ceil(coalesce(v_max, 480) / 60.0)::integer + 1;
  if p_timeout_hours < v_floor then
    p_timeout_hours := v_floor;
  end if;

  update public.replay_grids
     set status = 'failed'
   where status = 'recording'
     and created_at < now() - make_interval(hours => p_timeout_hours);

  with stuck as (
    update public.replays
       set status = 'failed'
     where status in ('recording','processing')
       and created_at < now() - make_interval(hours => p_timeout_hours)
    returning id
  )
  select count(*) into v_count from stuck;
  return v_count;
end;
$function$;

revoke execute on function public.purge_expired_replays(integer) from public, anon, authenticated;
revoke execute on function public.fail_stuck_replays(integer) from public, anon, authenticated;
