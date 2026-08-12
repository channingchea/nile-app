-- 0087 — B3 part 1. A new enum value must be committed before it can be used,
-- so the trigger that writes it ships separately in 0088 (same split as
-- 0044/0045 and 0046/0047).
alter type notification_type add value if not exists 'event_no_show';
