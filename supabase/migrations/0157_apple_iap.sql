-- 0157 Apple in-app purchase (plan: docs/plans/apple-iap-tickets.md, Phase 1)
--
-- Tickets and replays bought on iPhone/iPad go through Apple. One entitlement
-- row per (event, buyer) stays the rule; these columns say how it was paid for
-- and what the host is owed.
--
-- For an Apple ticket:
--   amount_cents          = the WEB price (what the host's share is based on)
--   store_price_cents     = what the buyer paid Apple (web ÷ 0.70, up to .99)
--   host_share_cents      = the host's cut, frozen at purchase
--   application_fee_cents = amount_cents − host_share_cents (Nile's side, as for card sales)
--   split_status          = 'apple' — the money lands with Nile and is sent to
--                           the host in the month-end payout (Phase 5)
--   stripe_payment_intent_id = 'apple:<event>:<buyer>' while pending,
--                              'apple:<transaction id>' once paid (column is NOT NULL + unique)

alter table public.tickets
  add column if not exists payment_provider text not null default 'stripe'
    check (payment_provider in ('stripe', 'apple')),
  add column if not exists apple_transaction_id text unique,
  add column if not exists apple_original_transaction_id text,
  add column if not exists apple_environment text
    check (apple_environment in ('Production', 'Sandbox')),
  add column if not exists store_price_cents integer check (store_price_cents > 0),
  add column if not exists host_share_cents integer check (host_share_cents >= 0),
  add column if not exists paid_at timestamptz,
  add column if not exists refunded_at timestamptz,
  add column if not exists host_paid_at timestamptz,
  add column if not exists host_clawback_at timestamptz,
  add column if not exists host_transfer_id text;

alter table public.tickets drop constraint if exists tickets_split_status_check;
alter table public.tickets add constraint tickets_split_status_check
  check (split_status in ('split', 'platform_fallback', 'apple'));

-- The payout job's scan: paid/refunded Apple tickets not yet settled with the host.
create index if not exists tickets_apple_payout_idx on public.tickets (event_id)
  where payment_provider = 'apple' and apple_environment = 'Production'
    and (host_paid_at is null or host_clawback_at is null);

-- iPhone price for a web price: web ÷ (1 − Apple's fee), rounded UP to the
-- next .99, never below $1.99. Null above the $99.99 top of the ladder (those
-- shows aren't sold through Apple). Mirrored by PricingConfig.iapPriceCentsFor
-- in the app — keep the two in step (test: test/pricing_config_test.dart).
create or replace function public.compute_iap_price_cents(p_web_cents integer)
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_fee  numeric;
  v_raw  integer;
  v_cents integer;
begin
  if p_web_cents is null or p_web_cents <= 0 then
    return null;
  end if;
  select apple_fee_pct into v_fee from app_config where id = 1;
  v_fee := coalesce(v_fee, 0.30);
  v_raw := ceil(p_web_cents / (1 - v_fee))::int;
  v_cents := greatest(ceil((v_raw + 1) / 100.0)::int * 100 - 1, 199);
  if v_cents > 9999 then
    return null;
  end if;
  return v_cents;
end;
$$;

grant execute on function public.compute_iap_price_cents(integer) to anon, authenticated;

-- Settle a verified Apple purchase (called by the apple-iap function only).
-- Returns: 'paid' | 'already' (this transaction was settled before) |
--          'not_found' | 'duplicate' (the buyer already holds this ticket some
--          other way — Apple still charged them, so the caller flags it).
-- A sold-out show still grants: Apple has taken the money and only the buyer
-- can ask for it back.
create or replace function public.settle_apple_ticket(
  p_ticket_id uuid,
  p_transaction_id text,
  p_original_transaction_id text,
  p_store_price_cents integer,
  p_environment text
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  t public.tickets%rowtype;
begin
  if exists (select 1 from tickets where apple_transaction_id = p_transaction_id) then
    return 'already';
  end if;

  select * into t from tickets where id = p_ticket_id for update;
  if not found then
    return 'not_found';
  end if;
  if t.status = 'paid' or t.payment_provider <> 'apple' then
    return 'duplicate';
  end if;

  update tickets
     set status = 'paid',
         apple_transaction_id = p_transaction_id,
         apple_original_transaction_id = p_original_transaction_id,
         apple_environment = p_environment,
         store_price_cents = p_store_price_cents,
         stripe_payment_intent_id = 'apple:' || p_transaction_id,
         paid_at = now(),
         refunded_at = null
   where id = t.id;
  return 'paid';
end;
$$;

-- Apple refunded a purchase (REFUND notification). Returns the ticket id, or
-- null when there's nothing paid to refund.
create or replace function public.refund_apple_ticket(p_transaction_id text)
returns uuid
language sql
security definer
set search_path = public, pg_temp
as $$
  update tickets
     set status = 'refunded', refunded_at = now()
   where apple_transaction_id = p_transaction_id
     and status = 'paid'
  returning id;
$$;

revoke execute on function public.settle_apple_ticket(uuid, text, text, integer, text) from public, anon, authenticated;
revoke execute on function public.refund_apple_ticket(text) from public, anon, authenticated;

-- Monthly cross-check of Nile's Apple tickets against Apple's own sales and
-- refund reports (Phase 5). One row per month checked; the admin portal shows
-- the latest rows with mismatches.
create table if not exists public.apple_reconciliations (
  month        date primary key,               -- first day of the month checked
  checked_at   timestamptz not null default now(),
  apple_units  integer not null default 0,     -- net units in Apple's reports
  nile_units   integer not null default 0,     -- net paid Apple tickets in Nile
  mismatches   jsonb not null default '[]'::jsonb,
  error        text                            -- report fetch failed, etc.
);
alter table public.apple_reconciliations enable row level security;
create policy apple_reconciliations_admin_read on public.apple_reconciliations
  for select using ((select public.is_admin()));
