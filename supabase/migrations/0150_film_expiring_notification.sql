-- 0150: notification type for Premiere films about to be deleted
-- (docs/plans/studio-modes.md, phase 6). Own migration: an enum value can't be
-- used in the transaction that adds it.
alter type public.notification_type add value if not exists 'film_expiring';
