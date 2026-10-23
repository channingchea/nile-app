-- In-show sponsor logo (graphics library expansions, phase 4).
--
-- A Pre-Show sponsor can also appear on screen during the show, as a free
-- bonus at the host's choice:
--   • ad_creatives.logo_path — an optional square logo the advertiser uploads
--     with the offer (ad-creatives bucket, their own account folder). The
--     livekit `set-graphics` action looks it up; the Studio never sends it.
--   • ad_events.surface — null for every existing kind of event, 'in_show'
--     for the logo. In-show impressions are reported on their own line and
--     never bill: tally_ad_spend already skips lobby campaigns, the only
--     campaigns that can have them.
--   • log_in_show_sponsor_impression — once per viewer per show, only while
--     the show is live.

-- ── the logo ────────────────────────────────────────────────────────────────
alter table public.ad_creatives
  add column if not exists logo_path text
  check (logo_path is null or (char_length(logo_path) <= 200
                               and logo_path ~ '^[0-9a-f-]{36}/[0-9A-Za-z_-]+\.(png|jpg|jpeg|webp)$'));

-- The logo must sit in the campaign's own advertiser folder.
create or replace function public.ad_creative_logo_owned()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.logo_path is not null and split_part(new.logo_path, '/', 1) <> (
    select c.advertiser_account_id::text from ad_campaigns c where c.id = new.campaign_id
  ) then
    raise exception 'logo must be uploaded by this advertiser' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists ad_creative_logo_owned on public.ad_creatives;
create trigger ad_creative_logo_owned
  before insert or update of logo_path on public.ad_creatives
  for each row execute function public.ad_creative_logo_owned();

-- ── where an impression happened ────────────────────────────────────────────
alter table public.ad_events
  add column if not exists surface text check (surface is null or surface = 'in_show');

-- The hourly dedupe stays for every existing surface; the logo gets its own:
-- one impression per viewer per campaign (a lobby campaign is one show).
drop index if exists public.ad_events_dedupe_idx;
create unique index ad_events_dedupe_idx
  on public.ad_events (campaign_id, viewer_id, kind, hour_bucket)
  where viewer_id is not null and surface is null;
create unique index ad_events_in_show_once_idx
  on public.ad_events (campaign_id, viewer_id)
  where surface = 'in_show' and kind = 'impression';

create or replace function public.log_in_show_sponsor_impression(
  p_campaign_id uuid,
  p_event_id    uuid
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then return 'anonymous'; end if;
  perform 1
    from ad_campaigns c
    join events e on e.id = c.event_id
   where c.id = p_campaign_id
     and c.event_id = p_event_id
     and c.placement = 'lobby'
     and c.status in ('active', 'completed')
     and e.status = 'live'
     and e.host_id <> v_uid;
  if not found then return 'not_servable'; end if;

  insert into ad_events (campaign_id, viewer_id, kind, surface)
  values (p_campaign_id, v_uid, 'impression', 'in_show')
  on conflict do nothing;
  if not found then return 'duplicate'; end if;
  return 'logged';
end;
$$;

revoke execute on function public.log_in_show_sponsor_impression(uuid, uuid) from public, anon;
grant  execute on function public.log_in_show_sponsor_impression(uuid, uuid) to authenticated;

-- ── the Studio learns about the logo ────────────────────────────────────────
drop function public.get_lobby_sponsorship(uuid); -- return type change
create function public.get_lobby_sponsorship(p_event_id uuid)
returns table (
  campaign_id uuid, kind text, image_url text, video_path text, thumb_path text,
  duration_ms integer, headline text, click_url text, advertiser_name text,
  auto_accepted boolean, logo_path text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    c.id, cr.kind, cr.image_url, cr.video_path, cr.thumb_path, cr.duration_ms,
    cr.headline, cr.click_url, a.name, c.auto_accepted, cr.logo_path
  from ad_campaigns c
  join ad_creatives cr on cr.campaign_id = c.id
  left join advertiser_accounts a on a.id = c.advertiser_account_id
  where c.event_id = p_event_id
    and c.placement = 'lobby'
    and c.status in ('active', 'completed')
  limit 1;
$$;
grant execute on function public.get_lobby_sponsorship(uuid) to authenticated;

-- ── reporting: in-show impressions on their own line ────────────────────────
drop function public.get_advertiser_performance(uuid, integer, timestamptz); -- return type change
create function public.get_advertiser_performance(
  p_account_id uuid,
  p_limit      integer     default 15,
  p_before     timestamptz default null
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
  payment_recovery_url text,
  in_show_impressions  bigint
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
    c.host_note, c.offer_expires_at, c.last_decline_code, c.payment_recovery_url,
    m.in_show_impressions
  from ad_campaigns c
  join advertiser_accounts a
    on a.id = c.advertiser_account_id
   and a.auth_user_id = auth.uid()
  left join ad_creatives cr on cr.campaign_id = c.id
  left join events       e  on e.id = c.event_id
  cross join lateral (
    select
      count(*) filter (where ae.kind = 'impression' and ae.surface is null)                  as impressions,
      count(*) filter (where ae.kind = 'click' and ae.surface is null)                       as clicks,
      count(distinct ae.viewer_id) filter (where ae.kind = 'impression' and ae.surface is null) as reach,
      count(*) filter (where ae.kind = 'impression' and ae.surface = 'in_show')              as in_show_impressions
    from ad_events ae
    where ae.campaign_id = c.id
  ) m
  where c.advertiser_account_id = p_account_id
    and (p_before is null or c.created_at < p_before)
  order by c.created_at desc
  limit greatest(1, least(p_limit, 100));
$$;
revoke execute on function public.get_advertiser_performance(uuid, integer, timestamptz) from public, anon;
grant  execute on function public.get_advertiser_performance(uuid, integer, timestamptz) to authenticated;

-- The daily trend and placement summary keep counting what they always did.
create or replace function public.get_advertiser_daily(
  p_account_id   uuid,
  p_days         integer default 30,
  p_campaign_id  uuid    default null
)
returns table (day date, impressions bigint, clicks bigint, reach bigint)
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
    and ae.surface is null
    and ae.created_at >= (now() - make_interval(days => greatest(1, least(p_days, 365))))
  group by day
  order by day;
$$;

create or replace function public.get_advertiser_placement_summary(
  p_account_id uuid,
  p_days       integer default 30
)
returns table (
  placement text, campaigns bigint, impressions bigint, clicks bigint,
  reach bigint, spent_cents bigint, ecpm_cents numeric
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
    (select coalesce(sum(s2.spent_cents), 0) from scoped s2 where s2.placement = s.placement) as spent_cents,
    round(
      (select coalesce(sum(s2.spent_cents), 0) from scoped s2 where s2.placement = s.placement)::numeric
      * 1000 / nullif(count(*) filter (where ae.kind = 'impression'), 0), 2)                   as ecpm_cents
  from scoped s
  left join ad_events ae on ae.campaign_id = s.id and ae.surface is null
  group by s.placement
  order by s.placement;
$$;
