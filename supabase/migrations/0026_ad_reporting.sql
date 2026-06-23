-- Ad platform — Phase A-3: reporting & budget enforcement.
-- Adds two SECURITY DEFINER RPCs:
--   tally_ad_spend()        — cron-invoked nightly; recomputes spent_cents from
--                             ad_events per pricing_model and completes campaigns
--                             whose budget is exhausted or whose flight has ended.
--   get_boost_performance() — per-host in-app "boost performance" view: one row
--                             per campaign with impressions, clicks, ctr, spend.
-- Phase A-1 (serving) and A-2 (host-boost checkout) are already live (0025).

-- CPM/CPC rate columns: A-2 only sells 'flat' boosts, but the tally must price
-- cpm/cpc campaigns once A-4 sells them. Default 0 so existing flat rows are
-- untouched. rate_cents = price per 1000 impressions (cpm) or per click (cpc).
alter table public.ad_campaigns
  add column if not exists rate_cents int not null default 0;

-- ── Nightly tally + budget enforcement ───────────────────────────────────────
-- Recompute spend for every active campaign, then complete the exhausted ones.
-- Idempotent: spend is derived from ad_events (not incremented), so replays and
-- overlapping runs converge to the same value. Returns how many campaigns were
-- updated and how many were completed.
create or replace function public.tally_ad_spend()
returns table (updated int, completed int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated   int := 0;
  v_completed int := 0;
begin
  -- 1. Recompute spent_cents from the flight clock / logged ad_events per model.
  --    flat (the only model A-2 sells): FLAT DAILY BURN — the committed budget
  --          accrues evenly across the flight window (budget * elapsed/total,
  --          capped at budget). Impressions/clicks are reported but do NOT drive
  --          flat spend. (Decision 2026-06-23.)
  --    cpm : impressions / 1000 * rate_cents.   (usage-priced, A-4)
  --    cpc : clicks * rate_cents.               (usage-priced, A-4)
  with spend as (
    select
      c.id,
      case c.pricing_model
        when 'flat' then least(
          c.budget_cents,
          floor(
            c.budget_cents
            * greatest(0, extract(epoch from (now() - c.starts_at)))
            / nullif(extract(epoch from (c.ends_at - c.starts_at)), 0)
          )::int
        )
        when 'cpm'  then floor(
          (count(*) filter (where ae.kind = 'impression')) / 1000.0 * c.rate_cents
        )::int
        when 'cpc'  then
          (count(*) filter (where ae.kind = 'click')) * c.rate_cents
        else c.spent_cents
      end as computed_cents
    from ad_campaigns c
    left join ad_events ae on ae.campaign_id = c.id
    where c.status = 'active'
    group by c.id
  )
  update ad_campaigns c
  set spent_cents = least(s.computed_cents, c.budget_cents)
  from spend s
  where c.id = s.id
    and c.spent_cents is distinct from least(s.computed_cents, c.budget_cents);
  get diagnostics v_updated = row_count;

  -- 2. Complete campaigns whose flight has ended, or whose budget is exhausted
  --    under USAGE pricing. A flat boost commits its whole budget up front, so
  --    "spent == budget" is true from the first tally — it must keep serving for
  --    the full purchased duration, completing only when ends_at passes. cpm/cpc
  --    campaigns genuinely run out of budget, so they complete on exhaustion too.
  update ad_campaigns
  set status = 'completed'
  where status = 'active'
    and (
      now() >= ends_at
      or (pricing_model in ('cpm','cpc') and spent_cents >= budget_cents)
    );
  get diagnostics v_completed = row_count;

  return query select v_updated, v_completed;
end;
$$;

revoke all on function public.tally_ad_spend() from public, anon, authenticated;
-- Invoked only by the cron Edge Function (service role); not client-callable.

-- ── Per-host boost performance (in-app reporting view) ───────────────────────
-- One row per campaign owned by the calling host: lifetime impressions, clicks,
-- click-through rate, and spend vs budget. SECURITY DEFINER so it can read
-- ad_events (insert-only to clients) but it is scoped to auth.uid()'s own
-- campaigns, so a host only ever sees their own numbers.
create or replace function public.get_boost_performance()
returns table (
  campaign_id  uuid,
  name         text,
  event_id     uuid,
  status       text,
  budget_cents int,
  spent_cents  int,
  starts_at    timestamptz,
  ends_at      timestamptz,
  impressions  bigint,
  clicks       bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    c.id, c.name, c.event_id, c.status, c.budget_cents, c.spent_cents,
    c.starts_at, c.ends_at,
    count(ae.*) filter (where ae.kind = 'impression') as impressions,
    count(ae.*) filter (where ae.kind = 'click')      as clicks
  from ad_campaigns c
  left join ad_events ae on ae.campaign_id = c.id
  where c.advertiser_id = auth.uid()
  group by c.id
  order by c.created_at desc;
$$;

grant execute on function public.get_boost_performance() to authenticated;
