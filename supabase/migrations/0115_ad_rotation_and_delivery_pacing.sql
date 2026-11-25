-- 0115 — P2 #21 from the 2026-08-16 platform review: only the 5 newest
-- campaigns could ever serve, while flat spend burned on the wall clock.
--
-- Two halves of the same injury to the same advertiser.
--
-- SERVING. get_feed_ads and get_currents_ads both ended `order by
-- c.starts_at desc limit page_limit`, and the app never passes page_limit, so
-- the default 5 stands. Sort by newest, take five: the sixth advertiser to buy
-- a boost never appeared in a single feed. Not rarely — never, until one of the
-- five ahead of them ended. There was no rotation, no weighting and no pacing
-- of any kind.
--
-- BILLING. Flat spend was `budget × elapsed / total` — pure clock, blind to
-- whether anything was ever shown. So that sixth advertiser watched their
-- dashboard climb to $50 against zero impressions, and nothing anywhere
-- recorded that they had been sold nothing.
--
-- Fix both, and they reinforce each other: spend now only accrues on days the
-- campaign actually delivered, and serving priority is weighted by UNSPENT
-- budget — so a campaign that has been starved keeps its full weight and gets
-- picked first, while one that has been delivering tapers off. That is a
-- makegood loop rather than a queue.

-- ── serving order ───────────────────────────────────────────────────────────
-- Weighted random sampling without replacement (Efraimidis–Spirakis): draw a
-- key of -ln(u)/w per row and take the smallest. A campaign with twice the
-- remaining budget is drawn twice as often, every eligible campaign has a
-- non-zero chance every single call, and nothing is ever permanently behind
-- anything else.
--
-- random() is VOLATILE, so both functions become VOLATILE too. A STABLE
-- function is contractually required to return the same rows for the same
-- arguments within one statement, which is precisely what we are giving up on
-- purpose. Both are already called over POST via supabase.rpc().
--
-- greatest(random(), 1e-9) because random() can return exactly 0 and ln(0)
-- raises.

create or replace function public.get_feed_ads(
  page_limit  int default 5,
  freq_cap    int default 3
)
returns table (
  campaign_id     uuid,
  event_id        uuid,
  post_id         uuid,
  creative_id     uuid,
  image_url       text,
  headline        text,
  body            text,
  click_url       text,
  advertiser_name text
)
language sql
volatile
security definer
set search_path = public
as $$
  select
    c.id, c.event_id, c.post_id,
    cr.id, cr.image_url, cr.headline, cr.body, cr.click_url,
    a.name
  from ad_campaigns c
  left join ad_creatives       cr on cr.campaign_id = c.id
  left join ad_targeting       t  on t.campaign_id  = c.id
  left join advertiser_accounts a  on a.id          = c.advertiser_account_id
  where c.status = 'active'
    and now() between c.starts_at and c.ends_at
    and c.spent_cents < c.budget_cents
    -- A standalone campaign (no event/post) must carry a creative to serve.
    and (c.event_id is not null or c.post_id is not null or cr.id is not null)
    -- 0068: video creatives serve only in the Currents player.
    and (cr.id is null or cr.kind = 'image')
    -- Topic targeting: if topic_ids is set, require overlap with the viewer's
    -- interests; untargeted (empty/null) campaigns serve broadly.
    and (
      t.topic_ids is null
      or cardinality(t.topic_ids) = 0
      or auth.uid() is null
      or exists (
        select 1 from user_topics ut
        where ut.user_id = auth.uid()
          and ut.topic_id = any (t.topic_ids)
      )
    )
    -- frequency cap: skip campaigns this viewer has seen >= freq_cap times today
    and (
      auth.uid() is null
      or (
        select count(*) from ad_events ae
        where ae.campaign_id = c.id
          and ae.viewer_id = auth.uid()
          and ae.kind = 'impression'
          and ae.created_at >= date_trunc('day', now())
      ) < freq_cap
    )
    -- viewer said "not interested" — permanent exclusion for that viewer
    and (
      auth.uid() is null
      or not exists (
        select 1 from ad_events ni
        where ni.campaign_id = c.id
          and ni.viewer_id = auth.uid()
          and ni.kind = 'not_interested'
      )
    )
    -- viewer reported this ad — permanent exclusion for that viewer
    and (
      auth.uid() is null
      or not exists (
        select 1 from reports r
        where r.reporter_id = auth.uid()
          and r.target_type = 'ad'
          and r.target_id = c.id
      )
    )
    -- block exclusion: host-boost (advertiser_id) or standalone (account's linked
    -- profile, if any). A standalone account with no linked profile can't be blocked.
    and not exists (
      select 1 from blocks b, lateral (select coalesce(c.advertiser_id, a.profile_id) as adv) z
      where z.adv is not null and (
        (b.blocker_id = auth.uid() and b.blocked_id = z.adv)
        or (b.blocked_id = auth.uid() and b.blocker_id = z.adv)
      )
    )
    -- a promoted event must still be live/scheduled (not ended/draft)
    and (c.event_id is null or exists (
      select 1 from events e
      where e.id = c.event_id and e.status in ('scheduled','live','soundcheck')
    ))
  order by -ln(greatest(random(), 1e-9))
           / greatest(c.budget_cents - c.spent_cents, 1)::float8
  limit page_limit;
