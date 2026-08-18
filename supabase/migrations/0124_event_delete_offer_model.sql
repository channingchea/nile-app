-- 0124 — P2 #27 from the 2026-08-16 platform review: hard-deleting an event
-- emailed a refund that never happened.
--
-- 0096 rebuilt sponsorship_on_event_status() for the offer model — only
-- 'active' has ever been charged, everything upstream just closes out — but
-- the DELETE trigger from 0079 was left behind. It still enqueues from
-- `status in ('pending_review','active')`, so deleting an event with an
-- offer that was merely cleared for review put a row in sponsorship_refunds
-- for a card that was only saved. The sweep then found no PaymentIntent to
-- act on, marked the row done, and sent "your payment has been refunded".
--
-- The other half is quieter and worse: an offer in pending_host, declined,
-- or payment_pending cascade-deleted with the event and the advertiser heard
-- nothing at all. review_note can't carry the news — the campaign row is
-- gone. sponsorship_refunds has no FK to ad_campaigns precisely so it can
-- outlive that cascade, which makes it the only channel left.
--
-- So: charged rows enqueue a real refund; uncharged rows enqueue a
-- notify-only row under a new reason the sweep knows not to take to Stripe.

alter table public.sponsorship_refunds
  drop constraint if exists sponsorship_refunds_reason_check;

alter table public.sponsorship_refunds
  add constraint sponsorship_refunds_reason_check
  check (reason in (
    'event_deleted',
    'event_cancelled',
    'not_approved_in_time',
    'event_never_started',
    'event_deleted_uncharged'   -- notify only: no money ever moved
  ));

create or replace function public.enqueue_sponsorship_refund_on_event_delete()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  -- Charged sponsorships: real money, real refund. Under the offer model
  -- 'active' is the only status a confirmed PaymentIntent can produce.
  insert into sponsorship_refunds
    (campaign_id, advertiser_account_id, stripe_payment_intent_id, split_status, event_title, reason)
  select c.id, c.advertiser_account_id, c.stripe_payment_intent_id, c.split_status, old.title, 'event_deleted'
  from ad_campaigns c
  where c.event_id = old.id
    and c.placement = 'lobby'
    and c.status = 'active';

  -- Uncharged offers: nothing to give back, but the advertiser still had an
  -- offer in flight on an event that no longer exists. Same queue, different
  -- reason — the sweep skips Stripe for this one and sends the "you were not
  -- charged" copy.
  insert into sponsorship_refunds
    (campaign_id, advertiser_account_id, stripe_payment_intent_id, split_status, event_title, reason)
  select c.id, c.advertiser_account_id, c.stripe_payment_intent_id, c.split_status, old.title, 'event_deleted_uncharged'
  from ad_campaigns c
  where c.event_id = old.id
    and c.placement = 'lobby'
    and c.status in ('pending_payment', 'pending_review', 'pending_host', 'payment_pending');

  return old;
end;
$function$;
