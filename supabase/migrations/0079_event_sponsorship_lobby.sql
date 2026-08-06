-- 0079: Event Sponsorship + Pre-Show Lobby, Phase 1
-- (docs/plans/event-sponsorship-preshow-lobby.md)
--
-- A sponsorship is an ordinary ad_campaign with placement='lobby' targeting an
-- event — it inherits checkout, the review state machine, creatives, ad_events
-- reporting, and admin audit for free. This migration adds:
--   • ad_campaigns.placement ('feed'|'currents'|'lobby') + backfill by
--     creative kind (video → currents),
--   • ad_campaigns.application_fee_cents / split_status — the 70/30 host split
--     frozen per purchase (same pattern as tickets, 0063),
--   • one-sponsor-per-event lock (partial unique index),
--   • events.sponsorship_open — host opt-in per event,
--   • app_config sponsorship pricing knobs (retunable without deploys),
--   • sponsorship_refunds — a small queue the event-death triggers write to;
--     the nightly tally-ad-spend sweep does the actual Stripe work (DB can't),
--   • triggers: event deleted/cancelled → enqueue refund + reject; event
--     reaches soundcheck with the sponsorship still unreviewed → reject +
--     enqueue auth release; event goes live → sponsorship 'completed',
--   • get_sponsorable_events / get_lobby_sponsorship RPCs,
--   • tally_ad_spend: lobby campaigns excluded from daily-burn spend and
--     flight-window auto-complete (the event's lifecycle is the flight).

-- ── ad_campaigns: placement ──────────────────────────────────────────────────
alter table public.ad_campaigns
  add column placement text not null default 'feed'
    check (placement in ('feed', 'currents', 'lobby'));

-- Backfill: video creatives serve in the Currents player today.
update public.ad_campaigns c
set placement = 'currents'
from public.ad_creatives cr
where cr.campaign_id = c.id and cr.kind = 'video';

-- ── ad_campaigns: frozen split (same pattern as tickets) ─────────────────────
alter table public.ad_campaigns
  add column application_fee_cents int,
  add column split_status text
    check (split_status is null or split_status in ('split', 'platform_fallback'));

-- ── One sponsor per event (exclusive) ────────────────────────────────────────
-- First purchase locks the event: any row still in the money pipeline blocks a
-- second. completed/rejected rows release the lock.
create unique index ad_campaigns_one_lobby_sponsor
  on public.ad_campaigns (event_id)
  where placement = 'lobby'
    and status in ('pending_payment', 'pending_review', 'active');

-- ── events: host opt-in ──────────────────────────────────────────────────────
alter table public.events
  add column sponsorship_open boolean not null default false;

-- ── app_config: pricing knobs (launch values are placeholders) ───────────────
alter table public.app_config
  add column sponsorship_price_free_cents int not null default 2500
    check (sponsorship_price_free_cents > 0),
  add column sponsorship_price_ticketed_cents int not null default 5000
    check (sponsorship_price_ticketed_cents > 0),
  add column sponsorship_host_share numeric not null default 0.70
    check (sponsorship_host_share >= 0 and sponsorship_host_share <= 1);

-- ── sponsorship_refunds: Stripe work queue for event-death paths ─────────────
-- Triggers below enqueue; the nightly tally-ad-spend sweep processes (cancel
-- an uncaptured auth, or refund a captured split with reverse_transfer) and
-- notifies the advertiser. No FK to ad_campaigns: the event-DELETE path
-- cascade-deletes the campaign row, and this queue must survive it.
create table public.sponsorship_refunds (
  id                       uuid primary key default gen_random_uuid(),
  campaign_id              uuid not null,
  advertiser_account_id    uuid,
  stripe_payment_intent_id text,
  split_status             text,
  event_title              text,
  reason                   text not null
    check (reason in ('event_deleted', 'event_cancelled', 'not_approved_in_time', 'event_never_started')),
  status                   text not null default 'due'
    check (status in ('due', 'done', 'failed')),
  note                     text,
  created_at               timestamptz not null default now(),
  processed_at             timestamptz
);

alter table public.sponsorship_refunds enable row level security;

create policy "sponsorship_refunds: admin read"
  on public.sponsorship_refunds for select using (is_admin());

-- ── Trigger: event deleted → enqueue refund (campaign row is about to cascade)
create or replace function public.enqueue_sponsorship_refund_on_event_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into sponsorship_refunds
    (campaign_id, advertiser_account_id, stripe_payment_intent_id, split_status, event_title, reason)
  select c.id, c.advertiser_account_id, c.stripe_payment_intent_id, c.split_status, old.title, 'event_deleted'
  from ad_campaigns c
  where c.event_id = old.id
    and c.placement = 'lobby'
    and c.status in ('pending_review', 'active');
  return old;
end;
$$;

create trigger events_sponsorship_refund_on_delete
  before delete on public.events
  for each row execute function public.enqueue_sponsorship_refund_on_event_delete();

-- ── Trigger: event status transitions drive the sponsorship lifecycle ────────
--   → cancelled : reject the sponsorship + enqueue refund/release
--   → soundcheck: still pending_review ⇒ too late to review — reject + enqueue
--                 auth release (an unapproved ad must never reach the lobby)
--   → live      : active sponsorship delivered ⇒ 'completed'
create or replace function public.sponsorship_on_event_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    insert into sponsorship_refunds
      (campaign_id, advertiser_account_id, stripe_payment_intent_id, split_status, event_title, reason)
    select c.id, c.advertiser_account_id, c.stripe_payment_intent_id, c.split_status, new.title, 'event_cancelled'
    from ad_campaigns c
    where c.event_id = new.id
      and c.placement = 'lobby'
      and c.status in ('pending_review', 'active');

    update ad_campaigns
    set status = 'rejected',
        review_note = 'Event was cancelled — your payment has been refunded.'
    where event_id = new.id
      and placement = 'lobby'
      and status in ('pending_review', 'active');

  elsif new.status in ('soundcheck', 'live') and old.status = 'scheduled' then
    insert into sponsorship_refunds
      (campaign_id, advertiser_account_id, stripe_payment_intent_id, split_status, event_title, reason)
    select c.id, c.advertiser_account_id, c.stripe_payment_intent_id, c.split_status, new.title, 'not_approved_in_time'
    from ad_campaigns c
    where c.event_id = new.id
      and c.placement = 'lobby'
      and c.status = 'pending_review';

    update ad_campaigns
    set status = 'rejected',
        review_note = 'The event started before this sponsorship could be reviewed. Your card was not charged.'
    where event_id = new.id
      and placement = 'lobby'
      and status = 'pending_review';
  end if;

  if new.status = 'live' and old.status is distinct from 'live' then
    update ad_campaigns
    set status = 'completed'
    where event_id = new.id
      and placement = 'lobby'
      and status = 'active';
  end if;

  return new;
end;
$$;

create trigger events_sponsorship_on_status
  after update of status on public.events
  for each row execute function public.sponsorship_on_event_status();

-- ── get_sponsorable_events: the portal's event picker ────────────────────────
-- Opted-in, still scheduled, ≥24h out (review window), host payable (Connect
-- account on file — the live charges_enabled check happens server-side at
-- checkout in create-ad-payment), and not already locked by another sponsor.
-- SECURITY DEFINER: needs profiles.stripe_account_id, which RLS hides.
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
  price_cents     int
)
language sql
stable
security definer
set search_path = public
as $$
  select
    e.id, e.title, e.cover_image_url, e.scheduled_at,
    p.username,
    coalesce(p.display_name, p.username),
    p.avatar_url,
    (e.price is not null and e.price > 0),
    case when e.price is not null and e.price > 0
         then cfg.sponsorship_price_ticketed_cents
         else cfg.sponsorship_price_free_cents end
  from events e
  join profiles p on p.id = e.host_id
  cross join (select sponsorship_price_free_cents, sponsorship_price_ticketed_cents
              from app_config where id = 1) cfg
  where e.sponsorship_open
    and e.status = 'scheduled'
    and e.removed_at is null
    and e.scheduled_at >= now() + interval '24 hours'
    and p.stripe_account_id is not null
    and p.suspended_at is null
    and not exists (
      select 1 from ad_campaigns c
      where c.event_id = e.id
        and c.placement = 'lobby'
        and c.status in ('pending_payment', 'pending_review', 'active')
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

-- ── get_lobby_sponsorship: what the Pre-Show screen renders ──────────────────
-- The active (approved, captured) sponsorship for an event, creative included.
-- SECURITY DEFINER: viewers can't read ad_campaigns/ad_creatives under RLS.
create or replace function public.get_lobby_sponsorship(p_event_id uuid)
returns table (
  campaign_id     uuid,
  kind            text,
  image_url       text,
  video_path      text,
  thumb_path      text,
  duration_ms     int,
  headline        text,
  click_url       text,
  advertiser_name text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    c.id, cr.kind, cr.image_url, cr.video_path, cr.thumb_path, cr.duration_ms,
    cr.headline, cr.click_url, a.name
  from ad_campaigns c
  join ad_creatives cr on cr.campaign_id = c.id
  left join advertiser_accounts a on a.id = c.advertiser_account_id
  where c.event_id = p_event_id
    and c.placement = 'lobby'
    and c.status = 'active'
  limit 1;
$$;

grant execute on function public.get_lobby_sponsorship(uuid) to authenticated;

-- ── tally_ad_spend: lobby campaigns are out of the daily-burn world ──────────
-- Their budget is a one-shot purchase (spent at capture, not accrued) and
-- their flight is the event's lifecycle (triggers above complete them), so
-- exclude placement='lobby' from both the spend recompute and the
-- flight-window auto-complete. Body otherwise identical to 0050.
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
    and (
      now() >= ends_at
      or (pricing_model in ('cpm','cpc') and spent_cents >= budget_cents)
    );
  get diagnostics v_completed = row_count;

  return query select v_updated, v_completed;
end;
$$;
