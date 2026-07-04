-- 0040: Advertiser dashboard maturity (Phase 1).
-- 1) get_advertiser_performance gains keyset pagination (p_limit + p_before on
--    created_at) and returns created_at so the client can page. Mirrors the
--    app's Paged<T> convention (fetch p_limit+order desc; cursor = last row's
--    created_at; hasMore = returned count == p_limit).
-- 2) get_advertiser_daily: per-day impression/click counts for the account's
--    campaigns, so the dashboard can chart activity over time.

drop function public.get_advertiser_performance(uuid); -- signature + return type change

create function public.get_advertiser_performance(
  p_account_id uuid,
  p_limit      integer     default 15,
  p_before     timestamptz default null   -- keyset cursor: created_at of last row
)
returns table (
  campaign_id  uuid,
  name         text,
  headline     text,
  status       text,
  budget_cents integer,
  spent_cents  integer,
  starts_at    timestamptz,
  ends_at      timestamptz,
  impressions  bigint,
  clicks       bigint,
  review_note  text,
  created_at   timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    c.id, c.name, cr.headline, c.status, c.budget_cents, c.spent_cents,
    c.starts_at, c.ends_at,
    count(ae.*) filter (where ae.kind = 'impression') as impressions,
    count(ae.*) filter (where ae.kind = 'click')      as clicks,
    c.review_note, c.created_at
  from ad_campaigns c
  join advertiser_accounts a
    on a.id = c.advertiser_account_id
   and a.auth_user_id = auth.uid()          -- caller must own the account
  left join ad_creatives cr on cr.campaign_id = c.id
  left join ad_events    ae on ae.campaign_id = c.id
  where c.advertiser_account_id = p_account_id
    and (p_before is null or c.created_at < p_before)
  group by c.id, cr.headline
  order by c.created_at desc
  limit greatest(1, least(p_limit, 100));
$$;

grant execute on function public.get_advertiser_performance(uuid, integer, timestamptz) to authenticated;

-- Daily impression/click buckets for the account (default last 30 days).
-- SECURITY DEFINER: aggregates ad_events (insert-only to clients) scoped to
-- account ownership. Returns one row per day that had activity.
create function public.get_advertiser_daily(
  p_account_id uuid,
  p_days       integer default 30
)
returns table (
  day         date,
  impressions bigint,
  clicks      bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    (ae.created_at at time zone 'UTC')::date as day,
    count(*) filter (where ae.kind = 'impression') as impressions,
    count(*) filter (where ae.kind = 'click')      as clicks
  from ad_events ae
  join ad_campaigns c on c.id = ae.campaign_id
  join advertiser_accounts a
    on a.id = c.advertiser_account_id
   and a.auth_user_id = auth.uid()
  where c.advertiser_account_id = p_account_id
    and ae.created_at >= (now() - make_interval(days => greatest(1, least(p_days, 365))))
  group by day
  order by day;
$$;

grant execute on function public.get_advertiser_daily(uuid, integer) to authenticated;
