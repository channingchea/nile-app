-- 0061: Security hardening fix #6 — pin search_path on the 13 functions the
-- advisor flags as function_search_path_mutable. Bodies reference public
-- tables unqualified, so pin to pg_catalog + public; pg_temp is listed LAST
-- explicitly (when unlisted it is implicitly searched FIRST, which is the
-- temp-table-shadowing attack vector for SECURITY DEFINER functions).

alter function public.update_follow_counts() set search_path = pg_catalog, public, pg_temp;
alter function public.handle_new_user() set search_path = pg_catalog, public, pg_temp;
alter function public.handle_follow_change() set search_path = pg_catalog, public, pg_temp;
alter function public.increment_viewer_count(text) set search_path = pg_catalog, public, pg_temp;
alter function public.decrement_viewer_count(text) set search_path = pg_catalog, public, pg_temp;
alter function public.touch_posts_updated_at() set search_path = pg_catalog, public, pg_temp;
alter function public.touch_post_comments_updated_at() set search_path = pg_catalog, public, pg_temp;
alter function public.update_conversation_last_message() set search_path = pg_catalog, public, pg_temp;
alter function public.recommend_events_from_network(integer) set search_path = pg_catalog, public, pg_temp;
alter function public.recommend_posts_from_network(integer) set search_path = pg_catalog, public, pg_temp;
alter function public.bump_post_repost_count() set search_path = pg_catalog, public, pg_temp;
alter function public.bump_event_repost_count() set search_path = pg_catalog, public, pg_temp;
alter function public.get_conversations_for_user() set search_path = pg_catalog, public, pg_temp;
