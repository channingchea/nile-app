-- 0096: Sponsorship offers — schema.
-- (docs/plans/sponsorship-offers-host-approved.md, Phase 1)
--
-- Two changes to the shipped Sponsored Event feature (0079):
--   • price is named by the advertiser, not derived from config tiers, and
--   • Nile screens the creative for policy, then the HOST accepts or declines.
--
-- Consequences carried by this migration:
--   • four new campaign statuses (pending_host, declined, expired,
--     payment_pending) — nothing is charged until the host accepts, so most of
--     the old "refund the sponsor" paths become "nobody owes anybody anything",
--   • the one-sponsor-per-event lock narrows to active/completed, so multiple
--     advertisers can bid on the same event and acceptance is what locks it,
--   • events.peak_viewer_count — a running max written by reconcile-viewers.
--     viewer_count is a live gauge that decays to zero, so nothing in the
--     system currently remembers how many people actually showed up, and
--     suggest_sponsorship_price (0097) has no attendance history without it.

-- ── ad_campaigns: statuses ───────────────────────────────────────────────────
alter table public.ad_campaigns drop constraint ad_campaigns_status_check;
alter table public.ad_campaigns add constraint ad_campaigns_status_check
  check (status in (
    'pending_payment',   -- card not yet saved
    'pending_review',    -- Nile policy screen
    'pending_host',      -- cleared by Nile, waiting on the host
    'payment_pending',   -- host accepted, charge needs advertiser action
    'active', 'paused', 'completed',
    'rejected',          -- Nile policy reject, hard card decline, withdrawn
    'declined',          -- the host said no
    'expired'            -- ran out of clock, or the event died uncharged
  ));

-- ── ad_campaigns: offer columns ──────────────────────────────────────────────
alter table public.ad_campaigns
  add column host_note                text check (char_length(host_note) <= 300),
  add column host_decided_at          timestamptz,
  add column offer_expires_at         timestamptz,
  add column stripe_customer_id       text,
  add column stripe_payment_method_id text,
  add column auto_accepted            boolean not null default false,
  add column last_decline_code        text,
  add column payment_retry_until      timestamptz;

-- The host offer list and the expiry sweep both scan by these.
create index ad_campaigns_lobby_pending_host
  on public.ad_campaigns (event_id)
  where placement = 'lobby' and status = 'pending_host';
create index ad_campaigns_lobby_offer_expiry
  on public.ad_campaigns (offer_expires_at)
  where placement = 'lobby' and status in ('pending_review', 'pending_host');

-- ── advertiser_accounts: saved card + trust tier ─────────────────────────────
-- trust_tier keeps Nile's policy screen off the 72h critical path: an
-- advertiser with one approved creative goes straight to the host and lands in
-- an admin spot-check list instead of the blocking queue. Demoted by any upheld
-- ad report (moderate-report).
alter table public.advertiser_accounts
  add column stripe_customer_id text,
  add column trust_tier text not null default 'new'
    check (trust_tier in ('new', 'trusted')),
  add column trusted_at timestamptz;

-- ── events: host-side sponsorship controls + attendance history ──────────────
alter table public.events
  add column sponsorship_min_offer_cents int
    check (sponsorship_min_offer_cents is null or sponsorship_min_offer_cents > 0),
  add column sponsorship_auto_accept boolean not null default false,
  add column peak_viewer_count int not null default 0;

-- ── app_config: offer pricing knobs replace the fixed tiers ──────────────────
alter table public.app_config
  add column sponsorship_min_offer_cents int not null default 2500
    check (sponsorship_min_offer_cents > 0),
  add column sponsorship_max_offer_cents int not null default 250000
    check (sponsorship_max_offer_cents > 0),
  add column sponsorship_target_cpm_cents int not null default 1800
    check (sponsorship_target_cpm_cents > 0),
  add column sponsorship_offer_cap int not null default 3
    check (sponsorship_offer_cap > 0);

-- get_sponsorable_events (0079) selects the tier columns; drop it here so the
-- column drop can't leave a function referencing a column that no longer
-- exists. 0097 recreates it with the offer-shaped return type.
drop function if exists public.get_sponsorable_events(text, int);

alter table public.app_config
  drop column sponsorship_price_free_cents,
  drop column sponsorship_price_ticketed_cents;

-- ── One sponsor per event, but only once one is bought ───────────────────────
-- Was: any row in the money pipeline locked the event, so the first advertiser
-- to open checkout blocked every other bid. Offers are competitive now —
-- acceptance is what locks the event, and acceptance auto-declines the rest.
drop index if exists public.ad_campaigns_one_lobby_sponsor;
create unique index ad_campaigns_one_lobby_sponsor
  on public.ad_campaigns (event_id)
  where placement = 'lobby' and status in ('active', 'completed');

