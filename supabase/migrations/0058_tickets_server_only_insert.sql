-- 0058: Security hardening fix #2 — tickets can only be created by the server.
--
-- tickets_insert_own checked WHO (buyer_id = auth.uid()) but not WHAT, so an
-- authenticated user could insert {status:'paid', amount_cents:0} directly via
-- the public API and get free access to paid events/replays. The client never
-- inserts tickets — create-payment-intent (service role) does — so drop the
-- policy entirely. The service role bypasses RLS and is unaffected.
-- Intentionally no public INSERT or UPDATE policy remains on tickets.

drop policy if exists tickets_insert_own on public.tickets;
