-- 0146: notification type for Interview mode invites (see 0147). On its own
-- because a new enum value can't be used in the transaction that adds it.

alter type notification_type add value if not exists 'guest_invited';