-- ── Event death: uncharged offers cost nobody anything ───────────────────────
-- Under 0079 every lobby row in the pipeline held a card authorization, so an
-- event dying meant Stripe work. Now only 'active' campaigns have been charged;
-- everything upstream of acceptance just stops, with no sponsorship_refunds row
-- (the nightly sweep would find nothing to cancel and email a refund that never
-- happened).
create or replace function public.sponsorship_on_event_status()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_reason text;
  v_note   text;
begin
  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    v_reason := 'event_cancelled';
    v_note   := 'Event was cancelled — your payment has been refunded.';
  elsif new.status = 'ended'
        and old.status is distinct from 'ended'
        and new.started_at is null then
    -- The host never went live, so the lobby creative was never shown.
    v_reason := 'event_never_started';
    v_note   := 'The event never started — your payment has been refunded.';
  elsif new.status in ('soundcheck', 'live') and old.status = 'scheduled' then
    -- Doors are open: anything not already accepted is out of time. Nothing was
    -- charged, so there is no refund to enqueue — only offers to close out.
    update ad_campaigns
    set status = 'expired',
        review_note = 'The event started before this offer was accepted. You were not charged.'
    where event_id = new.id
      and placement = 'lobby'
      and status in ('pending_payment', 'pending_review', 'pending_host', 'payment_pending');
  end if;

  if v_reason is not null then
    -- Charged sponsorships: real money, real refund.
    insert into sponsorship_refunds
      (campaign_id, advertiser_account_id, stripe_payment_intent_id, split_status, event_title, reason)
    select c.id, c.advertiser_account_id, c.stripe_payment_intent_id, c.split_status, new.title, v_reason
    from ad_campaigns c
    where c.event_id = new.id
      and c.placement = 'lobby'
      and c.status = 'active';

    update ad_campaigns
    set status = 'rejected', review_note = v_note
    where event_id = new.id
      and placement = 'lobby'
      and status = 'active';

    -- Uncharged offers: closed out, no money moved, no refund email owed.
    update ad_campaigns
    set status = 'expired',
        review_note = case when v_reason = 'event_cancelled'
                           then 'The event was cancelled. You were not charged.'
                           else 'The event never took place. You were not charged.' end
    where event_id = new.id
      and placement = 'lobby'
      and status in ('pending_payment', 'pending_review', 'pending_host', 'payment_pending');
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
$function$;

-- host_sponsorship_earnings (0081) already filters on active/completed, so
-- declined/expired/payment_pending offers can never reach it. Verified, not
-- changed.

-- ── Notification preference for offers ───────────────────────────────────────
-- A real column rather than 0090's map-onto-a-neighbour trick: this is the only
-- notification that is about the host's money and has a deadline, and burying
-- it under "Events" would make it un-findable when someone wants it back on.
alter table public.notification_preferences
  add column sponsorship_offer boolean not null default true;

create or replace function public.notif_enabled(p_uid uuid, p_type notification_type)
returns boolean
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select case p_type
      when 'post_like'                  then post_like
      when 'post_comment'               then post_comment
      when 'follow'                     then follow
      when 'event_starting'             then event_starting
      when 'event_live'                 then event_live
      when 'event_ended'                then event_ended
      when 'event_no_show'              then event_ended
      when 'operator_assigned'          then operator_assigned
      when 'new_message'                then new_message
      when 'message_reaction'           then message_reaction
      when 'replay_ready'               then replay_ready
      when 'tip_received'               then tip_received
      when 'soundcheck_open'            then soundcheck_open
      when 'replay_price_prompt'        then replay_price_prompt
      when 'feedback_resolved'          then feedback_resolved
      when 'sponsorship_offer'          then sponsorship_offer
      when 'sponsorship_offer_expiring' then sponsorship_offer
    end
  from notification_preferences
  where user_id = p_uid;
$function$;

-- ── Attendance history: a running max, written by reconcile-viewers ──────────
-- The livekit fn writes viewer_count on every reconcile pass; it can't express
-- greatest() through PostgREST, so it calls this instead. Service-role only —
-- a client that could call it could inflate a host's apparent reach, which is
-- exactly the number price suggestions are built on.
create or replace function public.set_viewer_count(p_event_id uuid, p_count int)
returns void
language sql
security definer
set search_path to 'public', 'pg_temp'
as $function$
  update events
  set viewer_count = greatest(p_count, 0),
      peak_viewer_count = greatest(coalesce(peak_viewer_count, 0), greatest(p_count, 0))
  where id = p_event_id;
$function$;

revoke execute on function public.set_viewer_count(uuid, int) from public, anon, authenticated;
