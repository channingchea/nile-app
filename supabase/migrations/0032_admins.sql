-- 0032_admins.sql
-- Phase A-4 Part 3: admin review queue foundation.
--
-- Adds an `admins` table + `is_admin()` helper so the advertiser portal can show
-- an admin-only review view, and grants admins READ access to every campaign,
-- creative, targeting row, and advertiser account (the review queue needs the
-- full picture). Status transitions (approve/reject/pause) do NOT go through
-- RLS — they run in the `review-ad-campaign` Edge Function with the service
-- role, which re-checks is_admin() itself, because approve must also capture
-- the Stripe PaymentIntent (manual capture, decided 2026-07-01).
--
-- Seeding: insert Channing's auth user id after applying (see deploy notes);
-- no hardcoded UUIDs in the migration.

create table admins (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table admins enable row level security;

-- A user may see only their own admin row — enough for the portal to ask
-- "am I an admin?" without exposing the admin list.
create policy "admins: read own row"
  on admins for select to authenticated
  using (user_id = auth.uid());

-- No insert/update/delete policies: admins are managed via SQL / service role.

-- Helper for policies and functions. SECURITY DEFINER so it can read `admins`
-- regardless of the caller's RLS view of that table.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from admins where user_id = auth.uid());
$$;

grant execute on function public.is_admin() to authenticated;

-- Admin read access for the review queue.
create policy "ad_campaigns: admin read"
  on ad_campaigns for select to authenticated
  using (is_admin());

create policy "ad_creatives: admin read"
  on ad_creatives for select to authenticated
  using (is_admin());

create policy "ad_targeting: admin read"
  on ad_targeting for select to authenticated
  using (is_admin());

create policy "advertiser_accounts: admin read"
  on advertiser_accounts for select to authenticated
  using (is_admin());
