-- Ad platform — review finding #3: "not interested" / "report" only hid an ad
-- for the current session. get_feed_ads never checked ad_events.not_interested
-- or reports rows, so the same ad returned on the next feed load.
-- This redefines the RPC (0029 body unchanged otherwise) with two exclusions:
--   • campaigns the viewer marked not_interested (any time, not just today),
--   • campaigns the viewer reported (reports.target_type = 'ad').
-- Anonymous viewers skip both (they can't have signals). SECURITY DEFINER lets
-- the function read reports despite its insert-only RLS.

drop function if exists public.get_feed_ads(int, int);

create or replace function public.get_feed_ads(
  page_limit  int default 5,
  freq_cap    int default 3   -- max impressions per campaign per viewer per day
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
stable
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
  order by c.starts_at desc
  limit page_limit;
$$;

grant execute on function public.get_feed_ads(int, int) to authenticated, anon;

-- Cheap lookup for the not_interested exclusion (the impression index from 0025
-- doesn't cover this kind).
create index if not exists ad_events_not_interested_idx
  on public.ad_events (viewer_id, campaign_id)
  where kind = 'not_interested';

-- Reports exclusion lookup: reporter + ad target.
create index if not exists reports_ad_reporter_idx
  on public.reports (reporter_id, target_id)
  where target_type = 'ad';
