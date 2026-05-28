-- Phase 10 fix: counter triggers were blocked by RLS on posts/events.
-- Run this once in the Supabase SQL Editor.
--
-- Root cause: trigger functions ran as the calling user (SECURITY INVOKER).
-- When user A liked user B's post, the trigger's UPDATE posts ...
-- was filtered by `posts_update_own` (user_id = auth.uid()) — RLS hid the
-- target row, the UPDATE matched zero rows, and no error was raised.
-- Fix: SECURITY DEFINER so the function runs as its owner (bypasses RLS).

-- ── Recreate functions as SECURITY DEFINER ───────────────────────────────────
create or replace function bump_post_like_count()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if (tg_op = 'INSERT') then
    update posts set like_count = like_count + 1 where id = new.post_id;
    return new;
  elsif (tg_op = 'DELETE') then
    update posts set like_count = greatest(0, like_count - 1) where id = old.post_id;
    return old;
  end if;
  return null;
end;
$$;

create or replace function bump_event_like_count()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if (tg_op = 'INSERT') then
    update events set like_count = like_count + 1 where id = new.event_id;
    return new;
  elsif (tg_op = 'DELETE') then
    update events set like_count = greatest(0, like_count - 1) where id = old.event_id;
    return old;
  end if;
  return null;
end;
$$;

create or replace function bump_post_comment_count()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if (tg_op = 'INSERT') then
    update posts set comment_count = comment_count + 1 where id = new.post_id;
    return new;
  elsif (tg_op = 'DELETE') then
    update posts set comment_count = greatest(0, comment_count - 1) where id = old.post_id;
    return old;
  end if;
  return null;
end;
$$;

-- ── Backfill drift from likes/comments that weren't counted ──────────────────
update posts
  set like_count    = coalesce((select count(*) from post_likes    where post_likes.post_id = posts.id), 0),
      comment_count = coalesce((select count(*) from post_comments where post_comments.post_id = posts.id), 0);

update events
  set like_count = coalesce((select count(*) from event_likes where event_likes.event_id = events.id), 0);
