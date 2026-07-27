-- 0072: include the caller's own Currents in the home rail and the player feed.
-- Both RPCs previously excluded `user_id <> auth.uid()`, so a creator could
-- never see (or replay) what they just posted. Own slot sorts first, then
-- followed creators, then unwatched, then newest.

-- Return type gains is_self, so the old signatures must be dropped first.
drop function if exists public.get_currents_rail(integer);
drop function if exists public.get_currents_feed(integer);

create function public.get_currents_rail(page_limit integer default 30)
returns table(
  user_id uuid, username text, avatar_url text, is_official boolean,
  current_count bigint, latest_current_at timestamptz,
  has_unwatched boolean, is_followed boolean, is_self boolean)
language sql
stable
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $function$
  select
    r.user_id,
    p.username,
    p.avatar_url,
    p.is_official,
    count(*)                           as current_count,
    max(r.created_at)                  as latest_current_at,
    bool_or(v.viewer_id is null)       as has_unwatched,
    bool_or(f.follower_id is not null) as is_followed,
    (r.user_id = auth.uid())           as is_self
  from currents r
  join profiles p on p.id = r.user_id
  left join current_views v on v.current_id = r.id and v.viewer_id = auth.uid()
  left join follows f on f.follower_id = auth.uid() and f.following_id = r.user_id
  where r.expires_at > now()
    and r.removed_at is null
  group by r.user_id, p.username, p.avatar_url, p.is_official
  order by
    (r.user_id = auth.uid()) desc,
    bool_or(f.follower_id is not null) desc,
    bool_or(v.viewer_id is null) desc,
    max(r.created_at) desc
  limit page_limit;
$function$;

create function public.get_currents_feed(page_limit integer default 200)
returns table(
  id uuid, user_id uuid, username text, avatar_url text, is_official boolean,
  media_type text, video_path text, thumb_path text, images jsonb,
  caption text, duration_ms integer,
  like_count integer, comment_count integer, view_count integer,
  created_at timestamptz,
  liked_by_me boolean, watched_by_me boolean, is_followed boolean, is_self boolean)
language sql
stable
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $function$
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
      from current_images ri where ri.current_id = r.id
    ), '[]'::jsonb) as images,
    r.caption, r.duration_ms,
    r.like_count, r.comment_count, r.view_count, r.created_at,
    (l.user_id   is not null) as liked_by_me,
    (v.viewer_id is not null) as watched_by_me,
    (f.follower_id is not null) as is_followed,
    (r.user_id = auth.uid()) as is_self
  from currents r
  join profiles p on p.id = r.user_id
  left join current_likes l on l.current_id = r.id and l.user_id   = auth.uid()
  left join current_views v on v.current_id = r.id and v.viewer_id = auth.uid()
  left join follows f on f.follower_id = auth.uid() and f.following_id = r.user_id
  where r.expires_at > now()
    and r.removed_at is null
  order by
    (r.user_id = auth.uid()) desc,
    (f.follower_id is not null) desc,
    bool_or(v.viewer_id is null) over (partition by r.user_id) desc,
    max(r.created_at) over (partition by r.user_id) desc,
    r.user_id,
    r.created_at asc
  limit page_limit;
$function$;

grant execute on function public.get_currents_rail(integer) to anon, authenticated, service_role;
grant execute on function public.get_currents_feed(integer) to anon, authenticated, service_role;
