-- ─────────────────────────────────────────────────────────────────────────────
-- Enable RLS on the two tables flagged as fully exposed (profiles,
-- event_attendees). DRAFT — do NOT apply blind. Run deliberately, then smoke-test
-- signup, user search, the operator picker/favorites, and profile editing right
-- after, since these tables are read across most of the app.
--
-- Design rationale:
--   profiles         → public read (social app: search, post authors, pickers);
--                      users update ONLY their own row; no client insert (the
--                      SECURITY DEFINER `handle_new_user` trigger populates rows
--                      at signup, bypassing RLS); no delete.
--   event_attendees  → public read; NO client writes — nothing in the app or any
--                      DB function currently writes this table, so we add no
--                      insert/update/delete policy. Add an insert policy when a
--                      "join event" flow lands (see commented stub at the bottom).
-- ─────────────────────────────────────────────────────────────────────────────

-- ── profiles ────────────────────────────────────────────────────────────────
alter table public.profiles enable row level security;

-- Anyone (anon or authenticated) may read any profile.
drop policy if exists "profiles: public read" on public.profiles;
create policy "profiles: public read" on public.profiles
  for select using (true);

-- A user may update only their own profile row.
drop policy if exists "profiles: update own" on public.profiles;
create policy "profiles: update own" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- NOTE: intentionally no INSERT policy. Profile rows are created by the
-- handle_new_user trigger (SECURITY DEFINER), which is not subject to RLS.
-- If you ever insert profiles from the client, add:
--   create policy "profiles: insert own" on public.profiles
--     for insert with check (auth.uid() = id);

-- ── event_attendees ─────────────────────────────────────────────────────────
alter table public.event_attendees enable row level security;

-- Anyone may read attendee rows (counts, lists). Tighten to authenticated-only
-- if you don't want anon to see attendance: replace `true` with `auth.uid() is not null`.
drop policy if exists "event_attendees: public read" on public.event_attendees;
create policy "event_attendees: public read" on public.event_attendees
  for select using (true);

-- NOTE: no write policies — nothing writes this table today, so RLS-on +
-- no-insert-policy = no client writes (the safe default). When a join flow
-- exists, add:
--   create policy "event_attendees: join self" on public.event_attendees
--     for insert with check (auth.uid() = user_id);
--   create policy "event_attendees: leave self" on public.event_attendees
--     for delete using (auth.uid() = user_id);
