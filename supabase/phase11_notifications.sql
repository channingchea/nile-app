-- Phase 11: Notifications
-- Run this entire file in the Supabase SQL editor.
-- All trigger functions use SECURITY DEFINER (same pattern as phase10_fix_counters.sql)
-- so they can INSERT into notifications rows owned by a different user.

-- ── Table ─────────────────────────────────────────────────────────────────────

do $$ begin
  create type notification_type as enum ('post_like', 'post_comment', 'follow');
exception when duplicate_object then null;
end $$;

create table if not exists notifications (
  id            uuid primary key default gen_random_uuid(),
  recipient_id  uuid not null references auth.users(id) on delete cascade,
  actor_id      uuid not null references auth.users(id) on delete cascade,
  type          notification_type not null,
  -- entity_id points to the relevant row: post_id for post_like/post_comment,
  -- null for follow (the actor IS the entity).
  entity_id     uuid,
  read_at       timestamptz,
  created_at    timestamptz not null default now()
);

-- ── Indexes ───────────────────────────────────────────────────────────────────

-- Primary read path: newest notifications for a recipient.
create index if not exists notifications_recipient_created_idx
  on notifications(recipient_id, created_at desc);

-- Unread badge count — partial index, only unread rows.
create index if not exists notifications_unread_idx
  on notifications(recipient_id)
  where read_at is null;

-- ── RLS ───────────────────────────────────────────────────────────────────────

alter table notifications enable row level security;

-- Recipients can read their own notifications.
create policy "notifications_select"
  on notifications for select
  using (recipient_id = auth.uid());

-- Recipients can update (mark read) their own notifications.
create policy "notifications_update"
  on notifications for update
  using (recipient_id = auth.uid());

-- No direct insert/delete from clients; triggers handle inserts,
-- and deletes are cascade-only (when the user or content is removed).

-- ── Trigger: post_like → post_like notification ───────────────────────────────

create or replace function notify_post_like()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_author_id uuid;
begin
  -- Look up the post author.
  select user_id into v_author_id from posts where id = new.post_id;

  -- Skip self-likes.
  if v_author_id is null or v_author_id = new.user_id then
    return new;
  end if;

  insert into notifications(recipient_id, actor_id, type, entity_id)
  values (v_author_id, new.user_id, 'post_like', new.post_id);

  return new;
end;
$$;

drop trigger if exists trg_notify_post_like on post_likes;
create trigger trg_notify_post_like
  after insert on post_likes
  for each row execute function notify_post_like();

-- ── Trigger: post_comment → post_comment notification ────────────────────────

create or replace function notify_post_comment()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_author_id uuid;
begin
  select user_id into v_author_id from posts where id = new.post_id;

  -- Skip self-comments.
  if v_author_id is null or v_author_id = new.user_id then
    return new;
  end if;

  insert into notifications(recipient_id, actor_id, type, entity_id)
  values (v_author_id, new.user_id, 'post_comment', new.post_id);

  return new;
end;
$$;

drop trigger if exists trg_notify_post_comment on post_comments;
create trigger trg_notify_post_comment
  after insert on post_comments
  for each row execute function notify_post_comment();

-- ── Trigger: follow → follow notification ─────────────────────────────────────

create or replace function notify_follow()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Skip self-follows (shouldn't happen, but be defensive).
  if new.follower_id = new.following_id then
    return new;
  end if;

  insert into notifications(recipient_id, actor_id, type, entity_id)
  values (new.following_id, new.follower_id, 'follow', null);

  return new;
end;
$$;

drop trigger if exists trg_notify_follow on follows;
create trigger trg_notify_follow
  after insert on follows
  for each row execute function notify_follow();
