-- New-message notifications, part 1: enum value only.
-- A newly added enum label cannot be referenced in the same transaction that
-- adds it, so the value is committed here and used in part 2 (0014).

alter type notification_type add value if not exists 'new_message';
