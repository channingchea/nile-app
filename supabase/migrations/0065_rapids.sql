-- 0065: Rapids — ≤60s short-form video snippets (docs/plans/rapids.md, Phase 1).
--
-- Content model: any user posts a Rapid (video + optional caption); it is
-- publicly visible for 24h (expires_at), then hidden everywhere except the
-- creator's own archive, and purged from storage+DB 30 days after expiry.
-- Moderation mirrors 0053: soft-removal columns + admin-aware select policies;
-- the report enum/queue extensions land in 0066/0067 (enum values can't be
-- added and used in one transaction).
--
-- Engagement mirrors phase10 (likes/comments w/ counter triggers) plus a
-- dedup'd per-viewer view log that powers view counts AND the rail's
-- watched/unwatched ring.

-- ── rapids ───────────────────────────────────────────────────────────────────
create table public.rapids (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  -- storage paths in the 'rapids' bucket: <uid>/<ts>.mp4 / <uid>/<ts>.jpg
  video_path    text not null,
  thumb_path    text,
  caption       text check (caption is null or char_length(caption) <= 200),
  duration_ms   int  not null check (duration_ms > 0 and duration_ms <= 61000),
  like_count    int  not null default 0,
  comment_count int  not null default 0,
  view_count    int  not null default 0,
  removed_at    timestamptz,
  removed_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  expires_at    timestamptz not null default now() + interval '24 hours'
);

create index rapids_user_created_idx on public.rapids (user_id, created_at desc);
-- Serving scan: live (unexpired, unremoved) rapids.
create index rapids_live_idx on public.rapids (expires_at) where removed_at is null;

alter table public.rapids enable row level security;

-- Visible while live; the creator always sees their own (archive); admins see
-- removed rows (0053 posture); blocked users never see each other's.
create policy "rapids_select_visible" on public.rapids for select
  using (
    (removed_at is null or is_admin())
    and not is_blocked(auth.uid(), user_id)
    and (expires_at > now() or user_id = auth.uid() or is_admin())
  );
create policy "rapids_insert_own" on public.rapids for insert
  with check (user_id = auth.uid());
create policy "rapids_delete_own" on public.rapids for delete
  using (user_id = auth.uid());

-- ── rapid_likes ──────────────────────────────────────────────────────────────
create table public.rapid_likes (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  rapid_id   uuid not null references public.rapids(id)   on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, rapid_id)
);
create index rapid_likes_rapid_idx on public.rapid_likes (rapid_id);

alter table public.rapid_likes enable row level security;
create policy "rapid_likes_select_all" on public.rapid_likes for select using (true);
create policy "rapid_likes_insert_own" on public.rapid_likes for insert with check (user_id = auth.uid());
create policy "rapid_likes_delete_own" on public.rapid_likes for delete using (user_id = auth.uid());

create or replace function public.bump_rapid_like_count()
returns trigger
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if (tg_op = 'INSERT') then
    update rapids set like_count = like_count + 1 where id = new.rapid_id;
    return new;
  elsif (tg_op = 'DELETE') then
    update rapids set like_count = greatest(0, like_count - 1) where id = old.rapid_id;
    return old;
  end if;
  return null;
end;
$$;
revoke execute on function public.bump_rapid_like_count() from public, anon, authenticated;

create trigger rapid_likes_count_ins after insert on public.rapid_likes
  for each row execute function public.bump_rapid_like_count();
create trigger rapid_likes_count_del after delete on public.rapid_likes
  for each row execute function public.bump_rapid_like_count();

