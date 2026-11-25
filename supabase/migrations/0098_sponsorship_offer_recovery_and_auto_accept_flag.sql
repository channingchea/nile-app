-- 0098: Sponsorship offers — payment recovery link + the auto-accept flag.
--
-- Two gaps found while building 0095-0097's clients:
--
-- 1. A recoverable card decline puts an offer in 'payment_pending' with six
--    hours to fix it, and nothing anywhere held the URL that fixes it. Stripe
--    has no hosted page for a bare PaymentIntent stuck in requires_action —
--    card 3DS resolves through Stripe.js, which the portal doesn't load. So the
--    recovery path is a fresh Checkout Session in payment mode: Stripe-hosted,
--    handles the challenge itself, and completes through the webhook we already
--    have. This column is where that URL lives so both the email and the
--    dashboard row can point at the same one.
--
-- 2. ad_campaigns.auto_accepted was written and never read. A host with
--    auto-accept on has no way to tell an offer they approved from one approved
--    for them, and the app can't read ad_campaigns under RLS. It rides along on
--    get_lobby_sponsorship, which the event screen already calls.

alter table public.ad_campaigns add column payment_recovery_url text;

-- ── get_lobby_sponsorship: + auto_accepted ───────────────────────────────────
drop function public.get_lobby_sponsorship(uuid); -- return type change

create function public.get_lobby_sponsorship(p_event_id uuid)
returns table (
  campaign_id     uuid,
  kind            text,
  image_url       text,
  video_path      text,
  thumb_path      text,
  duration_ms     int,
  headline        text,
  click_url       text,
  advertiser_name text,
  auto_accepted   boolean
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    c.id, cr.kind, cr.image_url, cr.video_path, cr.thumb_path, cr.duration_ms,
    cr.headline, cr.click_url, a.name, c.auto_accepted
  from ad_campaigns c
  join ad_creatives cr on cr.campaign_id = c.id
  left join advertiser_accounts a on a.id = c.advertiser_account_id
  where c.event_id = p_event_id
    and c.placement = 'lobby'
    and c.status in ('active', 'completed')
  limit 1;
$$;

grant execute on function public.get_lobby_sponsorship(uuid) to authenticated;

-- ── get_advertiser_performance: + the recovery link ──────────────────────────
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
    count(ae.*) filter (where ae.kind = 'impression') as impressions,
    count(ae.*) filter (where ae.kind = 'click')      as clicks,
    c.review_note, c.created_at,
    c.placement, e.title, e.scheduled_at,
    c.host_note, c.offer_expires_at, c.last_decline_code, c.payment_recovery_url
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
