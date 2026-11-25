-- 0161 Keep Apple sandbox purchases (TestFlight, App Review) out of the host's
-- earnings. They grant access like a real ticket but no money changes hands
-- and they're never paid out (0160). Same functions as 0094, one filter added.

create or replace function public.host_event_ticket_totals(p_event_id uuid)
returns table(gross_cents bigint, net_cents bigint, fee_cents bigint, paid_count bigint)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    coalesce(sum(t.amount_cents), 0)::bigint,
    coalesce(sum(t.amount_cents - coalesce(t.application_fee_cents, 0)), 0)::bigint,
    coalesce(sum(coalesce(t.application_fee_cents, 0)), 0)::bigint,
    count(*)::bigint
  from tickets t
  join events e on e.id = t.event_id
  where t.event_id = p_event_id
    and e.host_id = (select auth.uid())
    and t.status = 'paid'
    and (t.payment_provider = 'stripe' or t.apple_environment = 'Production');
$$;

create or replace function public.host_ticket_earnings()
returns table(lifetime_net_cents bigint, month_net_cents bigint, lifetime_gross_cents bigint,
              month_gross_cents bigint, ticket_count bigint, fallback_owed_cents bigint,
              fallback_count bigint)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    coalesce(sum(t.amount_cents - coalesce(t.application_fee_cents, 0)), 0)::bigint,
    coalesce(sum(case when t.created_at >= date_trunc('month', now())
                      then t.amount_cents - coalesce(t.application_fee_cents, 0)
                      else 0 end), 0)::bigint,
    coalesce(sum(t.amount_cents), 0)::bigint,
    coalesce(sum(case when t.created_at >= date_trunc('month', now())
                      then t.amount_cents else 0 end), 0)::bigint,
    count(*)::bigint,
    coalesce(sum(case when t.split_status = 'platform_fallback'
                      then t.amount_cents - coalesce(t.application_fee_cents, 0)
                      else 0 end), 0)::bigint,
    count(*) filter (where t.split_status = 'platform_fallback')::bigint
  from tickets t
  join events e on e.id = t.event_id
  where e.host_id = (select auth.uid())
    and t.status = 'paid'
    and (t.payment_provider = 'stripe' or t.apple_environment = 'Production');
$$;
