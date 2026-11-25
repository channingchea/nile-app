-- 0095: Sponsorship offers — notification enum values.
-- (docs/plans/sponsorship-offers-host-approved.md, Phase 1)
--
-- Its own migration on purpose: Postgres cannot use a newly added enum value in
-- the same transaction that creates it, and 0096 writes notif_enabled() with
-- both names in its CASE.

alter type notification_type add value if not exists 'sponsorship_offer';
alter type notification_type add value if not exists 'sponsorship_offer_expiring';
