-- Phase 22: Sound Check
-- Adds a 'soundcheck' status between 'scheduled' and 'live'. Hosts/operators enter
-- Sound Check to set up and test devices; pressing "Start Show" transitions to
-- 'live'. Viewers who join during 'soundcheck' wait in the Lobby.
--
-- Transition model: scheduled → soundcheck → live → ended
--   (a host who leaves during soundcheck without starting reverts to 'scheduled')
--
-- The phase17 status-change trigger fires event_live notifications only on
-- transition INTO 'live', so entering soundcheck is silent — no schema change
-- needed there.

-- events.status is the Postgres enum `event_status`
-- (scheduled, live, ended, cancelled). Add 'soundcheck' right after 'scheduled'.
-- ALTER TYPE ... ADD VALUE cannot run inside a transaction block, so apply this
-- statement on its own (not wrapped in a migration transaction).
alter type event_status add value if not exists 'soundcheck' after 'scheduled';
