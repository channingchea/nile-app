-- Message-reaction notifications, part 1: enum value only.
-- A newly added enum label cannot be referenced in the same transaction that
-- adds it, so the value is committed here and used in part 2 (0020). Mirrors
-- 0013 (new_message_enum).

alter type notification_type add value if not exists 'message_reaction';
