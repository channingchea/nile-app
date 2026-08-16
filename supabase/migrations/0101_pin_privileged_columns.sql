-- 0101_pin_privileged_columns.sql
-- P0.2 — stop clients writing columns that only moderation or billing owns.
--
-- Six RLS UPDATE policies are ownership-scoped but NOT column-scoped, so a user
-- who legitimately owns a row can write every column in it. Supabase grants the
-- `authenticated` role table-wide UPDATE, so a column-level REVOKE is
-- ineffective — a BEFORE trigger is the reliable guard. This is the same shape
-- as protect_is_official() (0064).
--
-- What was reachable before this migration:
--   events.removed_at      host PATCHes it to null and un-removes their own
--                          moderated event
--   posts.removed_at       same, for posts
--   profiles.suspended_at  user clears their own suspension; unsuspend_user()
--                          then 409s forever, so the ban can never be lifted
--                          through the admin console
--   messages.*             `messages_update_read_at` is USING (sender_id <>
--                          auth.uid()) with no column restriction — the
--                          recipient can rewrite what the SENDER said
--   ad_campaigns.status    advertiser flips an unpaid campaign to 'active' with
--                          spent_cents = 0 and a 2030 ends_at → free unlimited
--                          feed placement, creative review skipped entirely
--   advertiser_accounts.trust_tier
--                          advertiser self-promotes to 'trusted', which routes
--                          sponsorships straight to pending_host so no admin
--                          ever sees the creative
--
-- Client attempts are silently reverted rather than raising, so ordinary edits
-- (retitling an event, marking a DM read) keep working unchanged.

begin;

-- ── Shared authorization predicate ─────────────────────────────────────────
-- Client roles are blocked. The service role, direct SQL (auth.role() null),
-- and admins are allowed. Matches 0064's definition exactly.
create or replace function public.client_role_blocked()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(auth.role(), '') in ('authenticated', 'anon')
     and not public.is_admin();
$$;

revoke execute on function public.client_role_blocked() from public, anon, authenticated;

-- ── events.removed_at / removed_by ─────────────────────────────────────────
create or replace function public.protect_event_moderation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.client_role_blocked() then
    new.removed_at := old.removed_at;
    new.removed_by := old.removed_by;
  end if;
  return new;
end;
$$;

revoke execute on function public.protect_event_moderation() from public, anon, authenticated;

drop trigger if exists events_protect_moderation on events;
create trigger events_protect_moderation
  before update on events
  for each row
  execute function public.protect_event_moderation();

-- ── posts.removed_at / removed_by ──────────────────────────────────────────
create or replace function public.protect_post_moderation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.client_role_blocked() then
    new.removed_at := old.removed_at;
    new.removed_by := old.removed_by;
  end if;
  return new;
end;
$$;

revoke execute on function public.protect_post_moderation() from public, anon, authenticated;

drop trigger if exists posts_protect_moderation on posts;
create trigger posts_protect_moderation
  before update on posts
  for each row
  execute function public.protect_post_moderation();

-- ── profiles.suspended_at ──────────────────────────────────────────────────
-- is_official is already pinned by protect_is_official() (0064); this covers
-- the moderation column that migration predates.
create or replace function public.protect_profile_suspension()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.client_role_blocked() then
    new.suspended_at := old.suspended_at;
  end if;
  return new;
end;
$$;

revoke execute on function public.protect_profile_suspension() from public, anon, authenticated;

drop trigger if exists profiles_protect_suspension on profiles;
create trigger profiles_protect_suspension
  before update on profiles
  for each row
  execute function public.protect_profile_suspension();

-- ── messages: read_at is the ONLY client-writable column ───────────────────
-- The policy name always said read_at; now the behaviour matches. The app only
-- ever updates read_at (message_service.dart:463) — sends are INSERTs and
-- deletes are DELETEs — so nothing legitimate changes.
create or replace function public.protect_message_content()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.client_role_blocked() then
    new.id              := old.id;
    new.conversation_id := old.conversation_id;
    new.sender_id       := old.sender_id;
    new.content         := old.content;
    new.image_url       := old.image_url;
    new.shared_post_id  := old.shared_post_id;
    new.shared_event_id := old.shared_event_id;
    new.created_at      := old.created_at;
  end if;
  return new;
end;
$$;

revoke execute on function public.protect_message_content() from public, anon, authenticated;

drop trigger if exists messages_protect_content on messages;
create trigger messages_protect_content
  before update on messages
  for each row
  execute function public.protect_message_content();

-- ── ad_campaigns: server-written only ──────────────────────────────────────
-- Campaigns are created by create-ad-payment, transitioned by stripe-webhook
-- and review-ad-campaign, and metered by tally-ad-spend — all service role.
-- Nothing in nile_app or the advertiser portal writes this table directly
-- (grepped both repos), so the client write policies are pure attack surface.
-- This mirrors what 0058 did for tickets.
drop policy if exists "ad_campaigns: insert own" on ad_campaigns;
drop policy if exists "ad_campaigns: update own" on ad_campaigns;

-- ── advertiser_accounts.trust_tier ─────────────────────────────────────────
-- The portal inserts an account at signup and never updates it, but keep the
-- UPDATE policy for future brand-detail edits and pin the one column that
-- decides whether a creative gets reviewed.
create or replace function public.protect_advertiser_trust_tier()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.client_role_blocked() then
    new.trust_tier := old.trust_tier;
  end if;
  return new;
end;
$$;

revoke execute on function public.protect_advertiser_trust_tier() from public, anon, authenticated;

drop trigger if exists advertiser_accounts_protect_trust_tier on advertiser_accounts;
create trigger advertiser_accounts_protect_trust_tier
  before update on advertiser_accounts
  for each row
  execute function public.protect_advertiser_trust_tier();

commit;
