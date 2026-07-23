-- 0060: Security hardening fix #5 — anon/authenticated can no longer directly
-- EXECUTE internal SECURITY DEFINER helpers (e.g. confirm_ticket could flip an
-- arbitrary payment intent's ticket to 'paid'). Triggers run as the table
-- owner and cron as postgres, so revoking client roles is safe; edge functions
-- use the service role, which retains EXECUTE (same pattern as tally_ad_spend).
--
-- EXECUTE is kept on:
--  * client-called RPCs: assign_event_operator, increment/decrement_viewer_count,
--    notify_soundcheck_open, publish_replay, tickets_remaining,
--    host_ticket_earnings, get_conversations_for_user, get_feed_ads,
--    get_advertiser_performance, get_advertiser_daily, get_boost_performance,
--    get_report_queue, recommend_* (verified against app + portal code — the
--    audit plan's revoke list wrongly included the first three)
--  * RLS policy helpers evaluated as the querying role: is_admin, is_blocked,
--    is_event_host, can_edit_pending_ad

-- Webhook / server-only helpers
revoke execute on function public.confirm_ticket(text, text) from public, anon, authenticated;
revoke execute on function public.fanout_event_notification(uuid, notification_type, text) from public, anon, authenticated;
revoke execute on function public.fanout_event_starting(uuid) from public, anon, authenticated;
revoke execute on function public.fanout_replay_ready(uuid) from public, anon, authenticated;
revoke execute on function public.notify_replay_ready(uuid) from public, anon, authenticated;
revoke execute on function public.notif_enabled(uuid, notification_type) from public, anon, authenticated;

-- Cron / maintenance
revoke execute on function public.auto_end_expired_events(integer) from public, anon, authenticated;
revoke execute on function public.auto_publish_replays(integer) from public, anon, authenticated;
revoke execute on function public.fail_stuck_replays(integer) from public, anon, authenticated;
revoke execute on function public.purge_expired_replays(integer) from public, anon, authenticated;
revoke execute on function public.cleanup_abandoned_ad_checkouts() from public, anon, authenticated;

-- Trigger functions (the trigger owner runs them; no client role needs EXECUTE)
revoke execute on function public.bump_event_like_count() from public, anon, authenticated;
revoke execute on function public.bump_event_repost_count() from public, anon, authenticated;
revoke execute on function public.bump_post_comment_count() from public, anon, authenticated;
revoke execute on function public.bump_post_like_count() from public, anon, authenticated;
revoke execute on function public.bump_post_repost_count() from public, anon, authenticated;
revoke execute on function public.create_default_notification_preferences() from public, anon, authenticated;
revoke execute on function public.enforce_paid_publish_payable() from public, anon, authenticated;
revoke execute on function public.handle_follow_change() from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.notify_event_status_change() from public, anon, authenticated;
revoke execute on function public.notify_follow() from public, anon, authenticated;
revoke execute on function public.notify_message_reaction() from public, anon, authenticated;
revoke execute on function public.notify_post_comment() from public, anon, authenticated;
revoke execute on function public.notify_post_like() from public, anon, authenticated;
revoke execute on function public.on_notification_push() from public, anon, authenticated;
revoke execute on function public.purge_follows_on_block() from public, anon, authenticated;
revoke execute on function public.strip_app_check_token() from public, anon, authenticated;
revoke execute on function public.touch_post_comments_updated_at() from public, anon, authenticated;
revoke execute on function public.touch_posts_updated_at() from public, anon, authenticated;
revoke execute on function public.update_conversation_last_message() from public, anon, authenticated;
revoke execute on function public.update_follow_counts() from public, anon, authenticated;
