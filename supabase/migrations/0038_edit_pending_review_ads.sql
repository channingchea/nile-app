-- 0038: Let advertisers edit their standalone ads while still in review.
-- ad_creatives / ad_targeting had read+insert own-account policies only (0028),
-- so portal edits hit RLS. Allow UPDATE, but only while the owning campaign is
-- pending_review — once approved/active the creative is immutable to the client.

create or replace function public.can_edit_pending_ad(p_campaign_id uuid)
returns boolean
language sql stable
set search_path = public
as $$
  select exists (
    select 1 from ad_campaigns c
    join advertiser_accounts a on a.id = c.advertiser_account_id
    where c.id = p_campaign_id
      and a.auth_user_id = auth.uid()
      and c.status = 'pending_review'
  );
$$;

create policy "ad_creatives: update own pending_review"
  on public.ad_creatives for update
  using (can_edit_pending_ad(campaign_id))
  with check (can_edit_pending_ad(campaign_id));

create policy "ad_targeting: update own pending_review"
  on public.ad_targeting for update
  using (can_edit_pending_ad(campaign_id))
  with check (can_edit_pending_ad(campaign_id));
