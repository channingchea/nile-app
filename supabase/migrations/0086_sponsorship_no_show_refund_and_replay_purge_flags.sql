-- 0086 — B4 + B10 from the 2026-08-11 event lifecycle review.
--
-- B4  sponsorship_on_event_status handled →cancelled and scheduled→soundcheck/live
--     but never →ended. The reason code 'event_never_started' was defined in the
--     CHECK constraint and written by nothing. tally-ad-spend's zombie sweep used
--     to catch these by looking for events still 'scheduled' 24h past their slot —
--     migration 0084 now flips them to 'ended' within minutes, so that sweep no
--     longer sees them and the sponsor's money had no owner. Gated on
--     started_at IS NULL: an event that actually ran delivered its lobby.
-- B10 purge_expired_replays deleted the storage object and the replays row but
--     left events.replay_published_at / replay_price set, so the event kept
--     advertising — and selling — a replay that no longer exists. publish_replay
--     can't repair it either (it early-returns when already published).
--     Five prod rows were in this state; backfilled at the bottom.

-- ── B4 ───────────────────────────────────────────────────────────────────────

create or replace function public.sponsorship_on_event_status()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
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

  elsif new.status = 'ended'
        and old.status is distinct from 'ended'
        and new.started_at is null then
    -- The host never went live. The lobby creative was never shown, so the
    -- sponsor owes nothing — same treatment as a cancellation, different reason
    -- so the advertiser email reads correctly.
    insert into sponsorship_refunds
      (campaign_id, advertiser_account_id, stripe_payment_intent_id, split_status, event_title, reason)
    select c.id, c.advertiser_account_id, c.stripe_payment_intent_id, c.split_status, new.title, 'event_never_started'
    from ad_campaigns c
    where c.event_id = new.id
      and c.placement = 'lobby'
      and c.status in ('pending_review', 'active');

    update ad_campaigns
    set status = 'rejected',
        review_note = 'The event never started — your payment has been refunded.'
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
$function$;

-- ── B10 ──────────────────────────────────────────────────────────────────────

create or replace function public.purge_expired_replays(p_retention_days integer default 30)
returns integer
language plpgsql
security definer
set search_path to 'public', 'storage', 'pg_temp'
as $function$
declare
  v_count integer;
begin
  perform set_config('storage.allow_delete_query', 'true', true);

  delete from storage.objects o
   using public.replays r
   where o.bucket_id = 'replays'
     and o.name = r.playback_path
     and r.created_at < now() - make_interval(days => p_retention_days);

  with purged as (
    delete from public.replays
     where created_at < now() - make_interval(days => p_retention_days)
    returning id, event_id
  ),
  -- An event with no replay behind it must stop advertising one. Without this
  -- the detail screen keeps offering a paid replay that can never play, and
  -- publish_replay refuses to repair the row because it is already published.
  cleared as (
    update public.events e
       set replay_published_at = null,
           replay_price = null
      from purged p
     where e.id = p.event_id
    returning e.id
  )
  select count(*) into v_count from purged;

  return v_count;
end;
$function$;

-- Backfill the rows already in this state (5 on prod at time of writing).
update public.events e
   set replay_published_at = null,
       replay_price = null
 where e.replay_published_at is not null
   and not exists (select 1 from public.replays r where r.event_id = e.id);
