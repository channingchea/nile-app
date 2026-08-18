-- 0125 — P2 #28 from the 2026-08-16 platform review: the reporting an
-- advertiser sees can't support a renewal decision.
--
-- get_advertiser_performance / get_advertiser_daily returned raw impressions
-- and clicks. Raw counts answer "did it run", not "was it worth it": a
-- thousand impressions against fifty people is a very different buy from a
-- thousand against nine hundred, and nothing in the portal could tell those
-- apart. Every figure below is derivable from ad_events + spent_cents, so this
-- is presentation the data already supports, not new collection.
--
--   reach       distinct viewers who saw it at all
--   frequency   impressions / reach — how hard we leaned on the same people
--   ecpm_cents  cost per thousand impressions
--   ecpc_cents  cost per click (null until there is a click, not zero)
--
-- Money-per-outcome is computed from spent_cents, which since 0115 follows
-- delivered days rather than the wall clock — so eCPM is honest on a campaign
-- that spent part of its flight undelivered.
--
-- Also drops ad_targeting.geo / min_age / max_age. They have been declared
-- since 0028, are written by nothing, are read by nothing, and are NULL in
-- every row. Left in place they are a trap: the first targeting UI to bind to
-- them would sell an advertiser a filter that silently does nothing. Topic
-- targeting is the only targeting Nile actually has.

-- ── per-campaign performance ────────────────────────────────────────────────
drop function public.get_advertiser_performance(uuid, integer, timestamptz); -- return type change

create function public.get_advertiser_performance(
  p_account_id uuid,
  p_limit      integer     default 15,
  p_before     timestamptz default null   -- keyset cursor: created_at of last row
)
returns table (
  campaign_id          uuid,
  name                 text,
  headline             text,
  status               text,
  budget_cents         integer,
  spent_cents          integer,
  starts_at            timestamptz,
  ends_at              timestamptz,
  impressions          bigint,
  clicks               bigint,
  reach                bigint,
  frequency            numeric,
  ecpm_cents           numeric,
  ecpc_cents           numeric,
  review_note          text,
  created_at           timestamptz,
  placement            text,
  event_title          text,
  event_scheduled_at   timestamptz,
  host_note            text,
  offer_expires_at     timestamptz,
  last_decline_code    text,
  payment_recovery_url text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    c.id, c.name, cr.headline, c.status, c.budget_cents, c.spent_cents,
    c.starts_at, c.ends_at,
    m.impressions,
    m.clicks,
    m.reach,
    round(m.impressions::numeric / nullif(m.reach, 0), 2)                        as frequency,
    round(c.spent_cents::numeric * 1000 / nullif(m.impressions, 0), 2)           as ecpm_cents,
    round(c.spent_cents::numeric / nullif(m.clicks, 0), 2)                       as ecpc_cents,
    c.review_note, c.created_at,
    c.placement, e.title, e.scheduled_at,
    c.host_note, c.offer_expires_at, c.last_decline_code, c.payment_recovery_url
  from ad_campaigns c
  join advertiser_accounts a
    on a.id = c.advertiser_account_id
   and a.auth_user_id = auth.uid()          -- caller must own the account
  left join ad_creatives cr on cr.campaign_id = c.id
  left join events       e  on e.id = c.event_id
  -- Aggregate before the join rather than grouping after it: one row per
  -- campaign regardless of what else is joined on, and distinct-count stays
  -- correct if a second creative is ever allowed.
  cross join lateral (
    select
      count(*) filter (where ae.kind = 'impression')                  as impressions,
      count(*) filter (where ae.kind = 'click')                       as clicks,
      count(distinct ae.viewer_id) filter (where ae.kind = 'impression') as reach
    from ad_events ae
    where ae.campaign_id = c.id
  ) m
  where c.advertiser_account_id = p_account_id
    and (p_before is null or c.created_at < p_before)
  order by c.created_at desc
  limit greatest(1, least(p_limit, 100));
$$;

revoke execute on function public.get_advertiser_performance(uuid, integer, timestamptz)
  from public, anon;
grant execute on function public.get_advertiser_performance(uuid, integer, timestamptz)
  to authenticated;

-- ── daily trend, now with reach ─────────────────────────────────────────────
-- Dropping the TWO-argument form on purpose: 0052 added a p_campaign_id
-- parameter to this function and was never applied to prod, so the live
-- database still had (uuid, integer) while AdvertiserPortal.vue has been
-- calling it with p_campaign_id to filter the chart — a call PostgREST could
-- only answer with "function not found". The per-campaign chart filter has
-- been broken in production ever since; recreating it at the 0052 signature
-- fixes that as a side effect.
drop function public.get_advertiser_daily(uuid, integer); -- 0052's signature was never on prod

create function public.get_advertiser_daily(
  p_account_id   uuid,
  p_days         integer default 30,
  p_campaign_id  uuid    default null
)
returns table (
  day         date,
  impressions bigint,
  clicks      bigint,
  reach       bigint
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    (ae.created_at at time zone 'UTC')::date as day,
    count(*) filter (where ae.kind = 'impression')                     as impressions,
    count(*) filter (where ae.kind = 'click')                          as clicks,
    count(distinct ae.viewer_id) filter (where ae.kind = 'impression') as reach
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

revoke execute on function public.get_advertiser_daily(uuid, integer, uuid) from public, anon;
grant  execute on function public.get_advertiser_daily(uuid, integer, uuid) to authenticated;

-- ── where the money went ────────────────────────────────────────────────────
-- A campaign carries exactly one placement, so the breakdown an advertiser
-- wants is across their campaigns, not within one. Reach is counted distinctly
-- per placement — the same person seeing a feed ad and a lobby ad is one
-- viewer in each row and legitimately two here.
create function public.get_advertiser_placement_summary(
  p_account_id uuid,
  p_days       integer default 30
)
returns table (
  placement   text,
  campaigns   bigint,
  impressions bigint,
  clicks      bigint,
  reach       bigint,
  spent_cents bigint,
  ecpm_cents  numeric
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with scoped as (
    select c.id, c.placement, c.spent_cents
    from ad_campaigns c
    join advertiser_accounts a
      on a.id = c.advertiser_account_id
     and a.auth_user_id = auth.uid()
    where c.advertiser_account_id = p_account_id
      and c.created_at >= (now() - make_interval(days => greatest(1, least(p_days, 365))))
  )
  select
    s.placement,
    count(distinct s.id)                                                  as campaigns,
    count(*) filter (where ae.kind = 'impression')                        as impressions,
    count(*) filter (where ae.kind = 'click')                             as clicks,
    count(distinct ae.viewer_id) filter (where ae.kind = 'impression')    as reach,
    -- spent_cents lives on the campaign, so sum it once per campaign rather
    -- than once per event row.
    (select coalesce(sum(s2.spent_cents), 0) from scoped s2 where s2.placement = s.placement) as spent_cents,
    round(
      (select coalesce(sum(s2.spent_cents), 0) from scoped s2 where s2.placement = s.placement)::numeric
      * 1000 / nullif(count(*) filter (where ae.kind = 'impression'), 0), 2)                   as ecpm_cents
  from scoped s
  left join ad_events ae on ae.campaign_id = s.id
  group by s.placement
  order by s.placement;
$$;

revoke execute on function public.get_advertiser_placement_summary(uuid, integer) from public, anon;
grant  execute on function public.get_advertiser_placement_summary(uuid, integer) to authenticated;

-- ── stop advertising targeting we don't have ────────────────────────────────
alter table public.ad_targeting
  drop column if exists geo,
  drop column if exists min_age,
  drop column if exists max_age;
