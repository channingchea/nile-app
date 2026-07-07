-- Phase 3 — creator payouts & revenue split.
--
-- Turns ticket/replay purchases into destination charges: the creator's share
-- lands in their Connect account at checkout, the platform keeps an application
-- fee. Split percentages live in app_config so they're a data change, not a
-- deploy. Each ticket freezes its own fee so earnings stay accurate if the
-- share is later re-tuned. A trigger blocks publishing a PAID event whose host
-- has no Connect account (client gates too; this is the server backstop).

-- ── 1) Config knobs on the app_config singleton (0041) ────────────────────────
alter table public.app_config
  add column if not exists creator_revenue_share numeric not null default 0.50
    check (creator_revenue_share between 0 and 1),
  add column if not exists tip_fee_share numeric not null default 0.10
    check (tip_fee_share between 0 and 1);

-- ── 2) Per-ticket split bookkeeping ───────────────────────────────────────────
-- split_status: did the charge carry transfer_data (creator paid at checkout),
--   or fall back to a plain platform charge (grandfathered host → manual xfer)?
-- application_fee_cents: platform's cut on THIS charge, frozen at checkout.
-- Default 'platform_fallback' is the SAFE assumption: it backfills all existing
-- (pre-split) tickets as plain charges so refunds never attempt to reverse a
-- transfer that doesn't exist. New checkouts stamp 'split' only when a
-- destination charge is actually made.
alter table public.tickets
  add column if not exists split_status text not null default 'platform_fallback'
    check (split_status in ('split', 'platform_fallback')),
  add column if not exists application_fee_cents int
    check (application_fee_cents is null or application_fee_cents >= 0);

-- ── 3) Publish gate: a paid event can't go public without a payable host ───────
-- Fires only on the publish (draft→scheduled) or free→paid transition. Go-live
-- (scheduled→soundcheck→live) and edits of already-paid events are untouched.
-- SECURITY DEFINER so it can always read profiles regardless of RLS.
create or replace function enforce_paid_publish_payable()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'scheduled'
     and coalesce(new.price, 0) > 0
     and (old.status = 'draft' or coalesce(old.price, 0) = 0)
     and not exists (
       select 1 from profiles
       where id = new.host_id and stripe_account_id is not null
     )
  then
    raise exception 'payouts_required'
      using hint = 'Set up payouts before publishing a paid event.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_paid_publish_payable on public.events;
create trigger trg_enforce_paid_publish_payable
  before update on public.events
  for each row
  when (new.status = 'scheduled')
  execute function enforce_paid_publish_payable();

-- ── 4) Host ticket earnings for the Payouts screen ────────────────────────────
-- Net = gross minus the frozen application fee per split ticket. Fallback
-- tickets (no application_fee_cents) contribute to gross but net 0 until a
-- manual transfer is made.
create or replace function host_ticket_earnings()
returns table (
  lifetime_net_cents   bigint,
  month_net_cents      bigint,
  lifetime_gross_cents bigint,
  month_gross_cents    bigint,
  ticket_count         bigint
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    coalesce(sum(t.amount_cents - coalesce(t.application_fee_cents, t.amount_cents)), 0)::bigint,
    coalesce(sum(case when t.created_at >= date_trunc('month', now())
                      then t.amount_cents - coalesce(t.application_fee_cents, t.amount_cents)
                      else 0 end), 0)::bigint,
    coalesce(sum(t.amount_cents), 0)::bigint,
    coalesce(sum(case when t.created_at >= date_trunc('month', now())
                      then t.amount_cents else 0 end), 0)::bigint,
    count(*)::bigint
  from tickets t
  join events e on e.id = t.event_id
  where e.host_id = auth.uid()
    and t.status = 'paid';
$$;