-- ── rapid_comments (flat, with 0053-style soft removal) ──────────────────────
create table public.rapid_comments (
  id         uuid primary key default gen_random_uuid(),
  rapid_id   uuid not null references public.rapids(id)   on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  body       text not null check (length(trim(body)) > 0 and char_length(body) <= 500),
  removed_at timestamptz,
  removed_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index rapid_comments_rapid_created_idx
  on public.rapid_comments (rapid_id, created_at desc);

alter table public.rapid_comments enable row level security;
create policy "rapid_comments_select_visible" on public.rapid_comments for select
  using (
    (removed_at is null or is_admin())
    and not is_blocked(auth.uid(), user_id)
  );
create policy "rapid_comments_insert_own" on public.rapid_comments for insert
  with check (user_id = auth.uid());
create policy "rapid_comments_delete_own" on public.rapid_comments for delete
  using (user_id = auth.uid());

create or replace function public.bump_rapid_comment_count()
returns trigger
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if (tg_op = 'INSERT') then
    update rapids set comment_count = comment_count + 1 where id = new.rapid_id;
    return new;
  elsif (tg_op = 'DELETE') then
    update rapids set comment_count = greatest(0, comment_count - 1) where id = old.rapid_id;
    return old;
  end if;
  return null;
end;
$$;
revoke execute on function public.bump_rapid_comment_count() from public, anon, authenticated;

create trigger rapid_comments_count_ins after insert on public.rapid_comments
  for each row execute function public.bump_rapid_comment_count();
create trigger rapid_comments_count_del after delete on public.rapid_comments
  for each row execute function public.bump_rapid_comment_count();

-- ── rapid_views — dedup'd per-viewer view log ────────────────────────────────
-- One row per (viewer, rapid): drives view_count AND the watched/unwatched
-- ring. Insert-only from clients; the count trigger fires once per pair.
create table public.rapid_views (
  viewer_id  uuid not null references public.profiles(id) on delete cascade,
  rapid_id   uuid not null references public.rapids(id)   on delete cascade,
  created_at timestamptz not null default now(),
  primary key (viewer_id, rapid_id)
);
create index rapid_views_rapid_idx on public.rapid_views (rapid_id);

alter table public.rapid_views enable row level security;
create policy "rapid_views_select_own" on public.rapid_views for select
  using (viewer_id = auth.uid());
create policy "rapid_views_insert_own" on public.rapid_views for insert
  with check (viewer_id = auth.uid());

create or replace function public.bump_rapid_view_count()
returns trigger
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $$
begin
  update rapids set view_count = view_count + 1 where id = new.rapid_id;
  return new;
end;
$$;
revoke execute on function public.bump_rapid_view_count() from public, anon, authenticated;

create trigger rapid_views_count_ins after insert on public.rapid_views
  for each row execute function public.bump_rapid_view_count();

-- ── Storage bucket ───────────────────────────────────────────────────────────
-- Public-read like 'posts', but writes are prefix-scoped to the uploader's uid
-- (tighter than the legacy posts policy).
insert into storage.buckets (id, name, public)
values ('rapids', 'rapids', true)
on conflict (id) do nothing;

create policy "rapids_storage_public_read"
  on storage.objects for select using (bucket_id = 'rapids');
create policy "rapids_storage_owner_write"
  on storage.objects for insert
  with check (
    bucket_id = 'rapids'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "rapids_storage_owner_delete"
  on storage.objects for delete
  using (
    bucket_id = 'rapids'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ── get_rapids_rail — one row per creator for the home-screen rail ───────────
-- SECURITY INVOKER: rapids RLS (blocks, removal, expiry) applies as-is.
-- Order: followed creators first, then unwatched first, then most recent.
-- The caller is excluded — the client renders its own "Your Rapid" slot.
-- Non-followed creators appearing after followed ones IS the "recommended
-- fill" at current scale.
create or replace function public.get_rapids_rail(page_limit int default 30)
returns table (
  user_id         uuid,
  username        text,
  avatar_url      text,
  is_official     boolean,
  rapid_count     bigint,
  latest_rapid_at timestamptz,
  has_unwatched   boolean,
  is_followed     boolean
)
language sql
stable
set search_path = pg_catalog, public, pg_temp
as $$
  select
    r.user_id,
    p.username,
    p.avatar_url,
    p.is_official,
    count(*)                        as rapid_count,
    max(r.created_at)               as latest_rapid_at,
    bool_or(v.viewer_id is null)    as has_unwatched,
    bool_or(f.follower_id is not null) as is_followed
  from rapids r
  join profiles p on p.id = r.user_id
  left join rapid_views v on v.rapid_id = r.id and v.viewer_id = auth.uid()
  left join follows f on f.follower_id = auth.uid() and f.following_id = r.user_id
  where r.expires_at > now()
    and r.removed_at is null
    and r.user_id <> auth.uid()
  group by r.user_id, p.username, p.avatar_url, p.is_official
  order by
    bool_or(f.follower_id is not null) desc,
    bool_or(v.viewer_id is null) desc,
    max(r.created_at) desc
  limit page_limit;
$$;
grant execute on function public.get_rapids_rail(int) to authenticated;

-- ── get_rapids_feed — the playable list, in rail order ───────────────────────
-- Same ordering keys as the rail (followed → unwatched → newest creator),
-- oldest-first WITHIN a creator (stories semantics). The client jumps the
-- pager to the tapped creator's first item; swiping continues into the next
-- creator naturally. SECURITY INVOKER, same reasoning as above.
create or replace function public.get_rapids_feed(page_limit int default 200)
returns table (
  id            uuid,
  user_id       uuid,
  username      text,
  avatar_url    text,
  is_official   boolean,
  video_path    text,
  thumb_path    text,
  caption       text,
  duration_ms   int,
  like_count    int,
  comment_count int,
  view_count    int,
  created_at    timestamptz,
  liked_by_me   boolean,
  watched_by_me boolean,
  is_followed   boolean
)
language sql
stable
set search_path = pg_catalog, public, pg_temp
as $$
  select
    r.id, r.user_id, p.username, p.avatar_url, p.is_official,
    r.video_path, r.thumb_path, r.caption, r.duration_ms,
    r.like_count, r.comment_count, r.view_count, r.created_at,
    (l.user_id  is not null) as liked_by_me,
    (v.viewer_id is not null) as watched_by_me,
    (f.follower_id is not null) as is_followed
  from rapids r
  join profiles p on p.id = r.user_id
  left join rapid_likes l on l.rapid_id = r.id and l.user_id  = auth.uid()
  left join rapid_views v on v.rapid_id = r.id and v.viewer_id = auth.uid()
  left join follows f on f.follower_id = auth.uid() and f.following_id = r.user_id
  where r.expires_at > now()
    and r.removed_at is null
    and r.user_id <> auth.uid()
  order by
    (f.follower_id is not null) desc,
    bool_or(v.viewer_id is null) over (partition by r.user_id) desc,
    max(r.created_at) over (partition by r.user_id) desc,
    r.user_id,
    r.created_at asc
  limit page_limit;
$$;
grant execute on function public.get_rapids_feed(int) to authenticated;

-- ── Retention: purge 30 days after expiry ────────────────────────────────────
-- Mirrors purge_expired_replays (0024): storage objects FIRST (video + thumb),
-- rows second, so a partial storage failure retries next run with no orphaned
-- rows. Rapids a user deletes themselves have their objects removed client-side
-- (owner-delete storage policy above).
create or replace function public.purge_expired_rapids(p_grace_days int default 30)
returns integer
language plpgsql
security definer
set search_path = public, storage, pg_temp
as $$
declare
  v_count integer;
begin
  -- Supabase's storage.protect_delete trigger blocks direct deletes unless
  -- this transaction-local GUC is set (0036 pattern).
  perform set_config('storage.allow_delete_query', 'true', true);

  delete from storage.objects o
   using public.rapids r
   where o.bucket_id = 'rapids'
     and o.name in (r.video_path, r.thumb_path)
     and r.expires_at < now() - make_interval(days => p_grace_days);

  with purged as (
    delete from public.rapids
     where expires_at < now() - make_interval(days => p_grace_days)
    returning id
  )
  select count(*) into v_count from purged;
  return v_count;
end;
$$;
revoke execute on function public.purge_expired_rapids(int) from public, anon, authenticated;

comment on function public.purge_expired_rapids(int) is
  'Cron-invoked: deletes rapid storage objects + rows 30 days after expiry.';

-- Daily at 04:20 UTC (off-peak, staggered after the replay purge at 04:00).
select cron.schedule(
  'purge-expired-rapids',
  '20 4 * * *',
  $$ select public.purge_expired_rapids(30); $$
);
