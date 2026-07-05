-- Tipping, part 1: add the 'tip_received' notification type.
--
-- Split from the tips table + notif wiring (0045) because Postgres cannot add an
-- enum value and use it in the same transaction. Mirrors the enum-first pattern
-- of 0019 (message_reaction) / 0022 (replay_ready).

alter type notification_type add value if not exists 'tip_received';
