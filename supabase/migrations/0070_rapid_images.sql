-- 0070: Image Rapids — a Rapid can now be a multi-image slideshow instead of a
-- video. media_type distinguishes the two. Image slideshows keep their frames
-- in rapid_images (one row per image, each with its own 2–10s display time).
--
-- Video rapids are unchanged: media_type='video', video_path set.
-- Image rapids: media_type='image', video_path null, thumb_path = first image
-- (drives the rail ring + poster), duration_ms = sum of frame durations (total
-- slideshow length, ≤60s).

alter table public.rapids
  add column media_type text not null default 'video'
    check (media_type in ('video', 'image'));

-- video_path is only required for video rapids now.
alter table public.rapids alter column video_path drop not null;
alter table public.rapids
  add constraint rapids_media_shape check (
    (media_type = 'video' and video_path is not null) or
    (media_type = 'image' and video_path is null)
  );

-- ── rapid_images — ordered slideshow frames ──────────────────────────────────
create table public.rapid_images (
  id          uuid primary key default gen_random_uuid(),
  rapid_id    uuid not null references public.rapids(id) on delete cascade,
  position    int  not null,
  image_path  text not null,           -- <uid>/<ts>_<n>.jpg in the rapids bucket
  duration_ms int  not null check (duration_ms between 2000 and 10000),
  unique (rapid_id, position)
);
create index rapid_images_rapid_idx on public.rapid_images (rapid_id, position);

alter table public.rapid_images enable row level security;

-- Visibility delegates to the parent rapid (blocks / removal / expiry all apply
-- through the rapids RLS on this subquery).
create policy "rapid_images_select_visible" on public.rapid_images for select
  using (exists (select 1 from public.rapids r where r.id = rapid_id));
create policy "rapid_images_insert_own" on public.rapid_images for insert
  with check (exists (
    select 1 from public.rapids r where r.id = rapid_id and r.user_id = auth.uid()
  ));
create policy "rapid_images_delete_own" on public.rapid_images for delete
  using (exists (
    select 1 from public.rapids r where r.id = rapid_id and r.user_id = auth.uid()
  ));

-- ── get_rapids_feed — now carries media_type + the image list ────────────────
-- Return columns changed, so drop+recreate (create-or-replace can't alter the
-- OUT signature). Ordering keys are identical to 0065.
drop function if exists public.get_rapids_feed(int);
create function public.get_rapids_feed(page_limit int default 200)
returns table (
  id            uuid,
  user_id       uuid,
  username      text,
  avatar_url    text,
  is_official   boolean,
  media_type    text,
  video_path    text,
  thumb_path    text,
  images        jsonb,
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
    r.media_type, r.video_path, r.thumb_path,
    coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'path', ri.image_path,
                 'duration_ms', ri.duration_ms,
                 'position', ri.position)
               order by ri.position)
      from rapid_images ri where ri.rapid_id = r.id
    ), '[]'::jsonb) as images,
    r.caption, r.duration_ms,
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

-- ── Retention: also purge slideshow image objects ───────────────────────────
-- Extends 0065's purge to delete rapid_images storage objects before the row
-- cascade removes their rows.
create or replace function public.purge_expired_rapids(p_grace_days int default 30)
returns integer
language plpgsql
security definer
set search_path = public, storage, pg_temp
as $$
declare
  v_count integer;
begin
  perform set_config('storage.allow_delete_query', 'true', true);

  -- Video + poster objects.
  delete from storage.objects o
   using public.rapids r
   where o.bucket_id = 'rapids'
     and o.name in (r.video_path, r.thumb_path)
     and r.expires_at < now() - make_interval(days => p_grace_days);

  -- Slideshow frame objects.
  delete from storage.objects o
   using public.rapid_images ri
   join public.rapids r on r.id = ri.rapid_id
   where o.bucket_id = 'rapids'
     and o.name = ri.image_path
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
