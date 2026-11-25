-- 0155: cost controls, part 1 (docs/plans/cost-controls-and-60-payout.md,
-- phases 1-2).
--
-- 1. replay_video_kbps: the bitrate the livekit function records replays at
--    (720p30). 1500 kbps is about 12 MB a minute, half the old default.
-- 2. A price floor a host can do in their head, replacing the cost formula of
--    0078/0153: floor_base_cents for the first hour, plus floor_step_cents for
--    every floor_step_minutes (or part of one) after it. Same for any camera
--    count or Studio mode. $3 / $4 at 90 min / $5 at 2 h / $17 at 8 h.
-- 3. apple_fee_pct: stored for the Apple in-app purchase plan (iPhone price =
--    web price / (1 - apple_fee_pct)). Nothing reads it yet.

alter table public.app_config
  add column if not exists replay_video_kbps int not null default 1500
    check (replay_video_kbps between 300 and 6000),
  add column if not exists floor_base_cents int not null default 300
    check (floor_base_cents >= 0),
  add column if not exists floor_step_cents int not null default 100
    check (floor_step_cents >= 0),
  add column if not exists floor_step_minutes int not null default 30
    check (floor_step_minutes > 0),
  add column if not exists apple_fee_pct numeric not null default 0.30
    check (apple_fee_pct >= 0 and apple_fee_pct < 1);

-- Name and inputs unchanged so enforce_event_pricing_limits (0153) and the
-- two-argument form keep working; camera count and mode no longer matter.
create or replace function public.compute_min_ticket_cents(
  p_duration_minutes int,
  p_camera_count     int,
  p_mode             text
) returns int
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  c public.app_config%rowtype;
begin
  select * into c from public.app_config where id = 1;
  if not found then
    return 300;
  end if;

  return greatest(
    c.floor_base_cents + c.floor_step_cents * ceil(
      greatest(coalesce(p_duration_minutes, 60) - 60, 0)::numeric
      / c.floor_step_minutes
    )::int,
    c.min_ticket_cents
  );
end;
$$;
comment on function public.compute_min_ticket_cents(int, int, text) is
  'Ticket floor in cents: floor_base_cents for the first hour, + floor_step_cents per extra floor_step_minutes (0155). Camera count and mode are ignored.';
