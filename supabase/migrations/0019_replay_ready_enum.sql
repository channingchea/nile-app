-- Replay-ready notifications, part 1: enum value.
-- ALTER TYPE ... ADD VALUE must commit before the value can be referenced, so
-- it lives in its own migration (same pattern as phases 16/17 and 0010).

alter type notification_type add value if not exists 'replay_ready';
