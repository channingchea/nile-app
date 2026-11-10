-- 0153: Premiere playback, protection and pricing (docs/plans/studio-modes.md,
-- phases 7-9).
--
-- 1. event_films.film_state: the film clock livekit `film-control` writes (the
--    same object it puts in room metadata `film`). live-chat reads it to apply
--    the filmmaker's chat choice while the film plays; the replay reads it to
--    split Intro / Film / Q&A.
-- 2. event_films.ask_rating + film_ratings: the optional "Rate the film" on
--    the closing slate. Written by the premiere function only (it checks the
--    viewer could watch); the host reads their own film's ratings.
-- 3. film-captions bucket (private): the WebVTT files the filmmaker adds, so
--    the player can show them (video_player can't pick HLS subtitle tracks).
--    Served by short-lived signed URLs from the premiere function.
-- 4. compute_min_ticket_cents by Studio mode: every show now carries its
--    recording cost (fee analysis, guardrail 1); Interview adds its guests'
--    ingest; Premiere adds Cloudflare Stream delivery for each viewer and its
--    share of storage, assuming the film runs the length of the show.

alter table public.event_films
  add column if not exists film_state jsonb,
  add column if not exists ask_rating boolean not null default false;

create table if not exists public.film_ratings (
  event_id   uuid not null references public.events(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  stars      smallint not null check (stars between 1 and 5),
  created_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

alter table public.film_ratings enable row level security;
revoke all on public.film_ratings from anon, authenticated;
grant select on public.film_ratings to authenticated;

create policy film_ratings_host_read on public.film_ratings
  for select to authenticated
  using (exists (select 1 from public.events e where e.id = event_id and e.host_id = auth.uid()));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('film-captions', 'film-captions', false, 2097152, array['text/vtt'])
on conflict (id) do nothing;

-- Pricing knobs (cents). Recording: LiveKit room composite, per show-hour.
alter table public.app_config
  add column if not exists recording_cents_per_hour numeric not null default 120
    check (recording_cents_per_hour >= 0),
  add column if not exists stream_delivery_cents_per_viewer_hour numeric not null default 6
    check (stream_delivery_cents_per_viewer_hour >= 0),
  add column if not exists stream_storage_cents_per_minute numeric not null default 0.5
    check (stream_storage_cents_per_minute >= 0),
  add column if not exists interview_assumed_guests int not null default 2
    check (interview_assumed_guests between 0 and 5);

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
  c        public.app_config%rowtype;
  v_mins   int;
  v_hours  numeric;
  v_cams   int;
  v_cost   numeric;
  v_margin numeric;
begin
  select * into c from public.app_config where id = 1;
  if not found then
    return 100;
  end if;

  v_mins  := greatest(coalesce(p_duration_minutes, 60), 1);
  v_hours := v_mins / 60.0;
  v_cams  := greatest(coalesce(p_camera_count, 1), 1)
           + case when p_mode = 'interview' then c.interview_assumed_guests else 0 end;

  v_cost := c.stripe_fixed_cents
          + c.egress_cents_per_viewer_hour * v_hours
          + (c.ingest_cents_per_cam_hour * v_cams * v_hours
             + c.recording_cents_per_hour * v_hours) / c.floor_assumed_tickets;

  if p_mode = 'premiere' then
    v_cost := v_cost
            + c.stream_delivery_cents_per_viewer_hour * v_hours
            + (c.stream_storage_cents_per_minute * v_mins) / c.floor_assumed_tickets;
  end if;

  v_margin := (1 - c.creator_revenue_share) - c.stripe_pct;
  if v_margin <= 0 then
    return c.min_ticket_cents;
  end if;

  return greatest(
    (ceil((v_cost / v_margin) / 50.0) * 50)::int,
    c.min_ticket_cents
  );
end;
$$;
comment on function public.compute_min_ticket_cents(int, int, text) is
  'Break-even ticket floor in cents by duration, camera count and Studio mode (0153). Constants live in app_config.';

-- The two-argument form stays (other callers) and now means Multicam.
create or replace function public.compute_min_ticket_cents(
  p_duration_minutes int,
  p_camera_count     int
) returns int
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.compute_min_ticket_cents(p_duration_minutes, p_camera_count, 'multicam');
$$;

revoke execute on function public.compute_min_ticket_cents(int, int, text) from public, anon;
grant execute on function public.compute_min_ticket_cents(int, int, text) to authenticated;

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

  if coalesce(new.camera_count, 1) > 1 and coalesce(new.price, 0) = 0 then
    raise exception 'multicam_requires_ticket'
      using hint = 'Multi-camera streams need a ticket price.';
  end if;

  if coalesce(new.price, 0) > 0 then
    v_floor := public.compute_min_ticket_cents(
      coalesce(v_minutes, 60),
      coalesce(new.camera_count, 1),
      coalesce(new.studio_mode, 'multicam')
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

-- A mode change moves the floor too, so it re-checks the price.
create or replace trigger trg_enforce_event_pricing_limits_upd
  before update on public.events
  for each row
  when (
    new.price           is distinct from old.price
    or new.camera_count is distinct from old.camera_count
    or new.scheduled_at is distinct from old.scheduled_at
    or new.end_at       is distinct from old.end_at
    or new.studio_mode  is distinct from old.studio_mode
  )
  execute function public.enforce_event_pricing_limits();

revoke execute on function public.enforce_event_pricing_limits()
  from public, anon, authenticated;
