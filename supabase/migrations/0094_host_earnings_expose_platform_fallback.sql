-- 0094 — B12 (second half) + B13 from the 2026-08-11 review.
--
-- B12 The only record that a fallback charge owed the host money was a
--     console.warn in create-payment-intent. 0092 fixed the arithmetic (the fee
--     is recorded now, so these stop netting zero); this surfaces the amount
--     that is earned but sitting on the platform account awaiting a manual
--     transfer, so it can be shown on the Payouts screen instead of silently
--     looking like ordinary revenue.
-- B13 The Attendee list showed gross and Payouts showed net, with no
--     explanation of the platform cut on either screen. Returning both figures
--     from one function means the two screens can't drift.
--
-- Note the change to the net expression: it was
-- `amount - coalesce(fee, amount)`, which silently returned ZERO for any row
-- with no recorded fee. `coalesce(fee, 0)` is the honest reading — an unknown
-- fee is not "the host earned nothing".

drop function if exists public.host_ticket_earnings();

create function public.host_ticket_earnings()
returns table (
  lifetime_net_cents    bigint,
  month_net_cents       bigint,
  lifetime_gross_cents  bigint,
  month_gross_cents     bigint,
  ticket_count          bigint,
  fallback_owed_cents   bigint,
  fallback_count        bigint
)
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select
    coalesce(sum(t.amount_cents - coalesce(t.application_fee_cents, 0)), 0)::bigint,
    coalesce(sum(case when t.created_at >= date_trunc('month', now())
                      then t.amount_cents - coalesce(t.application_fee_cents, 0)
                      else 0 end), 0)::bigint,
    coalesce(sum(t.amount_cents), 0)::bigint,
    coalesce(sum(case when t.created_at >= date_trunc('month', now())
                      then t.amount_cents else 0 end), 0)::bigint,
    count(*)::bigint,
    -- Earned, but charged to the platform account because the host had no
    -- payable Connect account at the time. Owed by manual transfer.
    coalesce(sum(case when t.split_status = 'platform_fallback'
                      then t.amount_cents - coalesce(t.application_fee_cents, 0)
                      else 0 end), 0)::bigint,
    count(*) filter (where t.split_status = 'platform_fallback')::bigint
  from tickets t
  join events e on e.id = t.event_id
  where e.host_id = (select auth.uid())
    and t.status = 'paid';
$function$;

-- Per-event figures for the Attendee list, so it can show the same net the
-- Payouts screen does rather than gross alone.
create or replace function public.host_event_ticket_totals(p_event_id uuid)
returns table (
  gross_cents  bigint,
  net_cents    bigint,
  fee_cents    bigint,
  paid_count   bigint
)
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select
    coalesce(sum(t.amount_cents), 0)::bigint,
    coalesce(sum(t.amount_cents - coalesce(t.application_fee_cents, 0)), 0)::bigint,
    coalesce(sum(coalesce(t.application_fee_cents, 0)), 0)::bigint,
    count(*)::bigint
  from tickets t
  join events e on e.id = t.event_id
  where t.event_id = p_event_id
    and e.host_id = (select auth.uid())
    and t.status = 'paid';
$function$;

revoke execute on function public.host_event_ticket_totals(uuid) from anon;
