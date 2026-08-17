-- 0119_moderation_notices_and_appeals.sql
-- P3 #35 — no appeals, and no outcome ever reached either party.
--
-- Today a moderator removes a post or suspends an account and the person it
-- happened to learns nothing: a suspended creator's next sign-in fails with a
-- raw GoTrue "User is banned" string, no reason, no route to challenge it.
-- DSA Art. 17 requires a statement of reasons, and Apple expects a way to
-- contest a takedown.
--
-- Two tables: what we told you, and what you said back.

-- ── Statement of reasons ─────────────────────────────────────────────────
create table if not exists public.moderation_notices (
  id          uuid primary key default gen_random_uuid(),
  -- Who it happened TO: the content's author, or the suspended account.
  user_id     uuid not null references public.profiles(id) on delete cascade,
  action      text not null check (action in (
                'remove_content', 'restore_content', 'suspend_user', 'unsuspend_user')),
  target_type text not null,
  target_id   uuid,
  -- The moderator's note, verbatim. Null when they didn't write one, which is
  -- exactly the case worth auditing.
  reason      text,
  created_at  timestamptz not null default now()
);

create index if not exists moderation_notices_user_idx
  on public.moderation_notices (user_id, created_at desc);

alter table public.moderation_notices enable row level security;

-- You can read what was done to you; admins can read all of it. Written only
-- by moderate-report under the service role.
drop policy if exists moderation_notices_select_own on public.moderation_notices;
create policy moderation_notices_select_own on public.moderation_notices
  for select using (user_id = auth.uid() or public.is_admin());

revoke all on public.moderation_notices from public, anon, authenticated;
grant select on public.moderation_notices to authenticated;

-- ── Appeals ──────────────────────────────────────────────────────────────
-- Keyed on email, not on a session: a suspended account cannot sign in, so an
-- in-app appeal form would only work for the people who don't need it.
create table if not exists public.appeals (
  id            uuid primary key default gen_random_uuid(),
  email         text not null,
  notice_id     uuid references public.moderation_notices(id) on delete set null,
  user_id       uuid references public.profiles(id) on delete set null,
  body          text not null,
  status        text not null default 'open'
                check (status in ('open', 'upheld', 'overturned')),
  created_at    timestamptz not null default now(),
  decided_at    timestamptz,
  decided_by    uuid references auth.users(id),
  decision_note text
);

-- Supports both the admin queue and submit-appeal's per-email rate limit.
create index if not exists appeals_open_idx
  on public.appeals (status, created_at desc);
create index if not exists appeals_email_idx
  on public.appeals (lower(email), created_at desc);

alter table public.appeals enable row level security;

-- Admins only, and read-only from any client: appeals arrive through the
-- submit-appeal function (service role), which is what lets an unauthenticated
-- suspended user file one without opening the table to anon.
drop policy if exists appeals_admin_select on public.appeals;
create policy appeals_admin_select on public.appeals
  for select using (public.is_admin());

revoke all on public.appeals from public, anon, authenticated;
grant select on public.appeals to authenticated;
