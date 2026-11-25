-- 0160 Apple IAP Phase 5 — month-end host payouts (docs/plans/apple-iap-tickets.md).
--
-- App store money lands with Nile (Apple pays ~45 days later). The host's
-- share — frozen per ticket at purchase — is sent once a month by the
-- apple-payouts function on the 28th, as one Stripe transfer per host, so it
-- rides the host's normal month-end bank payout (monthly_anchor 31) with their
-- card sales. Apple refunds after a payout come off the next one.
--
-- Claim → transfer → complete, keyed `apple-payout-<host>-<YYYY-MM>`:
--   claim    stamps the rows with the key (only for hosts with no unfinished
--            claim, so a re-run repeats the same amount and Stripe's
--            idempotency key returns the same transfer);
--   complete swaps the key for the Stripe transfer id and stamps the dates;
--   release  un-claims when nothing is sent (net ≤ 0, host not payable).
-- Only Production purchases, for shows that actually took place.

alter table public.tickets
  add column if not exists host_clawback_transfer_id text;

create or replace function public.apple_payout_claim(p_month text)
returns table (key text, host_id uuid, stripe_account_id text,
               pay_cents bigint, clawback_cents bigint, ticket_count bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_busy uuid[];
begin
  -- Hosts with an unfinished claim (a run that stopped between transfer and
  -- complete) keep exactly that claim: no new rows join it, so the re-run asks
  -- Stripe for the same amount under the same idempotency key.
  select coalesce(array_agg(distinct e.host_id), '{}') into v_busy
    from tickets t join events e on e.id = t.event_id
   where (t.host_transfer_id like 'apple-payout-%' and t.host_paid_at is null)
      or (t.host_clawback_transfer_id like 'apple-payout-%' and t.host_clawback_at is null);

  update tickets t
     set host_transfer_id = 'apple-payout-' || e.host_id || '-' || p_month
    from events e
   where e.id = t.event_id
     and not (e.host_id = any (v_busy))
     and t.payment_provider = 'apple' and t.apple_environment = 'Production'
     and t.status = 'paid' and t.host_paid_at is null and t.host_transfer_id is null
     and e.status = 'ended' and e.started_at is not null;

  update tickets t
     set host_clawback_transfer_id = 'apple-payout-' || e.host_id || '-' || p_month
    from events e
   where e.id = t.event_id
     and not (e.host_id = any (v_busy))
     and t.payment_provider = 'apple' and t.apple_environment = 'Production'
     and t.status = 'refunded' and t.host_paid_at is not null
     and t.host_clawback_at is null and t.host_clawback_transfer_id is null;

  return query
  with rows as (
    select t.host_transfer_id as k, t.host_share_cents as pay, 0 as claw, e.host_id as h
      from tickets t join events e on e.id = t.event_id
     where t.host_transfer_id like 'apple-payout-%' and t.host_paid_at is null
    union all
    select t.host_clawback_transfer_id, 0, t.host_share_cents, e.host_id
      from tickets t join events e on e.id = t.event_id
     where t.host_clawback_transfer_id like 'apple-payout-%' and t.host_clawback_at is null
  )
  select r.k, r.h, p.stripe_account_id,
         coalesce(sum(r.pay), 0)::bigint, coalesce(sum(r.claw), 0)::bigint, count(*)::bigint
    from rows r join profiles p on p.id = r.h
   group by r.k, r.h, p.stripe_account_id;
end;
$$;

create or replace function public.apple_payout_complete(p_key text, p_transfer_id text)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update tickets set host_paid_at = now(), host_transfer_id = coalesce(p_transfer_id, p_key)
   where host_transfer_id = p_key and host_paid_at is null;
  update tickets set host_clawback_at = now(), host_clawback_transfer_id = coalesce(p_transfer_id, p_key)
   where host_clawback_transfer_id = p_key and host_clawback_at is null;
$$;

create or replace function public.apple_payout_release(p_key text)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update tickets set host_transfer_id = null
   where host_transfer_id = p_key and host_paid_at is null;
  update tickets set host_clawback_transfer_id = null
   where host_clawback_transfer_id = p_key and host_clawback_at is null;
$$;

revoke execute on function public.apple_payout_claim(text) from public, anon, authenticated;
revoke execute on function public.apple_payout_complete(text, text) from public, anon, authenticated;
revoke execute on function public.apple_payout_release(text) from public, anon, authenticated;

-- Payouts screen split (Phase 5): card vs app store, and app store refunds
-- waiting to come off the next payout. Same "net" meaning as
-- host_ticket_earnings (host's share of paid tickets).
create or replace function public.host_ticket_earnings_by_source()
returns table (card_net_cents bigint, card_count bigint,
               store_net_cents bigint, store_count bigint,
               store_unpaid_cents bigint, store_deduction_cents bigint)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    coalesce(sum(t.amount_cents - coalesce(t.application_fee_cents, 0))
             filter (where t.payment_provider = 'stripe' and t.status = 'paid'), 0)::bigint,
    count(*) filter (where t.payment_provider = 'stripe' and t.status = 'paid')::bigint,
    coalesce(sum(t.host_share_cents)
             filter (where t.payment_provider = 'apple' and t.status = 'paid'), 0)::bigint,
    count(*) filter (where t.payment_provider = 'apple' and t.status = 'paid')::bigint,
    -- In next month-end's payout (or waiting for the show to take place).
    coalesce(sum(t.host_share_cents)
             filter (where t.payment_provider = 'apple' and t.status = 'paid'
                       and t.host_paid_at is null), 0)::bigint,
    -- Refunded by the store after the host was paid: comes off the next payout.
    coalesce(sum(t.host_share_cents)
             filter (where t.payment_provider = 'apple' and t.status = 'refunded'
                       and t.host_paid_at is not null and t.host_clawback_at is null), 0)::bigint
  from tickets t
  join events e on e.id = t.event_id
  where e.host_id = (select auth.uid())
    and (t.payment_provider = 'stripe' or t.apple_environment = 'Production');
$$;

grant execute on function public.host_ticket_earnings_by_source() to authenticated;
