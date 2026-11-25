-- 0123 — P2 #26 from the 2026-08-16 platform review: a signed-out session
-- bypassed every viewer predicate in ad serving.
--
-- Each check in get_feed_ads / get_currents_ads was guarded with
-- `auth.uid() is null or …`, so anon matched all of them at once: topic
-- targeting, the frequency cap, "not interested", the report suppression and
-- the block list were all skipped, and both functions were granted to anon.
-- An advertiser who bought Worship reached every anonymous session regardless
-- of interest, uncapped, unsuppressable.
--
-- Since 0114 a signed-out impression cannot be logged at all (log_ad_event
-- returns 'anonymous'), so those deliveries were never billed, never capped
-- and never counted — unattributable inventory the advertiser paid nothing
-- for and learned nothing from. Both callers in the app (home_screen,
-- currents_player_screen) sit behind auth, and the website never calls either
-- function, so nothing legitimate is asking for them.
--
-- Two layers, the same shape 0100 used:
--   • the anon grant goes away — `from public, anon`, because REVOKE … FROM
--     anon alone is a no-op while PUBLIC still holds EXECUTE (the 0060 rule);
--   • the bodies require a viewer themselves, so a future re-grant, or a
--     service_role caller, cannot silently reopen it.
--
-- Rows returned to a signed-out caller: none, by construction.

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
  where
    -- No viewer, no ads. Everything below this line is a per-viewer decision;
    -- without an identity none of them mean anything.
    auth.uid() is not null
    and c.status = 'active'
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
      or exists (
        select 1 from user_topics ut
        where ut.user_id = auth.uid()
          and ut.topic_id = any (t.topic_ids)
      )
    )
    -- frequency cap: skip campaigns this viewer has seen >= freq_cap times today
    and (
      select count(*) from ad_events ae
      where ae.campaign_id = c.id
        and ae.viewer_id = auth.uid()
        and ae.kind = 'impression'
        and ae.created_at >= date_trunc('day', now())
    ) < freq_cap
    -- viewer said "not interested" — permanent exclusion for that viewer
    and not exists (
      select 1 from ad_events ni
      where ni.campaign_id = c.id
        and ni.viewer_id = auth.uid()
        and ni.kind = 'not_interested'
    )
    -- viewer reported this ad — permanent exclusion for that viewer
    and not exists (
      select 1 from reports r
      where r.reporter_id = auth.uid()
        and r.target_type = 'ad'
        and r.target_id = c.id
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
  where
    auth.uid() is not null
    and c.status = 'active'
    and now() between c.starts_at and c.ends_at
    and c.spent_cents < c.budget_cents
    and (
      t.topic_ids is null
      or cardinality(t.topic_ids) = 0
      or exists (
        select 1 from user_topics ut
        where ut.user_id = auth.uid()
          and ut.topic_id = any (t.topic_ids)
      )
    )
    and (
      select count(*) from ad_events ae
      where ae.campaign_id = c.id
        and ae.viewer_id = auth.uid()
        and ae.kind = 'impression'
        and ae.created_at >= date_trunc('day', now())
    ) < freq_cap
    and not exists (
      select 1 from ad_events ni
      where ni.campaign_id = c.id
        and ni.viewer_id = auth.uid()
        and ni.kind = 'not_interested'
    )
    and not exists (
      select 1 from reports r
      where r.reporter_id = auth.uid()
        and r.target_type = 'ad'
        and r.target_id = c.id
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

revoke execute on function public.get_feed_ads(int, int)     from public, anon;
revoke execute on function public.get_currents_ads(int, int) from public, anon;
grant  execute on function public.get_feed_ads(int, int)     to authenticated;
grant  execute on function public.get_currents_ads(int, int) to authenticated;
