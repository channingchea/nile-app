-- Phase 9: Posts — additive setup against an existing `posts` table.
-- Existing schema (assumed):
--   id uuid pk, user_id uuid, content text, image_url text,
--   like_count int, event_id uuid, created_at timestamptz, updated_at timestamptz
--
-- Idempotent. Dynamically clears any pre-existing policies that might
-- reference long-gone columns (e.g. author_id).

-- ── Drop ALL existing policies on posts ───────────────────────────────────────
do $$
declare r record;
begin
  for r in
    select polname from pg_policy where polrelid = 'posts'::regclass
  loop
    execute format('drop policy %I on posts', r.polname);
  end loop;
end $$;

-- ── Drop any leftover CHECK constraints that reference a missing column ──────
do $$
declare r record;
begin
  for r in
    select conname
    from pg_constraint
    where conrelid = 'posts'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%author_id%'
  loop
    execute format('alter table posts drop constraint %I', r.conname);
  end loop;
end $$;

-- ── Foreign keys (added only if missing) ─────────────────────────────────────
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'posts_user_id_fkey'
  ) then
    alter table posts
      add constraint posts_user_id_fkey
      foreign key (user_id) references profiles(id) on delete cascade;
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'posts_event_id_fkey'
  ) then
    alter table posts
      add constraint posts_event_id_fkey
      foreign key (event_id) references events(id) on delete set null;
  end if;
end $$;

-- ── Content guard: a post must have text content or an image ─────────────────
alter table posts drop constraint if exists posts_has_content;
alter table posts add constraint posts_has_content check (
  (content is not null and length(trim(content)) > 0) or image_url is not null
);

-- ── RLS ───────────────────────────────────────────────────────────────────────
alter table posts enable row level security;

create policy "posts_select_all" on posts for select using (true);
create policy "posts_insert_own" on posts for insert with check (user_id = auth.uid());
create policy "posts_update_own" on posts for update using (user_id = auth.uid());
create policy "posts_delete_own" on posts for delete using (user_id = auth.uid());

-- ── Indexes ───────────────────────────────────────────────────────────────────
create index if not exists posts_user_created_idx on posts (user_id, created_at desc);
create index if not exists posts_created_idx      on posts (created_at desc);
create index if not exists posts_event_idx        on posts (event_id) where event_id is not null;

-- ── Auto-bump updated_at on update ───────────────────────────────────────────
create or replace function touch_posts_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists posts_touch_updated_at on posts;
create trigger posts_touch_updated_at
  before update on posts
  for each row execute function touch_posts_updated_at();
