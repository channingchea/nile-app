-- Ad platform — Phase A-1: serving infrastructure only (no payment path).
-- A campaign is a paid promotion of an existing event or post, injected into the
-- feed the same way follow-graph recs are. Phase A-1 ships serving + logging;
-- the A-2 web portal will populate campaigns via Stripe Checkout later. Targeting
-- (ad_targeting) is deferred to A2 and intentionally not created here.

-- ── Tables ───────────────────────────────────────────────────────────────────

create table public.ad_campaigns (
  id              uuid primary key default gen_random_uuid(),
  advertiser_id   uuid not null references public.profiles(id) on delete cascade,
  name            text not null,
  -- what is being promoted; exactly one of these is set
  event_id        uuid references public.events(id) on delete cascade,
  post_id         uuid references public.posts(id)  on delete cascade,
  -- billing model (A-2 fills these; A-1 only reads status/flight)
  pricing_model   text not null default 'flat' check (pricing_model in ('flat','cpm','cpc')),
  budget_cents    int  not null default 0,
  spent_cents     int  not null default 0,
  -- flight window
  starts_at       timestamptz not null default now(),
  ends_at         timestamptz not null,
  status          text not null default 'pending_payment'
                  check (status in ('pending_payment','pending_review','active','paused','completed','rejected')),
  -- billing linkage (set by the A-2 portal / stripe-webhook)
  stripe_payment_intent_id text,
  created_at      timestamptz not null default now(),
  constraint ad_campaigns_one_target check (num_nonnulls(event_id, post_id) = 1)
);

-- Impression + click log: drives billing, frequency capping, and reporting.
create table public.ad_events (
  id          bigint generated always as identity primary key,
  campaign_id uuid not null references public.ad_campaigns(id) on delete cascade,
  viewer_id   uuid references public.profiles(id) on delete set null,
  kind        text not null check (kind in ('impression','click')),
  created_at  timestamptz not null default now()
);

create index ad_events_campaign_idx on public.ad_events (campaign_id, kind, created_at);
create index ad_events_freq_idx     on public.ad_events (viewer_id, campaign_id, created_at);
-- Serving query: active campaigns currently in flight.
create index ad_campaigns_serving_idx on public.ad_campaigns (starts_at, ends_at)
  where status = 'active';

-- ── RLS ──────────────────────────────────────────────────────────────────────

alter table public.ad_campaigns enable row level security;
alter table public.ad_events    enable row level security;

-- ad_campaigns: an advertiser reads/inserts/updates only their own rows. Serving
-- to viewers happens through get_feed_ads (SECURITY DEFINER), so no public read.
create policy "ad_campaigns: read own"
  on public.ad_campaigns for select using (auth.uid() = advertiser_id);
create policy "ad_campaigns: insert own"
  on public.ad_campaigns for insert with check (auth.uid() = advertiser_id);
create policy "ad_campaigns: update own"
  on public.ad_campaigns for update using (auth.uid() = advertiser_id)
  with check (auth.uid() = advertiser_id);

-- ad_events: insert-only from clients (mirrors the Phase 19 reports policy);
-- no client reads — reporting reads server-side / via SECURITY DEFINER aggregates.
create policy "ad_events: insert own impressions"
  on public.ad_events for insert
  with check (auth.uid() = viewer_id or viewer_id is null);

-- ── Serving RPC ──────────────────────────────────────────────────────────────
-- Returns the campaign ids to inject for the calling viewer, newest-flight
-- first, capped to page_limit. SECURITY DEFINER so it can read across all
-- advertisers' active campaigns without exposing ad_campaigns rows directly.
-- Returns campaign_id + target ids so the client hydrates the existing event/post
-- card payloads (same shape the recommend_* RPCs feed SearchService).

create or replace function public.get_feed_ads(
  page_limit  int default 5,
  freq_cap    int default 3   -- max impressions per campaign per viewer per day
)
returns table (campaign_id uuid, event_id uuid, post_id uuid)
language sql
stable
security definer
set search_path = public
as $$
  select c.id, c.event_id, c.post_id
  from ad_campaigns c
  where c.status = 'active'
    and now() between c.starts_at and c.ends_at
    and c.spent_cents < c.budget_cents
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
    -- don't promote content the viewer can't see / blocked the advertiser
    and not exists (
      select 1 from blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = c.advertiser_id)
         or (b.blocked_id = auth.uid() and b.blocker_id = c.advertiser_id)
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
