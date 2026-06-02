-- Phase 19: Blocking & Reporting
-- Run this entire file in the Supabase SQL editor (single transaction is fine —
-- no new enum value is USED in the same txn it is created, unlike phase 18).
--
-- Design:
--   • blocks       — one row per (blocker, blocked) pair. Block semantics are
--                    BIDIRECTIONAL: if A blocks B, the is_blocked(A,B) helper is
--                    true regardless of argument order, so neither user sees the
--                    other anywhere RLS or the client checks it.
--   • reports      — insert-only audit log. Reviewed manually in Supabase for now
--                    (no in-app moderation UI yet).
--   • is_blocked() — single SECURITY DEFINER helper used by every block-aware RLS
--                    policy. Centralizes the rule the same way notif_enabled()
--                    centralizes phase-18 preference checks.
--
-- RLS: posts / events / post_comments / follows previously had `using (true)`
-- select policies. We replace those with block-aware versions. The client also
-- applies a `not.in(blockedIds)` guard on discover/search for performance, but
-- RLS is the security floor — a tampered client still can't read blocked rows.

-- ════════════════════════════════════════════════════════════════════════════
-- Tables
-- ════════════════════════════════════════════════════════════════════════════

create table if not exists blocks (
  blocker_id  uuid        not null references profiles(id) on delete cascade,
  blocked_id  uuid        not null references profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

-- Reverse-lookup index: "who has blocked me?" (used by is_blocked's OR arm).
create index if not exists blocks_blocked_idx on blocks (blocked_id);

do $$ begin
  create type report_target_type as enum ('user', 'post', 'event', 'comment');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type report_reason as enum (
    'spam', 'harassment', 'hate_speech', 'nudity', 'violence', 'self_harm', 'other'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type report_status as enum ('open', 'reviewing', 'resolved', 'dismissed');
exception when duplicate_object then null;
end $$;

create table if not exists reports (
  id           uuid               primary key default gen_random_uuid(),
  reporter_id  uuid               not null references profiles(id) on delete cascade,
  target_type  report_target_type not null,
  target_id    uuid               not null,  -- profiles.id / posts.id / events.id / post_comments.id
  reason       report_reason      not null,
  note         text,                          -- optional free text, esp. for 'other'
  status       report_status      not null default 'open',
  created_at   timestamptz        not null default now()
);

-- Review queue: open reports first, newest first.
create index if not exists reports_status_created_idx
  on reports (status, created_at desc);
-- Dedup / rate-limit lookups: has this reporter already flagged this target?
create index if not exists reports_reporter_target_idx
  on reports (reporter_id, target_type, target_id);

-- ════════════════════════════════════════════════════════════════════════════
-- Helper: is_blocked(a, b) — true if EITHER user has blocked the other.
-- ════════════════════════════════════════════════════════════════════════════

create or replace function is_blocked(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from blocks
    where (blocker_id = a and blocked_id = b)
       or (blocker_id = b and blocked_id = a)
  );
$$;

-- ════════════════════════════════════════════════════════════════════════════
-- RLS — blocks
-- ════════════════════════════════════════════════════════════════════════════

alter table blocks enable row level security;

drop policy if exists "blocks_select_own" on blocks;
drop policy if exists "blocks_insert_own" on blocks;
drop policy if exists "blocks_delete_own" on blocks;

-- A user can see (and thus manage) only the blocks they created.
create policy "blocks_select_own" on blocks for select
  using (blocker_id = auth.uid());
create policy "blocks_insert_own" on blocks for insert
  with check (blocker_id = auth.uid());
create policy "blocks_delete_own" on blocks for delete
  using (blocker_id = auth.uid());

-- ════════════════════════════════════════════════════════════════════════════
-- RLS — reports (insert-only from clients; no client reads)
-- ════════════════════════════════════════════════════════════════════════════

alter table reports enable row level security;

drop policy if exists "reports_insert_own" on reports;
-- No select policy: clients cannot read the reports table at all. Review happens
-- via the service role in the Supabase dashboard.
create policy "reports_insert_own" on reports for insert
  with check (reporter_id = auth.uid());

-- ════════════════════════════════════════════════════════════════════════════
-- Block-aware SELECT policies on existing tables
-- (replace the old `using (true)` policies)
-- ════════════════════════════════════════════════════════════════════════════

-- posts: hide rows authored by someone in a block relationship with the viewer.
drop policy if exists "posts_select_all" on posts;
create policy "posts_select_visible" on posts for select
  using (not is_blocked(auth.uid(), user_id));

-- events: same, keyed on host_id.
drop policy if exists "events_select_all" on events;
create policy "events_select_visible" on events for select
  using (not is_blocked(auth.uid(), host_id));

-- post_comments: hide comments from blocked users.
drop policy if exists "post_comments_select_all" on post_comments;
create policy "post_comments_select_visible" on post_comments for select
  using (not is_blocked(auth.uid(), user_id));

-- follows: hide follow edges that touch a blocked user (keeps blocked users out
-- of follower/following lists for both parties).
drop policy if exists "follows_select_all" on follows;
create policy "follows_select_visible" on follows for select
  using (
    not is_blocked(auth.uid(), follower_id)
    and not is_blocked(auth.uid(), following_id)
  );

-- ════════════════════════════════════════════════════════════════════════════
-- On block: remove any existing follow edges in BOTH directions.
-- ════════════════════════════════════════════════════════════════════════════

create or replace function purge_follows_on_block()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  delete from follows
  where (follower_id = new.blocker_id and following_id = new.blocked_id)
     or (follower_id = new.blocked_id and following_id = new.blocker_id);
  return new;
end;
$$;

drop trigger if exists trg_purge_follows_on_block on blocks;
create trigger trg_purge_follows_on_block
  after insert on blocks
  for each row execute function purge_follows_on_block();