$$;

create or replace function public.get_currents_ads(
  page_limit  int default 5,
  freq_cap    int default 3
)
returns table (
  campaign_id     uuid,
  video_path      text,
  thumb_path      text,
  headline        text,
  body            text,
  click_url       text,
  advertiser_name text,
  duration_ms     integer
)
language sql
volatile
security definer
set search_path = public
as $$
  select
    c.id, cr.video_path, cr.thumb_path, cr.headline, cr.body, cr.click_url,
    a.name, cr.duration_ms
  from ad_campaigns c
  join ad_creatives        cr on cr.campaign_id = c.id and cr.kind = 'video'
  left join ad_targeting       t  on t.campaign_id  = c.id
  left join advertiser_accounts a  on a.id          = c.advertiser_account_id
  where c.status = 'active'
    and now() between c.starts_at and c.ends_at
    and c.spent_cents < c.budget_cents
    and (
      t.topic_ids is null
      or cardinality(t.topic_ids) = 0
      or auth.uid() is null
      or exists (
        select 1 from user_topics ut
        where ut.user_id = auth.uid()
          and ut.topic_id = any (t.topic_ids)
      )
    )
    and (
      auth.uid() is null
      or (
        select count(*) from ad_events ae
        where ae.campaign_id = c.id
          and ae.viewer_id = auth.uid()
          and ae.kind = 'impression'
          and ae.created_at >= date_trunc('day', now())
      ) < freq_cap
    )
    and (
      auth.uid() is null
      or not exists (
        select 1 from ad_events ni
        where ni.campaign_id = c.id
          and ni.viewer_id = auth.uid()
          and ni.kind = 'not_interested'
      )
    )
    and (
      auth.uid() is null
      or not exists (
        select 1 from reports r
        where r.reporter_id = auth.uid()
          and r.target_type = 'ad'
          and r.target_id = c.id
      )
    )
    and not exists (
      select 1 from blocks b
      where a.profile_id is not null and (
        (b.blocker_id = auth.uid() and b.blocked_id = a.profile_id)
        or (b.blocked_id = auth.uid() and b.blocker_id = a.profile_id)
      )
    )
  order by -ln(greatest(random(), 1e-9))
           / greatest(c.budget_cents - c.spent_cents, 1)::float8
  limit page_limit;
$$;

-- ── flat spend follows delivery, not the clock ──────────────────────────────
-- Flat is sold as "N days of placement". It now bills for the days the
-- campaign actually appeared: distinct UTC days carrying at least one
-- impression, over the days in the flight.
--
-- Days rather than hours on purpose. Hour-granularity would quietly halve every
-- flat invoice, because there is no traffic at 4am and that is not the
-- advertiser's fault. A day on which the ad served at all is a day they got
-- what they bought.
--
-- delivered_days can never exceed elapsed days, so this is self-capping — the
-- old `elapsed / total` term is redundant and gone.
--
-- Two consequences worth stating plainly:
--   • A campaign that never serves now bills nothing, and completes at ends_at
--     with spent_cents < budget_cents. That gap IS the under-delivery report;
--     there was previously no way at all to detect it. Refunding the gap is
--     review #23/#25 and is not built yet.
--   • It also fixes review #24 as a side effect: a campaign paused on day 2 and
--     resumed on day 5 delivers nothing in between, so the paused window no
--     longer back-bills on the next tally.

create or replace function public.tally_ad_spend()
returns table (updated integer, completed integer)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_updated   int := 0;
  v_completed int := 0;
begin
  with spend as (
    select
      c.id,
      case c.pricing_model
        when 'flat' then least(
          c.budget_cents,
          floor(
            c.budget_cents
            * (count(distinct date_trunc('day', ae.created_at, 'UTC'))
                 filter (where ae.kind = 'impression'))::numeric
            / greatest(
                1,
                ceil(extract(epoch from (c.ends_at - c.starts_at)) / 86400.0)
              )
          )::int
        )
        when 'cpm'  then floor((count(*) filter (where ae.kind = 'impression')) / 1000.0 * c.rate_cents)::int
        when 'cpc'  then (count(*) filter (where ae.kind = 'click')) * c.rate_cents
        else c.spent_cents
      end as computed_cents
    from ad_campaigns c
    left join ad_events ae on ae.campaign_id = c.id
    where c.status = 'active'
      and c.placement <> 'lobby'
    group by c.id
  )
  update ad_campaigns c
  set spent_cents = least(s.computed_cents, c.budget_cents)
  from spend s
  where c.id = s.id
    and c.spent_cents is distinct from least(s.computed_cents, c.budget_cents);
  get diagnostics v_updated = row_count;

  update ad_campaigns
  set status = 'completed'
  where status = 'active'
    and placement <> 'lobby'
    and (now() >= ends_at or (pricing_model in ('cpm','cpc') and spent_cents >= budget_cents));
  get diagnostics v_completed = row_count;

  return query select v_updated, v_completed;
end;
$function$;
