-- Phase 10: Engagement — likes on posts + events, comments on posts.
-- Idempotent. Run in Supabase SQL editor.

-- ── Counter columns (add if missing) ─────────────────────────────────────────
alter table events add column if not exists like_count    int not null default 0;
alter table posts  add column if not exists comment_count int not null default 0;
-- like_count already exists on posts per the existing schema.

-- ── post_likes ───────────────────────────────────────────────────────────────
create table if not exists post_likes (
  user_id    uuid not null references profiles(id) on delete cascade,
  post_id    uuid not null references posts(id)    on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, post_id)
);
create index if not exists post_likes_post_idx on post_likes (post_id);

alter table post_likes enable row level security;

drop policy if exists "post_likes_select_all" on post_likes;
drop policy if exists "post_likes_insert_own" on post_likes;
drop policy if exists "post_likes_delete_own" on post_likes;

create policy "post_likes_select_all" on post_likes for select using (true);
create policy "post_likes_insert_own" on post_likes for insert with check (user_id = auth.uid());
create policy "post_likes_delete_own" on post_likes for delete using (user_id = auth.uid());

-- Counter triggers.
create or replace function bump_post_like_count()
returns trigger language plpgsql as $$
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

drop trigger if exists post_likes_count_ins on post_likes;
drop trigger if exists post_likes_count_del on post_likes;
create trigger post_likes_count_ins after insert on post_likes
  for each row execute function bump_post_like_count();
create trigger post_likes_count_del after delete on post_likes
  for each row execute function bump_post_like_count();

-- ── event_likes ──────────────────────────────────────────────────────────────
create table if not exists event_likes (
  user_id    uuid not null references profiles(id) on delete cascade,
  event_id   uuid not null references events(id)   on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, event_id)
);
create index if not exists event_likes_event_idx on event_likes (event_id);

alter table event_likes enable row level security;

drop policy if exists "event_likes_select_all" on event_likes;
drop policy if exists "event_likes_insert_own" on event_likes;
drop policy if exists "event_likes_delete_own" on event_likes;

create policy "event_likes_select_all" on event_likes for select using (true);
create policy "event_likes_insert_own" on event_likes for insert with check (user_id = auth.uid());
create policy "event_likes_delete_own" on event_likes for delete using (user_id = auth.uid());

create or replace function bump_event_like_count()
returns trigger language plpgsql as $$
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

drop trigger if exists event_likes_count_ins on event_likes;
drop trigger if exists event_likes_count_del on event_likes;
create trigger event_likes_count_ins after insert on event_likes
  for each row execute function bump_event_like_count();
create trigger event_likes_count_del after delete on event_likes
  for each row execute function bump_event_like_count();

-- ── post_comments (flat) ─────────────────────────────────────────────────────
create table if not exists post_comments (
  id         uuid        primary key default gen_random_uuid(),
  post_id    uuid        not null references posts(id)    on delete cascade,
  user_id    uuid        not null references profiles(id) on delete cascade,
  body       text        not null check (length(trim(body)) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists post_comments_post_created_idx
  on post_comments (post_id, created_at desc);

alter table post_comments enable row level security;

drop policy if exists "post_comments_select_all" on post_comments;
drop policy if exists "post_comments_insert_own" on post_comments;
drop policy if exists "post_comments_update_own" on post_comments;
drop policy if exists "post_comments_delete_own" on post_comments;

create policy "post_comments_select_all" on post_comments for select using (true);
create policy "post_comments_insert_own" on post_comments for insert with check (user_id = auth.uid());
create policy "post_comments_update_own" on post_comments for update using (user_id = auth.uid());
create policy "post_comments_delete_own" on post_comments for delete using (user_id = auth.uid());

create or replace function bump_post_comment_count()
returns trigger language plpgsql as $$
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

drop trigger if exists post_comments_count_ins on post_comments;
drop trigger if exists post_comments_count_del on post_comments;
create trigger post_comments_count_ins after insert on post_comments
  for each row execute function bump_post_comment_count();
create trigger post_comments_count_del after delete on post_comments
  for each row execute function bump_post_comment_count();

-- Touch updated_at on edit.
create or replace function touch_post_comments_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists post_comments_touch on post_comments;
create trigger post_comments_touch
  before update on post_comments
  for each row execute function touch_post_comments_updated_at();
