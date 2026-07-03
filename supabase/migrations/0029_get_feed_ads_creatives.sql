-- Ad platform — Phase A-4 Part 1: extend get_feed_ads for standalone creatives.
-- Adds, on top of the 0025 serving query:
--   • standalone creative payload (image/headline/body/click_url + advertiser name),
--   • topic targeting: when a campaign has ad_targeting.topic_ids, require overlap
--     with the viewer's user_topics (untargeted campaigns still serve broadly),
--   • a guard so a creative-less standalone campaign (no event/post, no creative)
--     never serves,
--   • block exclusion for standalone campaigns via advertiser_account_id → profile_id.
-- 'pending_review'/'paused' campaigns are excluded as before (status='active' only).
-- The return adds five nullable columns; existing host-boost rows return them null,
-- so AdService keeps hydrating event/post campaigns unchanged.

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
