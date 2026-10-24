-- 0139: viewer taps on live elements (studio live elements, phase 5) and
-- viewers-per-angle for element angles (phase 4).

-- ── Votes ────────────────────────────────────────────────────────────────────
-- One row per viewer per element; a changed vote overwrites it. Written only
-- by the `livekit` function (`respond`). No policies: nobody — the host
-- included — reads who voted what; totals come from element_tally().
create table public.element_responses (
  event_id   uuid not null references public.events(id) on delete cascade,
  element_id text not null check (char_length(element_id) between 1 and 80),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  choice     text not null check (char_length(choice) between 1 and 40),
  updated_at timestamptz not null default now(),
  primary key (event_id, element_id, user_id)
);

create index element_responses_tally on public.element_responses (event_id, element_id, choice);

alter table public.element_responses enable row level security;

-- When each element's totals last went out, and whether a trailing send is
-- already waiting — so totals reach viewers at most once a second.
create table public.element_tally_state (
  event_id   uuid not null references public.events(id) on delete cascade,
  element_id text not null,
  sent_at    timestamptz not null default now(),
  scheduled  boolean not null default false,
  primary key (event_id, element_id)
);

alter table public.element_tally_state enable row level security;

-- A vote. 'slow' when this viewer changed it under a second ago, else 'ok'.
create or replace function public.element_respond(p_event uuid, p_element text, p_user uuid, p_choice text)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_last timestamptz;
begin
  select updated_at into v_last
    from element_responses
   where event_id = p_event and element_id = p_element and user_id = p_user
   for update;
  if v_last is not null and v_last > now() - interval '1 second' then
    return 'slow';
  end if;
  insert into element_responses (event_id, element_id, user_id, choice, updated_at)
  values (p_event, p_element, p_user, p_choice, now())
  on conflict (event_id, element_id, user_id)
  do update set choice = excluded.choice, updated_at = excluded.updated_at;
  return 'ok';
end
$$;

-- Choice → count for one element.
create or replace function public.element_tally(p_event uuid, p_element text)
returns jsonb
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $$
  select coalesce(jsonb_object_agg(choice, n), '{}'::jsonb)
    from (
      select choice, count(*)::int as n
        from element_responses
       where event_id = p_event and element_id = p_element
       group by choice
    ) t
$$;

-- May totals go out now? 0 = send now; > 0 = schedule one send in that many
-- ms; -1 = a send is already scheduled, skip.
create or replace function public.element_tally_claim(p_event uuid, p_element text)
returns int
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v record;
  v_ms int;
begin
  insert into element_tally_state (event_id, element_id, sent_at, scheduled)
  values (p_event, p_element, now(), false)
  on conflict do nothing;
  if found then
    return 0;
  end if;
  select sent_at, scheduled into v
    from element_tally_state
   where event_id = p_event and element_id = p_element
   for update;
  if v.scheduled then
    return -1;
  end if;
  v_ms := (extract(epoch from (now() - v.sent_at)) * 1000)::int;
  if v_ms >= 1000 then
    update element_tally_state set sent_at = now()
     where event_id = p_event and element_id = p_element;
    return 0;
  end if;
  update element_tally_state set scheduled = true
   where event_id = p_event and element_id = p_element;
  return 1000 - v_ms;
end
$$;

-- The scheduled send went out.
create or replace function public.element_tally_sent(p_event uuid, p_element text)
returns void
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  update element_tally_state set sent_at = now(), scheduled = false
   where event_id = p_event and element_id = p_element
$$;

revoke all on function public.element_respond(uuid, text, uuid, text) from public, anon, authenticated;
revoke all on function public.element_tally(uuid, text) from public, anon, authenticated;
revoke all on function public.element_tally_claim(uuid, text) from public, anon, authenticated;
revoke all on function public.element_tally_sent(uuid, text) from public, anon, authenticated;
grant execute on function public.element_respond(uuid, text, uuid, text) to service_role;
grant execute on function public.element_tally(uuid, text) to service_role;
grant execute on function public.element_tally_claim(uuid, text) to service_role;
grant execute on function public.element_tally_sent(uuid, text) to service_role;

-- ── Viewers per angle, element angles included ──────────────────────────────
-- 0134 counted cameras only (slot_id → event_cameras). An element shown as
-- its own angle is `el:<element id>`; it goes in `angle`.
alter table public.angle_watchers
  add column if not exists angle text check (angle is null or char_length(angle) <= 84);

drop function if exists public.angle_heartbeat(text, uuid);
create or replace function public.angle_heartbeat(p_slug text, p_slot text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_uid uuid := auth.uid();
  v_event uuid;
  v_slot uuid;
  v_angle text;
begin
  if v_uid is null then return; end if;
  select id into v_event from events where livekit_room = p_slug;
  if v_event is null then return; end if;
  if p_slot like 'el:%' then
    v_angle := left(p_slot, 84);
  elsif p_slot ~ '^[0-9a-fA-F-]{36}$' then
    select id into v_slot from event_cameras where id = p_slot::uuid and event_id = v_event;
  end if;
  insert into angle_watchers (event_id, user_id, slot_id, angle, seen_at)
  values (v_event, v_uid, v_slot, v_angle, now())
  on conflict (event_id, user_id)
  do update set slot_id = excluded.slot_id, angle = excluded.angle, seen_at = excluded.seen_at;
end
$$;

revoke all on function public.angle_heartbeat(text, text) from public, anon;
grant execute on function public.angle_heartbeat(text, text) to authenticated;

drop function if exists public.angle_counts(text);
create or replace function public.angle_counts(p_slug text)
returns table (slot_id text, viewers int)
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
    select coalesce(w.slot_id::text, w.angle), count(*)::int
      from angle_watchers w
     where w.event_id = v_event.id
       and (w.slot_id is not null or w.angle is not null)
       and w.seen_at > now() - interval '90 seconds'
       and w.user_id <> v_event.host_id
     group by coalesce(w.slot_id::text, w.angle);
end
$$;

revoke all on function public.angle_counts(text) from public, anon;
grant execute on function public.angle_counts(text) to authenticated;
