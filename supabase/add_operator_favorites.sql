-- Personal "favorite people" list, used to quickly assign camera operators
-- without searching the whole user base each time. One row per (owner, favorite).
create table if not exists public.operator_favorites (
  user_id uuid not null references public.profiles(id) on delete cascade,
  favorite_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, favorite_id),
  check (user_id <> favorite_id)
);

create index if not exists operator_favorites_user_idx
  on public.operator_favorites (user_id, created_at desc);

alter table public.operator_favorites enable row level security;

-- A user manages only their own favorites.
drop policy if exists "own favorites: select" on public.operator_favorites;
create policy "own favorites: select" on public.operator_favorites
  for select using (auth.uid() = user_id);

drop policy if exists "own favorites: insert" on public.operator_favorites;
create policy "own favorites: insert" on public.operator_favorites
  for insert with check (auth.uid() = user_id);

drop policy if exists "own favorites: delete" on public.operator_favorites;
create policy "own favorites: delete" on public.operator_favorites
  for delete using (auth.uid() = user_id);
