-- Phase 14 — Stripe Connect host payouts.
-- Run once in the Supabase SQL editor.

-- Connected-account id for hosts who have begun Stripe Connect onboarding.
-- Null until the host taps "Set up payouts". Live charges_enabled /
-- payouts_enabled status is read from Stripe, not stored here.
alter table public.profiles
  add column if not exists stripe_account_id text;

-- The stripe-connect Edge Function writes this column via the service role,
-- so no extra RLS policy is needed (service role bypasses RLS). Clients only
-- ever read their own profile row, which already includes the new column
-- under the existing "select any profile" policy.
