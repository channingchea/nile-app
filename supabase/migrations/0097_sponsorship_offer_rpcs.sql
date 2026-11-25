-- 0097: Sponsorship offers — RPCs and price suggestion.
-- (docs/plans/sponsorship-offers-host-approved.md, Phase 2)
--
--   get_sponsorable_events        the portal's event picker, now offer-shaped
--   suggest_sponsorship_price     a CPM-based starting number, honestly labelled
--   host_sponsorship_offers       what the Flutter host screen renders
--   host_sponsorship_offer_count  the nav badge
--   get_advertiser_performance    + the host's note and the offer clock

-- ── get_sponsorable_events ───────────────────────────────────────────────────
-- Lead time is 72h now (was 24h): Nile's policy screen and the host's decision
-- both have to fit before the offer expires 48h out. An event is listed until
-- someone's offer is ACCEPTED — competing bids no longer block each other.
create or replace function public.get_sponsorable_events(
  search     text default null,
  page_limit int  default 20
)
returns table (
  event_id        uuid,
  title           text,
  cover_image_url text,
  scheduled_at    timestamptz,
  host_username   text,
  host_name       text,
  host_avatar_url text,
  is_ticketed     boolean,
  min_offer_cents int,
  max_offer_cents int,
  offer_cap       int,
  my_offer_count  bigint
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    e.id, e.title, e.cover_image_url, e.scheduled_at,
    p.username,
    coalesce(p.display_name, p.username),
    p.avatar_url,
    (e.price is not null and e.price > 0),
    greatest(coalesce(e.sponsorship_min_offer_cents, cfg.sponsorship_min_offer_cents),
             cfg.sponsorship_min_offer_cents),
    cfg.sponsorship_max_offer_cents,
    cfg.sponsorship_offer_cap,
    mine.n
  from events e
  join profiles p on p.id = e.host_id
  cross join (select sponsorship_min_offer_cents, sponsorship_max_offer_cents,
                     sponsorship_offer_cap
              from app_config where id = 1) cfg
  -- Offers this advertiser has already made here. A campaign Nile or Stripe
  -- killed ('rejected') is not the advertiser's fault and doesn't burn a slot;
  -- everything else does, including offers the host let expire.
  left join lateral (
    select count(*) as n
    from ad_campaigns c2
    join advertiser_accounts a2 on a2.id = c2.advertiser_account_id
    where c2.event_id = e.id
      and c2.placement = 'lobby'
      and c2.status <> 'rejected'
      and a2.auth_user_id = auth.uid()
  ) mine on true
  where e.sponsorship_open
    and e.status = 'scheduled'
    and e.removed_at is null
    and e.scheduled_at >= now() + interval '72 hours'
    and p.stripe_account_id is not null
    and p.suspended_at is null
    and not exists (
      select 1 from ad_campaigns c
      where c.event_id = e.id
        and c.placement = 'lobby'
        and c.status in ('active', 'completed')
    )
    and (
      search is null or btrim(search) = ''
      or e.title ilike '%' || btrim(search) || '%'
      or p.username ilike '%' || btrim(search) || '%'
      or p.display_name ilike '%' || btrim(search) || '%'
    )
  order by e.scheduled_at asc
  limit least(greatest(page_limit, 1), 50);
$$;

grant execute on function public.get_sponsorable_events(text, int) to authenticated;

-- ── suggest_sponsorship_price ────────────────────────────────────────────────
-- A starting number, not a price. `basis` exists so the UI can say "based on 4
-- past events" or "estimated from follower count" and never pass a guess off as
-- data — follower count is a weak proxy for attendance, and until events
-- accumulate it is all there is.
--
-- Reach = median peak_viewer_count over the host's last 5 events that actually
-- happened. Once five comparable sponsorships have been accepted in the same
-- reach band, their observed 25th–75th percentile replaces the modelled range;
-- individual deal amounts stay private (a percentile over ≥5 rows is not one).
create or replace function public.suggest_sponsorship_price(p_event_id uuid)
returns table (
  suggested_cents int,
  low_cents       int,
  high_cents      int,
  basis           text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_host  uuid;
  v_min   int;
  v_max   int;
  v_cpm   int;
  v_reach numeric;
  v_n     int;
  v_basis text;
  v_sug   int;
  v_low   int;
  v_high  int;
  v_comps int;
  v_p25   numeric;
  v_p75   numeric;
begin
  select host_id into v_host from events where id = p_event_id and removed_at is null;
  if v_host is null then return; end if;

  select sponsorship_min_offer_cents, sponsorship_max_offer_cents, sponsorship_target_cpm_cents
    into v_min, v_max, v_cpm
  from app_config where id = 1;

  -- The host's own floor for this event raises the platform floor, never lowers it.
  select greatest(coalesce(e.sponsorship_min_offer_cents, v_min), v_min)
    into v_min
  from events e where e.id = p_event_id;

  with recent as (
    select peak_viewer_count
    from events
    where host_id = v_host
      and status = 'ended'
      and started_at is not null
      and removed_at is null
      and peak_viewer_count > 0
    order by scheduled_at desc
    limit 5
  )
  select count(*)::int,
         percentile_cont(0.5) within group (order by peak_viewer_count)
    into v_n, v_reach
  from recent;

  if coalesce(v_n, 0) = 0 or coalesce(v_reach, 0) <= 0 then
    select coalesce(follower_count, 0) * 0.05 into v_reach from profiles where id = v_host;
    v_basis := 'estimated from follower count';
  else
    v_basis := v_n || case when v_n = 1 then ' past event' else ' past events' end;
  end if;
  v_reach := coalesce(v_reach, 0);

  v_sug  := greatest(v_min, least(v_max, round(v_reach / 1000.0 * v_cpm)::int));
  v_low  := greatest(v_min, least(v_max, round(v_sug * 0.6)::int));
  v_high := greatest(v_low, least(v_max, round(v_sug * 1.4)::int));

  select count(*)::int,
         percentile_cont(0.25) within group (order by c.budget_cents),
         percentile_cont(0.75) within group (order by c.budget_cents)
    into v_comps, v_p25, v_p75
  from ad_campaigns c
  join events e2 on e2.id = c.event_id
  where c.placement = 'lobby'
    and c.status in ('active', 'completed')
    and e2.peak_viewer_count between v_reach * 0.5 and greatest(v_reach * 2, 1);

  if coalesce(v_comps, 0) >= 5 then
    v_low   := greatest(v_min, least(v_max, round(v_p25)::int));
    v_high  := greatest(v_low, least(v_max, round(v_p75)::int));
    v_basis := v_comps || ' comparable sponsorships';
  end if;

  return query select v_sug, v_low, v_high, v_basis;
end;
$$;

grant execute on function public.suggest_sponsorship_price(uuid) to authenticated;

-- ── host_sponsorship_offers ──────────────────────────────────────────────────
-- Everything the offer card needs in one row: the money, the creative, and the
-- clock. SECURITY DEFINER because RLS hides ad_campaigns from hosts entirely —
-- a host has no business reading the ad table, only the offers aimed at them.
create or replace function public.host_sponsorship_offers()
returns table (
  campaign_id      uuid,
  event_id         uuid,
  event_title      text,
  scheduled_at     timestamptz,
  advertiser_name  text,
  budget_cents     int,
  host_net_cents   int,
  status           text,
  kind             text,
  image_url        text,
  video_path       text,
  thumb_path       text,
  duration_ms      int,
  headline         text,
  body             text,
  click_url        text,
  offer_expires_at timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    c.id, e.id, e.title, e.scheduled_at,
    coalesce(a.name, 'A sponsor'),
    c.budget_cents,
    c.budget_cents - round(c.budget_cents * (1 - cfg.sponsorship_host_share))::int,
    c.status,
    cr.kind, cr.image_url, cr.video_path, cr.thumb_path, cr.duration_ms,
    cr.headline, cr.body, cr.click_url,
    c.offer_expires_at
  from ad_campaigns c
  join events e on e.id = c.event_id
  left join ad_creatives cr on cr.campaign_id = c.id
  left join advertiser_accounts a on a.id = c.advertiser_account_id
  cross join (select sponsorship_host_share from app_config where id = 1) cfg
  where e.host_id = auth.uid()
    and c.placement = 'lobby'
    and c.status in ('pending_host', 'payment_pending')
    and e.removed_at is null
  order by e.scheduled_at asc, c.budget_cents desc;
$$;

grant execute on function public.host_sponsorship_offers() to authenticated;

-- ── host_sponsorship_offer_count ─────────────────────────────────────────────
-- Only offers the host can actually act on. A payment_pending row is waiting on
-- the advertiser's bank, not on them, and badging it would be a lie.
create or replace function public.host_sponsorship_offer_count()
returns int
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select count(*)::int
  from ad_campaigns c
  join events e on e.id = c.event_id
  where e.host_id = auth.uid()
    and c.placement = 'lobby'
    and c.status = 'pending_host'
    and e.removed_at is null
    and (c.offer_expires_at is null or c.offer_expires_at > now());
$$;

grant execute on function public.host_sponsorship_offer_count() to authenticated;

-- ── get_advertiser_performance: + the host's answer and the clock ────────────
drop function public.get_advertiser_performance(uuid, integer, timestamptz); -- return type change

create function public.get_advertiser_performance(
  p_account_id uuid,
  p_limit      integer     default 15,
  p_before     timestamptz default null   -- keyset cursor: created_at of last row
)
returns table (
  campaign_id        uuid,
  name               text,
  headline           text,
  status             text,
  budget_cents       integer,
  spent_cents        integer,
  starts_at          timestamptz,
  ends_at            timestamptz,
  impressions        bigint,
  clicks             bigint,
  review_note        text,
  created_at         timestamptz,
  placement          text,
  event_title        text,
  event_scheduled_at timestamptz,
  host_note          text,
  offer_expires_at   timestamptz,
  last_decline_code  text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    c.id, c.name, cr.headline, c.status, c.budget_cents, c.spent_cents,
    c.starts_at, c.ends_at,
    count(ae.*) filter (where ae.kind = 'impression') as impressions,
    count(ae.*) filter (where ae.kind = 'click')      as clicks,
    c.review_note, c.created_at,
    c.placement, e.title, e.scheduled_at,
    c.host_note, c.offer_expires_at, c.last_decline_code
  from ad_campaigns c
  join advertiser_accounts a
    on a.id = c.advertiser_account_id
   and a.auth_user_id = auth.uid()          -- caller must own the account
  left join ad_creatives cr on cr.campaign_id = c.id
  left join ad_events    ae on ae.campaign_id = c.id
  left join events       e  on e.id = c.event_id
  where c.advertiser_account_id = p_account_id
    and (p_before is null or c.created_at < p_before)
  group by c.id, cr.headline, e.title, e.scheduled_at
  order by c.created_at desc
  limit greatest(1, least(p_limit, 100));
$$;

grant execute on function public.get_advertiser_performance(uuid, integer, timestamptz) to authenticated;
