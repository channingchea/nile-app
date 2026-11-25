-- 0099: one expiring-offer nudge per offer, enforced.
--
-- Migration 0090 gave five notification types partial unique indexes after two
-- duplicate event_live pairs reached prod. The 2-hourly sweep that sends
-- sponsorship_offer_expiring reads-then-inserts, which is correct but not
-- atomic — two overlapping runs can both see no row. Same fix, same reasoning:
-- the query is the intent, the index is the backstop.

create unique index if not exists notifications_sponsorship_offer_expiring_uniq
  on public.notifications (recipient_id, entity_id)
  where type = 'sponsorship_offer_expiring';
