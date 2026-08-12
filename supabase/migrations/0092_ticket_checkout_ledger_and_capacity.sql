-- 0092 — B6, B7, B8, B12 from the 2026-08-11 event lifecycle review.
--
-- tickets has UNIQUE (event_id, buyer_id) and the pending row was upserted on
-- that key, which made the row do two incompatible jobs: current entitlement,
-- and the record of a payment. Three failures fell out of that.
--
-- B6 Opening checkout a second time overwrote stripe_payment_intent_id, so
--    completing the FIRST tab matched zero rows in the webhook. Card charged,
--    ticket stuck 'pending' forever, door rejects them, and refund-ticket
--    refuses on two separate grounds — only a manual Stripe dashboard refund,
--    that nobody is alerted to, recovers it.
-- B7 Buying a replay after a refund rewrote the same row, erasing the refund
--    from history and corrupting the host's revenue and the chargeback trail.
-- B8 Capacity was checked once, before the Stripe session, and never re-checked
--    when payment landed. No constraint or trigger backed it, so ten buyers on
--    the last seat all paid.
-- B12 A fallback charge (Connect lookup failed) stored application_fee_cents as
--    NULL, and host_ticket_earnings does amount - coalesce(fee, amount) — which
--    nets exactly zero. The only record that money was owed was a console.warn.
--
-- Shape: ticket_checkouts is the ledger — one row per checkout attempt, keyed
-- on the Stripe session id. tickets stays exactly what it was, the current
-- entitlement. The webhook now resolves through the ledger, so a second attempt
-- can't hide the first, and a refund survives a later purchase.

create table if not exists public.ticket_checkouts (
  id                    uuid primary key default gen_random_uuid(),
  event_id              uuid not null references public.events(id) on delete cascade,
  buyer_id              uuid not null references public.profiles(id) on delete cascade,
  session_id            text not null unique,
  payment_intent_id     text,
  kind                  text not null default 'live' check (kind in ('live','replay')),
  amount_cents          integer not null check (amount_cents > 0),
  application_fee_cents integer check (application_fee_cents is null or application_fee_cents >= 0),
  split_status          text not null default 'platform_fallback'
                          check (split_status in ('split','platform_fallback')),
  status                text not null default 'pending'
                          check (status in ('pending','paid','refunded','abandoned','oversold')),
  note                  text,
  created_at            timestamptz not null default now(),
  settled_at            timestamptz
);

create index if not exists ticket_checkouts_event_idx on public.ticket_checkouts (event_id);
create index if not exists ticket_checkouts_buyer_idx on public.ticket_checkouts (buyer_id);
create index if not exists ticket_checkouts_pi_idx on public.ticket_checkouts (payment_intent_id);
create index if not exists ticket_checkouts_pending_idx
  on public.ticket_checkouts (created_at) where status = 'pending';

alter table public.ticket_checkouts enable row level security;

-- Reads only. Every write goes through the service role (the webhook and
-- create-payment-intent), so there is no insert/update/delete policy at all.
drop policy if exists ticket_checkouts_select_own on public.ticket_checkouts;
create policy ticket_checkouts_select_own on public.ticket_checkouts
  for select using (
    buyer_id = (select auth.uid())
    or exists (
      select 1 from public.events e
       where e.id = ticket_checkouts.event_id
         and e.host_id = (select auth.uid())
    )
  );

grant select on public.ticket_checkouts to authenticated;

-- Backfill from the tickets that exist today, so the ledger isn't blank on day
-- one. session_id falls back to the PI id, which is what the old flow stored.
insert into public.ticket_checkouts
  (event_id, buyer_id, session_id, payment_intent_id, kind, amount_cents,
   application_fee_cents, split_status, status, created_at, settled_at, note)
select t.event_id, t.buyer_id, t.stripe_payment_intent_id, t.stripe_payment_intent_id,
       t.kind, t.amount_cents, t.application_fee_cents, t.split_status,
       t.status, t.created_at,
       case when t.status = 'pending' then null else t.created_at end,
       'backfilled from tickets by migration 0092'
  from public.tickets t
 on conflict (session_id) do nothing;

-- ── B12: a fallback charge still owes the host their share ──────────────────
-- Record the fee we would have charged, so earnings are honest about what the
-- host has earned even when the transfer has to be made by hand.
update public.tickets t
   set application_fee_cents = t.amount_cents
     - floor(t.amount_cents * coalesce(
         (select creator_revenue_share from public.app_config where id = 1), 0.5))::int
 where t.application_fee_cents is null;

update public.ticket_checkouts c
   set application_fee_cents = t.application_fee_cents
  from public.tickets t
 where c.session_id = t.stripe_payment_intent_id
   and c.application_fee_cents is null;
