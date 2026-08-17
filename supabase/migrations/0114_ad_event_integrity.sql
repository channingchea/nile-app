-- 0114 — P2 #20 from the 2026-08-16 platform review: ad events were asserted
-- by the client.
--
-- The policy was `with check (auth.uid() = viewer_id or viewer_id is null)`.
-- Read what that actually permits:
--   • campaign_id is entirely caller-chosen — nothing ties the row to a
--     campaign that was ever served to this caller, or to anyone;
--   • viewer_id may be NULL, so the anon key alone is enough to write;
--   • there is no unique index and no per-window constraint, so the same row
--     can be written a thousand times.
-- A competitor scripts clicks against a rival campaign. A host inflates their
-- own boost's CTR. Under flat pricing it doesn't drain a budget, but it
-- poisons every number get_advertiser_performance shows — which is the only
-- evidence an advertiser has when deciding whether to renew.
--
-- Fix: clients lose INSERT entirely and go through log_ad_event, which decides
-- for itself whether the caller could plausibly have seen this ad.

-- ── dedupe what's already there, then make it impossible ────────────────────
-- 9 duplicate groups exist today (all from testing). The index below can't be
-- created until they're gone.
delete from public.ad_events a
 using public.ad_events b
 where a.id > b.id
   and a.campaign_id = b.campaign_id
   and a.viewer_id is not distinct from b.viewer_id
   and a.kind = b.kind
   and date_trunc('hour', a.created_at, 'UTC')
     = date_trunc('hour', b.created_at, 'UTC');

-- Three-argument date_trunc is IMMUTABLE (the two-argument timestamptz form is
-- only STABLE, because it reads the session TimeZone) — which is what makes it
-- legal in a generated column.
alter table public.ad_events
  add column if not exists hour_bucket timestamptz
  generated always as (date_trunc('hour', created_at, 'UTC')) stored;

-- One event per campaign, per viewer, per kind, per hour. This is the backstop
-- under the checks in log_ad_event, and it also quietly fixes a real UI bug
-- class: a card that re-enters the viewport re-fired an impression.
create unique index if not exists ad_events_dedupe_idx
  on public.ad_events (campaign_id, viewer_id, kind, hour_bucket)
  where viewer_id is not null;

-- ── the only way in ─────────────────────────────────────────────────────────
-- Returns a status rather than raising, because the caller is a fire-and-forget
-- logger on a feed — an exception there is a crash on a scroll.
--
--   'logged'        wrote it
--   'duplicate'     already logged this hour
--   'capped'        viewer is at the daily frequency cap for this campaign
--   'not_servable'  campaign isn't live, is out of flight, or is out of budget
--   'no_impression' a click with no matching impression in the last 24h
--   'anonymous'     signed-out caller
--   'bad_kind'      unknown event kind
--
-- Signed-out viewers no longer generate events. An event with no viewer_id
-- cannot be frequency-capped, deduped, or attributed, and accepting one is
-- exactly what made the anon key sufficient to forge numbers. The honest
-- smaller count beats the forgeable larger one.
create or replace function public.log_ad_event(
  p_campaign_id uuid,
  p_kind        text
)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_uid  uuid := (select auth.uid());
  -- Same default get_feed_ads / get_currents_ads serve with. The client never
  -- overrides it, so this is the effective cap in both places.
  v_cap  constant integer := 3;
begin
  if p_kind not in ('impression', 'click', 'not_interested') then
    return 'bad_kind';
  end if;
  if v_uid is null then
    return 'anonymous';
  end if;

  if p_kind = 'not_interested' then
    -- A viewer preference, not a billable event. It has to keep working on a
    -- campaign that has since paused or run out of budget, or "don't show me
    -- this again" silently fails on the ads most worth suppressing.
    perform 1 from ad_campaigns where id = p_campaign_id;
    if not found then return 'not_servable'; end if;
  else
    -- The same three predicates get_feed_ads serves on. Deliberately not the
    -- whole serving clause: topic targeting and block lists can change between
    -- the render and the tap, and punishing the viewer for that would drop
    -- honest events. These three are the ones that decide whether the campaign
    -- can bill at all.
    perform 1 from ad_campaigns c
     where c.id = p_campaign_id
       and c.status = 'active'
       and now() between c.starts_at and c.ends_at
       and c.spent_cents < c.budget_cents;
    if not found then return 'not_servable'; end if;
  end if;

  if p_kind = 'impression' then
    if (
      select count(*) from ad_events
       where campaign_id = p_campaign_id
         and viewer_id = v_uid
         and kind = 'impression'
         and created_at >= date_trunc('day', now())
    ) >= v_cap then
      return 'capped';
    end if;
  elsif p_kind = 'click' then
    -- You cannot click an ad you were never shown. This is the single cheapest
    -- check against scripted clicks on a rival's campaign: forging a click now
    -- costs a forged impression first, and impressions are capped at 3/day.
    if not exists (
      select 1 from ad_events
       where campaign_id = p_campaign_id
         and viewer_id = v_uid
         and kind = 'impression'
         and created_at >= now() - interval '24 hours'
    ) then
      return 'no_impression';
    end if;
  end if;

  insert into ad_events (campaign_id, viewer_id, kind)
  values (p_campaign_id, v_uid, p_kind)
  on conflict do nothing;

  if not found then return 'duplicate'; end if;
  return 'logged';
end;
$function$;

revoke execute on function public.log_ad_event(uuid, text) from public, anon;
grant  execute on function public.log_ad_event(uuid, text) to authenticated;

-- ── close the front door ────────────────────────────────────────────────────
-- Dropping the policy alone would not be enough: with the table grant still in
-- place a future policy could reopen it by accident. Revoke the privilege too.
drop policy if exists "ad_events: insert own impressions" on public.ad_events;
revoke insert on public.ad_events from public, anon, authenticated;
