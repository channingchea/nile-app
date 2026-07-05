-- Sound-check-open crew notifications, part 1: add the 'soundcheck_open' type.
--
-- Split from the pref/function/RPC wiring (0047) because Postgres cannot add an
-- enum value and use it in the same transaction. Mirrors the enum-first pattern
-- of 0044 (tip_received) / 0022 (replay_ready).

alter type notification_type add value if not exists 'soundcheck_open';
