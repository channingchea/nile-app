-- Phase 18: Notification preferences
-- One row per user, one boolean column per notification_type (all default true).
-- A single helper notif_enabled(uid, type) gates every notification insert, so
-- the phase 11 triggers (and, once deployed, the phase 16/17 fanout) honour it.
--
-- IMPORTANT: run this file in TWO steps. Postgres won't let a newly added enum
-- value be USED in the same transaction that adds it, and the Supabase SQL editor
-- runs a selection as one transaction. Run STEP 1, let it commit, then run STEP 2.

-- ════════════════════════════════════════════════════════════════════════════
-- STEP 1 — run this block on its own first, then run STEP 2 below.
-- ════════════════════════════════════════════════════════════════════════════

-- The phase 11 enum only had post_like/post_comment/follow. Phases 16/17 add the
-- event_* values but are deferred/unrun, so add them here (idempotent). These
-- must commit before STEP 2 references them.
alter type notification_type add value if not exists 'event_starting';
alter type notification_type add value if not exists 'event_live';
alter type notification_type add value if not exists 'event_ended';

-- ════════════════════════════════════════════════════════════════════════════
-- STEP 2 — run everything below this line after STEP 1 has committed.
-- ════════════════════════════════════════════════════════════════════════════

-- ── Table ─────────────────────────────────────────────────────────────────────

create table if not exists notification_preferences (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  post_like      boolean not null default true,
  post_comment   boolean not null default true,
  follow         boolean not null default true,
  event_starting boolean not null default true,
  event_live     boolean not null default true,
  event_ended    boolean not null default true,
  updated_at     timestamptz not null default now()
);

-- ── RLS ───────────────────────────────────────────────────────────────────────

alter table notification_preferences enable row level security;

drop policy if exists "notif_prefs_select" on notification_preferences;
create policy "notif_prefs_select"
  on notification_preferences for select
  using (user_id = auth.uid());

drop policy if exists "notif_prefs_insert" on notification_preferences;
create policy "notif_prefs_insert"
  on notification_preferences for insert
  with check (user_id = auth.uid());

drop policy if exists "notif_prefs_update" on notification_preferences;
create policy "notif_prefs_update"
  on notification_preferences for update
  using (user_id = auth.uid());

-- ── Auto-create a default row when a profile is created ───────────────────────

create or replace function create_default_notification_preferences()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into notification_preferences(user_id)
  values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists trg_default_notif_prefs on profiles;
create trigger trg_default_notif_prefs
  after insert on profiles
  for each row execute function create_default_notification_preferences();

-- Backfill rows for existing users.
insert into notification_preferences(user_id)
select id from profiles
on conflict (user_id) do nothing;

-- ── Helper: is a given notification type enabled for a recipient? ─────────────
-- Returns NULL when no preferences row exists; callers treat NULL as enabled
-- (fail-open: never silently drop a notification because a row is missing).

create or replace function notif_enabled(p_uid uuid, p_type notification_type)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case p_type
      when 'post_like'      then post_like
      when 'post_comment'   then post_comment
      when 'follow'         then follow
      when 'event_starting' then event_starting
      when 'event_live'     then event_live
      when 'event_ended'    then event_ended
    end
  from notification_preferences
  where user_id = p_uid;
$$;

-- ── Re-gate phase 11 triggers ─────────────────────────────────────────────────
-- Function bodies replaced to skip recipients who disabled the type. Triggers
-- themselves are unchanged (still bound from phase 11).

create or replace function notify_post_like()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_author_id uuid;
begin
  select user_id into v_author_id from posts where id = new.post_id;
  if v_author_id is null or v_author_id = new.user_id then
    return new;
  end if;
  if notif_enabled(v_author_id, 'post_like') is false then
    return new;
  end if;
  insert into notifications(recipient_id, actor_id, type, entity_id)
  values (v_author_id, new.user_id, 'post_like', new.post_id);
  return new;
end;
$$;

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
  if v_author_id is null or v_author_id = new.user_id then
    return new;
  end if;
  if notif_enabled(v_author_id, 'post_comment') is false then
    return new;
  end if;
  insert into notifications(recipient_id, actor_id, type, entity_id)
  values (v_author_id, new.user_id, 'post_comment', new.post_id);
  return new;
end;
$$;

create or replace function notify_follow()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.follower_id = new.following_id then
    return new;
  end if;
  if notif_enabled(new.following_id, 'follow') is false then
    return new;
  end if;
  insert into notifications(recipient_id, actor_id, type, entity_id)
  values (new.following_id, new.follower_id, 'follow', null);
  return new;
end;
$$;

-- ── Event-notification gating is deferred ─────────────────────────────────────
-- Phases 16/17 (fanout_event_starting / fanout_event_notification) are NOT yet
-- deployed. When that workflow is reworked and run, add the per-recipient filter
--   and notif_enabled(uid, <type>) is not false
-- to each fanout's recipients query. The columns + helper above are already in
-- place, so no further schema change is needed there.
