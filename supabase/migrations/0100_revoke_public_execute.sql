-- 0100_revoke_public_execute.sql
-- P0.1 — close the PUBLIC grant hole left by 0085, 0093 and 0094.
--
-- Postgres grants EXECUTE to the PUBLIC pseudo-role on every CREATE FUNCTION.
-- `revoke ... from anon, authenticated` does NOT remove that grant, and both
-- roles still inherit it — so those three migrations' revokes were silent
-- no-ops. 0060 and 0096 got the form right (`from public, anon, authenticated`);
-- everything since did not.
--
-- Verified on prod before writing this: `has_function_privilege('anon', ...)`
-- returned true for all of the functions below.
--
-- The worst of it: settle_ticket_checkout() is SECURITY DEFINER with no caller
-- check. Anyone could start a checkout, read their own session_id out of
-- ticket_checkouts (their own RLS policy allows exactly that), abandon Stripe,
-- then call the RPC directly to mint themselves a `paid` tickets row — the same
-- row the LiveKit viewer-token gate and gateReplayAccess check. Free entry to
-- every paid stream and every paid replay with only the publishable key.
--
-- service_role holds an explicit `service_role=X/postgres` grant on all of
-- these (checked in pg_proc.proacl), so revoking PUBLIC does not affect any
-- Edge Function. Client-callable functions are re-granted to `authenticated`
-- explicitly below rather than relying on the inherited PUBLIC grant.

begin;

-- ── Server-only: cron, Stripe webhook, and trigger bodies ──────────────────
-- No client of any kind should reach these.

revoke execute on function public.settle_ticket_checkout(text, text)
  from public, anon, authenticated;
revoke execute on function public.refund_ticket_checkout(text)
  from public, anon, authenticated;

revoke execute on function public.expire_abandoned_ticket_checkouts(integer)
  from public, anon, authenticated;
revoke execute on function public.purge_stale_drafts(integer)
  from public, anon, authenticated;

-- Dead code superseded by set_viewer_count() (0096), which was locked
-- correctly. 0085 flagged these as "anyone could pump or zero any event's
-- count" and tried to revoke them; the revoke never took effect.
revoke execute on function public.increment_viewer_count(text)
  from public, anon, authenticated;
revoke execute on function public.decrement_viewer_count(text)
  from public, anon, authenticated;

-- Trigger bodies. Calling them directly errors out, but they have no business
-- being on the client's menu at all.
revoke execute on function public.delete_event_replay_objects()
  from public, anon, authenticated;
revoke execute on function public.enqueue_sponsorship_refund_on_event_delete()
  from public, anon, authenticated;
revoke execute on function public.sponsorship_on_event_status()
  from public, anon, authenticated;

-- ── Signed-in only: internally guarded, but never anonymous ────────────────
-- Each of these checks the caller (host / admin / advertiser ownership) in its
-- own body, so `authenticated` is correct and `anon` never is. Re-granted
-- explicitly because the revoke below strips the inherited PUBLIC grant.

revoke execute on function public.assign_event_operator(uuid, uuid, uuid, boolean)
  from public, anon;
grant execute on function public.assign_event_operator(uuid, uuid, uuid, boolean)
  to authenticated;

revoke execute on function public.publish_replay(uuid, integer) from public, anon;
grant execute on function public.publish_replay(uuid, integer) to authenticated;

revoke execute on function public.notify_soundcheck_open(text) from public, anon;
grant execute on function public.notify_soundcheck_open(text) to authenticated;

revoke execute on function public.tickets_remaining(uuid) from public, anon;
grant execute on function public.tickets_remaining(uuid) to authenticated;

-- Host earnings dashboards — all self-scoped on auth.uid(), which is null for
-- anon, so this is hygiene rather than a live hole. 0094 already tried on the
-- first one and was defeated by the same PUBLIC grant.
revoke execute on function public.host_event_ticket_totals(uuid) from public, anon;
grant execute on function public.host_event_ticket_totals(uuid) to authenticated;

revoke execute on function public.host_ticket_earnings() from public, anon;
grant execute on function public.host_ticket_earnings() to authenticated;

revoke execute on function public.host_sponsorship_earnings() from public, anon;
grant execute on function public.host_sponsorship_earnings() to authenticated;

revoke execute on function public.host_sponsorship_offers() from public, anon;
grant execute on function public.host_sponsorship_offers() to authenticated;

revoke execute on function public.host_sponsorship_offer_count() from public, anon;
grant execute on function public.host_sponsorship_offer_count() to authenticated;

-- Advertiser portal (signed-in advertiser or admin).
revoke execute on function public.get_advertiser_daily(uuid, integer) from public, anon;
grant execute on function public.get_advertiser_daily(uuid, integer) to authenticated;

revoke execute on function public.get_advertiser_performance(uuid, integer, timestamptz)
  from public, anon;
grant execute on function public.get_advertiser_performance(uuid, integer, timestamptz)
  to authenticated;

revoke execute on function public.get_boost_performance() from public, anon;
grant execute on function public.get_boost_performance() to authenticated;

revoke execute on function public.get_sponsorable_events(text, integer) from public, anon;
grant execute on function public.get_sponsorable_events(text, integer) to authenticated;

revoke execute on function public.suggest_sponsorship_price(uuid) from public, anon;
grant execute on function public.suggest_sponsorship_price(uuid) to authenticated;

-- Admin moderation queue (is_admin() guarded in the body).
revoke execute on function public.get_report_queue(integer, timestamptz) from public, anon;
grant execute on function public.get_report_queue(integer, timestamptz) to authenticated;

commit;

-- Deliberately NOT revoked — these need anon and are safe:
--   get_feed_ads / get_currents_ads   logged-out feed browsing
--   get_lobby_sponsorship             public lobby sponsor card
--   is_admin / is_blocked / is_event_host   invoked inside RLS policies as the
--                                     calling role; revoking breaks every
--                                     policy that references them
--   can_join_live_chat                invoked by the Realtime authorization
--                                     policy as the connecting user
--
-- RULE FOR FUTURE MIGRATIONS: always write
--   revoke execute on function ... from public, anon, authenticated;
-- Omitting `public` leaves the default grant in place and does nothing.
