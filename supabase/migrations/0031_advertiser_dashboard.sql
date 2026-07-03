-- 0031_advertiser_dashboard.sql
-- Phase A-4 Part 2: self-serve advertiser dashboard support.
--
-- Part 1 (0028) added advertiser_accounts / ad_creatives / ad_targeting and made
-- ad_campaigns.advertiser_account_id the owner column for standalone creative ads
-- (advertiser_id stays null for those). But the RLS on ad_campaigns, the
-- ad-creatives bucket, and the get_boost_performance reporting RPC were all still
-- keyed on advertiser_id = auth.uid() (host boosts only). This migration closes
-- those three gaps so a logged-in advertiser can upload a creative image, read
-- their own standalone campaigns, and see reporting — WITHOUT exposing any other
-- account's data.

-- 1) ad-creatives bucket: allow an advertiser to upload objects they own.
--    Object path convention (portal): "<advertiser_account_id>/<uuid>.<ext>", so
--    the first path segment identifies the owning account. Insert is allowed only
--    when that segment is an account the caller owns. Public read already exists.
create policy "ad-creatives: insert own"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'ad-creatives'
    and exists (
      select 1 from public.advertiser_accounts a
      where a.auth_user_id = auth.uid()
        and a.id::text = (storage.foldername(name))[1]
    )
  );

-- 2) ad_campaigns: let advertisers READ their own standalone campaigns (owned via
--    advertiser_account_id). Host-boost read (advertiser_id = auth.uid()) is
--    unchanged and still covered by its own policy. No standalone INSERT/UPDATE
--    policy: those rows are created service-side by create-ad-payment and only
--    ever transitioned by the webhook / admin (service role bypasses RLS).
create policy "ad_campaigns: read own advertiser account"
  on ad_campaigns for select to authenticated
  using (
    exists (
      select 1 from advertiser_accounts a
      where a.id = ad_campaigns.advertiser_account_id
        and a.auth_user_id = auth.uid()
    )
  );

-- 3) Reporting RPC for advertiser-account campaigns (standalone ads). Mirrors
--    get_boost_performance but scopes by advertiser_account ownership and returns
--    the creative headline so the dashboard can label rows. SECURITY DEFINER so it
--    can aggregate ad_events (insert-only to clients) without exposing the table.
create or replace function public.get_advertiser_performance(p_account_id uuid)
returns table (
  campaign_id  uuid,
  name         text,
  headline     text,
  status       text,
  budget_cents integer,
  spent_cents  integer,
  starts_at    timestamptz,
  ends_at      timestamptz,
  impressions  bigint,
  clicks       bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    c.id, c.name, cr.headline, c.status, c.budget_cents, c.spent_cents,
    c.starts_at, c.ends_at,
    count(ae.*) filter (where ae.kind = 'impression') as impressions,
    count(ae.*) filter (where ae.kind = 'click')      as clicks
  from ad_campaigns c
  join advertiser_accounts a
    on a.id = c.advertiser_account_id
   and a.auth_user_id = auth.uid()          -- caller must own the account
  left join ad_creatives cr on cr.campaign_id = c.id
  left join ad_events    ae on ae.campaign_id = c.id
  where c.advertiser_account_id = p_account_id
  group by c.id, cr.headline
  order by c.created_at desc;
$$;

grant execute on function public.get_advertiser_performance(uuid) to authenticated;
