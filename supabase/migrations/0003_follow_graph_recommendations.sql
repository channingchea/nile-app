-- Recommendations: content liked by people you follow ("from your network").
-- Runs as the caller (SECURITY INVOKER), so posts/events RLS applies as usual.
-- Ranked by number of distinct followed users who liked it, then recency.
-- Excludes: your own content, items you've already liked, and users in a
-- bidirectional block relationship with you.

create or replace function public.recommend_posts_from_network(
  page_limit int default 20
)
returns setof posts
language sql
stable
as $$
  select p.*
  from posts p
  join post_likes pl on pl.post_id = p.id
  join follows f
    on f.following_id = pl.user_id
   and f.follower_id = auth.uid()
  where p.user_id <> auth.uid()
    and not exists (
      select 1 from post_likes me
      where me.post_id = p.id and me.user_id = auth.uid()
    )
    and not exists (
      select 1 from blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = p.user_id)
         or (b.blocked_id = auth.uid() and b.blocker_id = p.user_id)
    )
  group by p.id
  order by count(distinct pl.user_id) desc, max(pl.created_at) desc
  limit page_limit;
$$;

create or replace function public.recommend_events_from_network(
  page_limit int default 20
)
returns setof events
language sql
stable
as $$
  select e.*
  from events e
  join event_likes el on el.event_id = e.id
  join follows f
    on f.following_id = el.user_id
   and f.follower_id = auth.uid()
  where e.host_id <> auth.uid()
    and e.status <> 'ended'
    and not exists (
      select 1 from event_likes me
      where me.event_id = e.id and me.user_id = auth.uid()
    )
    and not exists (
      select 1 from blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = e.host_id)
         or (b.blocked_id = auth.uid() and b.blocker_id = e.host_id)
    )
  group by e.id
  order by count(distinct el.user_id) desc, max(el.created_at) desc
  limit page_limit;
$$;
