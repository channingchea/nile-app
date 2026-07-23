-- 0068: Rapids video ads (docs/plans/rapids.md, Phase 4).
--
-- A Rapids video ad is an ordinary ad_campaign whose creative carries
-- kind='video' + a video in the ad-creatives bucket. Same budget/checkout
-- (create-ad-payment), same review state machine (0038/0039), same billing
-- (tally_ad_spend derives spend from ad_events per campaign, placement-
-- agnostic — video impressions bill identically with no change). This adds:
--   • ad_creatives: kind ('image'|'video'), video_path, thumb_path,
--     duration_ms; image_url/body relaxed to nullable for video creatives,
--   • app_config.rapids_ad_frequency — server-tunable cadence (ad slot after
--     every Nth Rapid) read by the app without a release,
--   • get_rapids_ads — serving RPC for the vertical player (mirrors
--     get_feed_ads' exclusions, filtered to video creatives),
--   • get_feed_ads redefined to exclude video creatives (a video campaign
--     must never render as an image card in the feed).

-- ── ad_creatives: video creative support ─────────────────────────────────────
alter table public.ad_creatives
  add column kind        text not null default 'image'
             check (kind in ('image', 'video')),
  add column video_path  text,
  add column thumb_path  text,
  add column duration_ms int check (duration_ms is null or (duration_ms > 0 and duration_ms <= 61000));

alter table public.ad_creatives alter column image_url drop not null;
alter table public.ad_creatives alter column body      drop not null;

-- Keep 0034's canonical body limit (150); video creatives may omit body.
alter table public.ad_creatives drop constraint if exists ad_creatives_body_check;
alter table public.ad_creatives
  add constraint ad_creatives_body_check
  check (body is null or char_length(body) between 1 and 150);

-- Shape guard: an image creative needs image_url; a video creative needs
-- video_path + duration.
alter table public.ad_creatives
  add constraint ad_creatives_kind_shape check (
    (kind = 'image' and image_url is not null)
    or (kind = 'video' and video_path is not null and duration_ms is not null)
  );

-- ── ad-videos bucket ─────────────────────────────────────────────────────────
-- 0034 locked the ad-creatives bucket to images ≤5MB, so ad videos get their
-- own public-read bucket: mp4/quicktime + jpeg posters, 100MB cap. Writes go
-- through the portal's upload path (mirrors ad-creatives' posture — write
-- policy added alongside the portal change if it uploads client-side).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'ad-videos', 'ad-videos', true, 104857600,
  array['video/mp4', 'video/quicktime', 'image/jpeg']
)
on conflict (id) do nothing;

create policy "ad-videos: public read"
  on storage.objects for select using (bucket_id = 'ad-videos');

-- Portal uploads client-side at {account_id}/{uuid}.{ext} (same convention as
-- ad-creatives); scope writes to the caller's own advertiser-account folder.
create policy "ad-videos: advertiser write own folder"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'ad-videos'
    and exists (
      select 1 from public.advertiser_accounts a
      where a.id::text = (storage.foldername(name))[1]
        and a.auth_user_id = auth.uid()
    )
  );

-- ── app_config: Rapids ad cadence ────────────────────────────────────────────
alter table public.app_config
  add column if not exists rapids_ad_frequency int not null default 5
  check (rapids_ad_frequency >= 1);

-- ── get_rapids_ads — serving RPC for the vertical player ─────────────────────
-- Mirrors get_feed_ads (0033): active + in-flight + under budget, frequency
-- cap, topic targeting, not_interested / reported / blocked exclusions —
-- filtered to video creatives. SECURITY DEFINER for the same reasons.
create or replace function public.get_rapids_ads(
  page_limit  int default 5,
  freq_cap    int default 3   -- max impressions per campaign per viewer per day
)
returns table (
  campaign_id     uuid,
  video_path      text,
  thumb_path      text,
  headline        text,
  body            text,
  click_url       text,
  advertiser_name text,
  duration_ms     int
)
language sql
stable
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
    -- block exclusion via the account's linked profile, if any
    and not exists (
      select 1 from blocks b
      where a.profile_id is not null and (
        (b.blocker_id = auth.uid() and b.blocked_id = a.profile_id)
        or (b.blocked_id = auth.uid() and b.blocker_id = a.profile_id)
      )
    )
  order by c.starts_at desc
  limit page_limit;
$$;

grant execute on function public.get_rapids_ads(int, int) to authenticated;

-- ── get_feed_ads: exclude video creatives ────────────────────────────────────
-- Same signature and body as 0033 with ONE new predicate: a campaign whose
-- creative is kind='video' never serves in the image feed.
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
    -- NEW (0068): video creatives serve only in the Rapids player.
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
  order by c.starts_at desc
  limit page_limit;
$$;

grant execute on function public.get_feed_ads(int, int) to authenticated, anon;

-- ── cleanup_abandoned_ad_checkouts: also purge abandoned ad videos ───────────
-- 0035/0036 body + one extra delete for ad-videos objects (video creatives
-- store bucket-relative paths, not URLs).
create or replace function public.cleanup_abandoned_ad_checkouts()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  perform set_config('storage.allow_delete_query', 'true', true);

  with doomed as (
    -- Capture storage object paths BEFORE the cascade deletes ad_creatives.
    -- image_url is a public bucket URL; the object name is everything after
    -- '/ad-creatives/' (portal convention: {account_id}/{uuid}.{ext}).
    -- video_path/thumb_path (0068) are already bucket-relative ad-videos paths.
    select c.id as campaign_id,
           split_part(cr.image_url, '/ad-creatives/', 2) as object_name,
           cr.video_path,
           cr.thumb_path
    from ad_campaigns c
    left join ad_creatives cr on cr.campaign_id = c.id
    where c.status = 'pending_payment'
      and c.created_at < now() - interval '24 hours'
  ),
  del_objects as (
    delete from storage.objects o
    using doomed d
    where o.bucket_id = 'ad-creatives'
      and d.object_name is not null
      and d.object_name <> ''
      and o.name = d.object_name
    returning o.id
  ),
  del_videos as (
    delete from storage.objects o
    using doomed d
    where o.bucket_id = 'ad-videos'
      and o.name in (d.video_path, d.thumb_path)
    returning o.id
  ),
  del_campaigns as (
    delete from ad_campaigns c
    where c.id in (select campaign_id from doomed)
    returning c.id
  )
  select count(*) into v_count from del_campaigns;
  return v_count;
end;
$$;
