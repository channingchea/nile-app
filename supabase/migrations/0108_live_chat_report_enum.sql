-- 0108 — report_target_type gains 'live_chat_message' (#16 phase 3).
--
-- Alone in its own migration for the reason 0066 spells out: an enum value
-- added and USED in the same transaction fails. 0109 is what uses it.
--
-- Until now the only way to report something said in chat was to report the
-- account, which threw away the actual message — the reviewer got "someone
-- reported @x" and a screenshot at best. 0107 gave chat messages a row and an
-- id; this is what lets a report point at one.

alter type report_target_type add value if not exists 'live_chat_message';
