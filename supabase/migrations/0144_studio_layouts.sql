-- 0144: Studio Layouts (docs/plans/studio-layouts.md, phase 1).
--
-- studio_layouts — the host's saved show setups, one account-wide library like
-- studio_graphics / studio_elements. `payload` is a StudioLayout
-- (lib/services/studio_layouts.dart): cameras by position, each with the
-- library graphics and elements on it (spot, layer order, auto-hide), on/off
-- air, plus element angles, the default angle and camera order. It only holds
-- library ids — Apply looks them up, so editing a graphic updates every
-- layout that uses it. `template` names the template it was made from.

create table public.studio_layouts (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references public.profiles(id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 60),
  payload    jsonb not null default '{}'::jsonb
             check (jsonb_typeof(payload) = 'object' and pg_column_size(payload) <= 16384),
  template   text check (template ~ '^[a-z][a-z_]{0,29}$'),
  sort       int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index studio_layouts_owner_sort on public.studio_layouts (owner_id, sort, created_at);

-- studio_graphics_touch (0130) only stamps updated_at — reused as is.
create trigger studio_layouts_touch
  before update on public.studio_layouts
  for each row execute function public.studio_graphics_touch();

alter table public.studio_layouts enable row level security;

create policy studio_layouts_owner_all on public.studio_layouts
  for all to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

create or replace function public.studio_layouts_cap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select count(*) from public.studio_layouts where owner_id = new.owner_id) >= 100 then
    raise exception 'Layouts library is full (100 layouts)' using errcode = 'P0001';
  end if;
  return new;
end
$$;

create trigger studio_layouts_cap
  before insert on public.studio_layouts
  for each row execute function public.studio_layouts_cap();
