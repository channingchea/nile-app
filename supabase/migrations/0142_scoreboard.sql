-- 0142: Studio scoreboard (docs/plans/studio-scoreboard.md, phase 1).
--
--   studio_teams                 the host's saved teams (name, code, colour,
--                                logo), owner-only like studio_graphics. Logos
--                                live in the studio-graphics bucket under the
--                                owner's folder (existing policies).
--   event_operators.is_scorekeeper  a crew member who keeps score from their
--                                phone (no camera). assign_event_operator
--                                takes it.
--   events.final_score           the on-air scoreboard when the show ended,
--                                written by a trigger on the move to 'ended'
--                                (stop-egress, the sweep, room_finished and
--                                the app all end shows that way). Clients
--                                can't write it.

create table public.studio_teams (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references public.profiles(id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 24),
  code       text not null check (code ~ '^[A-Z0-9&]{1,4}$'),
  color      text not null check (color ~ '^#[0-9A-F]{6}$'),
  logo_path  text check (logo_path is null or char_length(logo_path) <= 200),
  sport      text check (sport is null or sport in ('basketball', 'soccer', 'football', 'baseball', 'generic')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index studio_teams_owner on public.studio_teams (owner_id, name);

create trigger studio_teams_touch
  before update on public.studio_teams
  for each row execute function public.studio_graphics_touch();

alter table public.studio_teams enable row level security;

create policy studio_teams_owner_all on public.studio_teams
  for all to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

create or replace function public.studio_teams_cap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select count(*) from public.studio_teams where owner_id = new.owner_id) >= 200 then
    raise exception 'Saved teams are full (200 teams)' using errcode = 'P0001';
  end if;
  return new;
end
$$;

create trigger studio_teams_cap
  before insert on public.studio_teams
  for each row execute function public.studio_teams_cap();

-- ── Scorekeeper crew role ───────────────────────────────────────────────────

alter table public.event_operators
  add column is_scorekeeper boolean not null default false;

-- Same function, one more role. Dropped first so PostgREST never sees two
-- overloads (a 4-argument call would match both); older builds call with four
-- named arguments, which still resolve here.
drop function public.assign_event_operator(uuid, uuid, uuid, boolean);

create function public.assign_event_operator(
  p_event_id uuid,
  p_operator_id uuid,
  p_camera_id uuid default null,
  p_is_audio_operator boolean default false,
  p_is_scorekeeper boolean default false
)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_host_id uuid;
  v_already boolean;
begin
  select host_id into v_host_id from events where id = p_event_id;

  -- Host-only (never trust the client).
  if v_host_id is null or v_host_id is distinct from auth.uid() then
    raise exception 'not authorized';
  end if;

  select exists (
    select 1 from event_operators
    where event_id = p_event_id and operator_id = p_operator_id
  ) into v_already;

  -- A scorekeeper has no camera and doesn't carry the show audio.
  insert into event_operators (event_id, operator_id, camera_id, is_audio_operator, is_scorekeeper)
  values (
    p_event_id,
    p_operator_id,
    case when p_is_scorekeeper then null else p_camera_id end,
    p_is_audio_operator and not p_is_scorekeeper,
    p_is_scorekeeper
  )
  on conflict (event_id, operator_id)
  do update set
    camera_id = excluded.camera_id,
    is_audio_operator = excluded.is_audio_operator,
    is_scorekeeper = excluded.is_scorekeeper;

  if not v_already
     and p_operator_id is distinct from v_host_id
     and notif_enabled(p_operator_id, 'operator_assigned') is not false then
    insert into notifications (recipient_id, actor_id, type, entity_id)
    values (p_operator_id, v_host_id, 'operator_assigned', p_event_id);
  end if;
end;
$function$;

revoke all on function public.assign_event_operator(uuid, uuid, uuid, boolean, boolean) from public, anon;
grant execute on function public.assign_event_operator(uuid, uuid, uuid, boolean, boolean) to authenticated, service_role;

-- ── Final score ─────────────────────────────────────────────────────────────

alter table public.events
  add column final_score jsonb
  check (final_score is null or (jsonb_typeof(final_score) = 'object' and pg_column_size(final_score) <= 2000));

-- { sport, home: { name, code, color, logoPath? }, away: {…}, homeScore,
--   awayScore, period, elementId }. The scoreboard on air when the show ended
-- (the most recently changed one if several were up); with none on air, the
-- show's most recently changed scoreboard.
create or replace function public.events_final_score()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v record;
begin
  if public.client_role_blocked() then
    new.final_score := case when tg_op = 'UPDATE' then old.final_score else null end;
  end if;
  if tg_op = 'UPDATE'
     and new.status = 'ended'
     and old.status is distinct from 'ended'
     and new.final_score is null then
    select s.element_id, s.spec, s.state into v
      from public.live_element_state s
     where s.event_id = new.id and s.kind = 'scoreboard'
     order by (
         s.spec->>'angle' = 'true'
         or s.spec->'targets'->>'all' = 'true'
         or (jsonb_typeof(s.spec->'targets'->'slots') = 'array'
             and jsonb_array_length(s.spec->'targets'->'slots') > 0)
       ) desc nulls last,
       s.updated_at desc
     limit 1;
    if found then
      new.final_score := jsonb_build_object(
        'sport', v.spec->'config'->>'sport',
        'home', jsonb_strip_nulls(jsonb_build_object(
          'name', v.spec->'config'->'home'->>'name',
          'code', v.spec->'config'->'home'->>'code',
          'color', v.spec->'config'->'home'->>'color',
          'logoPath', v.spec->'config'->'home'->>'logoPath')),
        'away', jsonb_strip_nulls(jsonb_build_object(
          'name', v.spec->'config'->'away'->>'name',
          'code', v.spec->'config'->'away'->>'code',
          'color', v.spec->'config'->'away'->>'color',
          'logoPath', v.spec->'config'->'away'->>'logoPath')),
        'homeScore', case when jsonb_typeof(v.state->'home') = 'number' then (v.state->>'home')::int else 0 end,
        'awayScore', case when jsonb_typeof(v.state->'away') = 'number' then (v.state->>'away')::int else 0 end,
        'period', case when jsonb_typeof(v.state->'period') = 'number' then (v.state->>'period')::int else 1 end,
        'elementId', v.element_id
      );
    end if;
  end if;
  return new;
end
$$;

create trigger events_final_score
  before insert or update on public.events
  for each row execute function public.events_final_score();
