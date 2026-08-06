-- 0081: Event Sponsorship — host earnings (plan Phase 5).
--
-- host_sponsorship_earnings(): sibling of host_ticket_earnings (0050) for the
-- Payouts screen. A sponsorship pays the host at capture (approval), so
-- 'active' and 'completed' lobby campaigns both count; rejected rows were
-- refunded/never charged. Net = price minus the platform application fee
-- frozen on the row at purchase.

create or replace function host_sponsorship_earnings()
returns table (
  lifetime_net_cents   bigint,
  month_net_cents      bigint,
  lifetime_gross_cents bigint,
  sponsorship_count    bigint
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    coalesce(sum(c.budget_cents - coalesce(c.application_fee_cents, c.budget_cents)), 0)::bigint,
    coalesce(sum(case when c.created_at >= date_trunc('month', now())
                      then c.budget_cents - coalesce(c.application_fee_cents, c.budget_cents)
                      else 0 end), 0)::bigint,
    coalesce(sum(c.budget_cents), 0)::bigint,
    count(*)::bigint
  from ad_campaigns c
  join events e on e.id = c.event_id
  where e.host_id = auth.uid()
    and c.placement = 'lobby'
    and c.status in ('active', 'completed');
$$;

grant execute on function host_sponsorship_earnings() to authenticated;
