-- 0118_ticket_buyer_anonymization.sql
-- P3 #32 — account deletion was permanently impossible for anyone who had
-- ever bought a ticket (Guideline 5.1.1(v)).
--
-- The old delete-account 409'd on any status='paid' ticket, and a ticket only
-- leaves 'paid' via a host refund. There is no buyer-initiated refund path and
-- nothing ages a ticket out, so one purchase locked the account forever.
--
-- The guard now only covers tickets for events that have not happened yet —
-- those are live entitlements the buyer paid for and should be refunded before
-- leaving. Everything older is *anonymized* rather than deleted, so the host's
-- revenue history for a show that already happened survives an attendee
-- exercising erasure.

alter table public.tickets alter column buyer_id drop not null;

-- Was ON DELETE CASCADE, which is what made deletion destroy sales history.
alter table public.tickets drop constraint tickets_buyer_id_fkey;
alter table public.tickets
  add constraint tickets_buyer_id_fkey
  foreign key (buyer_id) references public.profiles(id) on delete set null;

-- Stamped by delete-account immediately before the profile row goes, so a null
-- buyer_id reads as "this person deleted their account" rather than as data
-- corruption. UNIQUE (event_id, buyer_id) still holds: Postgres treats NULLs as
-- distinct, so several anonymized tickets on one event are fine.
alter table public.tickets
  add column if not exists buyer_deleted_at timestamptz;

comment on column public.tickets.buyer_deleted_at is
  'Set when the buyer deleted their account; buyer_id is nulled by the FK at the same moment. The sale stays on the host''s books, the person does not.';
