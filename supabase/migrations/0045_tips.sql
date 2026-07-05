-- Tipping, part 2: tips table, RLS, notification preference, and notif_enabled
-- gating for the 'tip_received' type (enum added in 0044).
--
-- Money flow: tips are collected via a Stripe destination charge in the
-- create-tip-payment edge fn (atomic Connect split — application_fee to the
-- platform, remainder to the host's connected account). Rows here are the
-- ledger: created 'pending' at checkout, flipped to 'paid' by the stripe-webhook
-- on checkout.session.completed. No client writes — the edge fn + webhook use
-- the service role; RLS only grants SELECT to the two parties.

-- ── Table ─────────────────────────────────────────────────────────────────────

create table if not exists tips (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  tipper_id uuid not null references profiles(id) on delete cascade,
  host_id uuid not null references profiles(id) on delete cascade,
  amount_cents int not null check (amount_cents between 100 and 50000),
  fee_cents int not null default 0 check (fee_cents >= 0),
  -- session.id at create time (PaymentIntent is null then); the real PI id is
  -- written on webhook success so a later charge.refunded can match.
  stripe_payment_intent_id text,
  status text not null default 'pending'
    check (status in ('pending', 'paid', 'refunded')),
  created_at timestamptz not null default now()
);

create index if not exists tips_host_paid_idx on tips (host_id) where status = 'paid';
create index if not exists tips_event_idx on tips (event_id);

-- ── RLS ───────────────────────────────────────────────────────────────────────
-- Tipper sees tips they sent; host sees tips they received. All writes go through
-- the edge fn / webhook (service role bypasses RLS), so no insert/update policy.

alter table tips enable row level security;

drop policy if exists tips_select_own on tips;
create policy tips_select_own on tips for select
  using (auth.uid() = tipper_id or auth.uid() = host_id);

-- ── Preference column (fail-open, mirrors phase 18 / 0020) ─────────────────────

alter table notification_preferences
  add column if not exists tip_received boolean not null default true;

-- ── notif_enabled: add 'tip_received' ─────────────────────────────────────────
-- Same fail-open contract: NULL (no row / unlisted type) is treated as enabled.
-- This definition also restores the new_message and message_reaction cases that
-- 0023 dropped from the CASE (they still fired fail-open, but could not be
-- toggled off); listing every type with a preference column makes toggles work.

create or replace function notif_enabled(p_uid uuid, p_type notification_type)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case p_type
      when 'post_like'          then post_like
      when 'post_comment'       then post_comment
      when 'follow'             then follow
      when 'event_starting'     then event_starting
      when 'event_live'         then event_live
      when 'event_ended'        then event_ended
      when 'operator_assigned'  then operator_assigned
      when 'new_message'        then new_message
      when 'message_reaction'   then message_reaction
      when 'replay_ready'       then replay_ready
      when 'tip_received'       then tip_received
    end
  from notification_preferences
  where user_id = p_uid;
$$;
