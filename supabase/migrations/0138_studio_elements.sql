-- 0138: Studio live elements — foundation (docs/plans/studio-live-elements-foundation.md, phase 1).
--
-- Two tables:
--   studio_elements     the host's saved elements (scoreboards, polls, …), like
--                       studio_graphics: owner-only, reusable across shows.
--   live_element_state  one row per element per event — the source of truth for
--                       what an element shows right now (score, clock, who it is
--                       on air for). Written only by the `livekit` function
--                       (set-element), which mirrors the on-air ones into the
--                       LiveKit room metadata (`elements`). A Studio that drops
--                       and rejoins reloads from here, so nothing is lost.
--
-- Kinds are checked by shape here and by name in code (ELEMENT_KINDS in
-- supabase/functions/_shared/elements.ts, ElementKinds in
-- lib/services/live_elements.dart), so a new element kind needs no migration.

create table public.studio_elements (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references public.profiles(id) on delete cascade,
  kind       text not null check (kind ~ '^[a-z][a-z_]{0,29}$'),
  name       text not null check (char_length(name) between 1 and 60),
  config     jsonb not null default '{}'::jsonb
             check (jsonb_typeof(config) = 'object' and pg_column_size(config) <= 8000),
  -- { nileStyle?: bool, accent?, panel?, text?, onAccent?: '#RRGGBB', font? } —
  -- per-element overrides on top of the brand kit.
  style      jsonb not null default '{}'::jsonb
             check (jsonb_typeof(style) = 'object' and pg_column_size(style) <= 1000),
  sort       int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index studio_elements_owner_sort on public.studio_elements (owner_id, sort, created_at);

-- studio_graphics_touch (0130) only stamps updated_at — reused as is.
create trigger studio_elements_touch
  before update on public.studio_elements
  for each row execute function public.studio_graphics_touch();

alter table public.studio_elements enable row level security;

create policy studio_elements_owner_all on public.studio_elements
  for all to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

create or replace function public.studio_elements_cap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select count(*) from public.studio_elements where owner_id = new.owner_id) >= 200 then
    raise exception 'Elements library is full (200 items)' using errcode = 'P0001';
  end if;
  return new;
end
$$;

create trigger studio_elements_cap
  before insert on public.studio_elements
  for each row execute function public.studio_elements_cap();

create table public.live_element_state (
  event_id    uuid not null references public.events(id) on delete cascade,
  element_id  text not null check (char_length(element_id) between 1 and 80),
  kind        text not null check (kind ~ '^[a-z][a-z_]{0,29}$'),
  -- name, config, style, nileStyle, targets, presentedBy — as last pushed.
  spec        jsonb not null default '{}'::jsonb check (jsonb_typeof(spec) = 'object'),
  -- kind-specific values plus `clocks` ({ name: { elapsedMs, runningSince?, pausedAt? } }, server ms).
  state       jsonb not null default '{}'::jsonb check (jsonb_typeof(state) = 'object'),
  -- Every push carries the next version; an older one is refused.
  version     int not null check (version >= 1),
  -- Server ms of the moment the change refers to — viewers hold it back to match their video.
  content_at  bigint not null default 0,
  updated_at  timestamptz not null default now(),
  primary key (event_id, element_id),
  check (pg_column_size(spec) + pg_column_size(state) <= 16000)
);

-- No policies: only the livekit function (service role) reads or writes it.
-- The Studio reads it back through the `list-elements` action.
alter table public.live_element_state enable row level security;
