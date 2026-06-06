-- Roadmap #6: Sharing / social distribution.
-- (a) Pointer reposts. (b) Share a post via DM (rich card). Mirrors existing
-- post_likes counter/RLS patterns (see phase10_engagement.sql).

-- ── reposts ────────────────────────────────────────────────────────────────────
create table if not exists reposts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  post_id    uuid not null references posts(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (user_id, post_id)
);
create index if not exists reposts_post_idx on reposts (post_id);
-- For the feed union: a user's reposts newest-first.
create index if not exists reposts_user_created_idx on reposts (user_id, created_at desc);

alter table reposts enable row level security;
drop policy if exists "reposts_select_all" on reposts;
drop policy if exists "reposts_insert_own" on reposts;
drop policy if exists "reposts_delete_own" on reposts;
create policy "reposts_select_all" on reposts for select using (true);
create policy "reposts_insert_own" on reposts for insert with check (user_id = auth.uid());
create policy "reposts_delete_own" on reposts for delete using (user_id = auth.uid());

-- ── posts.repost_count + trigger ───────────────────────────────────────────────
alter table posts add column if not exists repost_count int not null default 0;

create or replace function bump_post_repost_count()
returns trigger language plpgsql security definer as $$
begin
  if (tg_op = 'INSERT') then
    update posts set repost_count = repost_count + 1 where id = new.post_id;
  elsif (tg_op = 'DELETE') then
    update posts set repost_count = greatest(0, repost_count - 1) where id = old.post_id;
  end if;
  return null;
end;
$$;

drop trigger if exists reposts_count_ins on reposts;
drop trigger if exists reposts_count_del on reposts;
create trigger reposts_count_ins after insert on reposts
  for each row execute function bump_post_repost_count();
create trigger reposts_count_del after delete on reposts
  for each row execute function bump_post_repost_count();

-- Backfill (idempotent re-run safety).
update posts
  set repost_count = coalesce((select count(*) from reposts where reposts.post_id = posts.id), 0);

-- ── messages.shared_post_id (share a post via DM) ──────────────────────────────
-- Nullable: a normal message has no shared post. The existing content CHECK
-- (1..1000) still applies, so a share message carries a short auto caption.
alter table messages
  add column if not exists shared_post_id uuid references posts(id) on delete set null;
