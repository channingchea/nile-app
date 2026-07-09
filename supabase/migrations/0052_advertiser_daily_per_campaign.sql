-- 0052: Per-campaign filter for get_advertiser_daily (Part 3 of the ad-platform
-- hardening plan — reporting polish). Additive only: p_campaign_id defaults to
-- null (existing "all campaigns" behavior), so every current caller is
-- unaffected. CREATE OR REPLACE keeps the existing grant since the original two
-- parameters are unchanged and the new one is appended with a default.

create or replace function public.get_advertiser_daily(
  p_account_id   uuid,
  p_days         integer default 30,
  p_campaign_id  uuid    default null
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
    and (p_campaign_id is null or c.id = p_campaign_id)
    and ae.created_at >= (now() - make_interval(days => greatest(1, least(p_days, 365))))
  group by day
  order by day;
$$;

grant execute on function public.get_advertiser_daily(uuid, integer, uuid) to authenticated;
