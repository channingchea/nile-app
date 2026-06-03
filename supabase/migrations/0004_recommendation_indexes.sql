-- Indexes supporting follow-graph recommendation queries.
-- Like tables are PK'd on (post_id|event_id, user_id), so a user_id-leading
-- lookup (match likes against followed users) isn't covered.
create index if not exists post_likes_user_id_idx on public.post_likes (user_id);
create index if not exists event_likes_user_id_idx on public.event_likes (user_id);

-- follows is PK'd on (follower_id, following_id); the following_id join side
-- (find who a followee is) is uncovered.
create index if not exists follows_following_id_idx on public.follows (following_id);
