-- 0039: Rejection reasons + advertiser withdraw support.
-- 1) ad_campaigns.review_note — optional note an admin writes when rejecting,
--    shown to the advertiser on their dashboard.
-- 2) get_advertiser_performance returns it (single dashboard call).
-- Withdraw (owner hard-delete of pending_review/rejected campaigns) needs no
-- RLS change: it runs in the review-ad-campaign fn with the service role, and
-- children (ad_creatives/ad_targeting/ad_events) cascade on campaign delete.

alter table public.ad_campaigns
  add column review_note text check (char_length(review_note) <= 300);

drop function public.get_advertiser_performance(uuid); -- return type changes

create function public.get_advertiser_performance(p_account_id uuid)
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
  clicks       bigint,
  review_note  text
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
    count(ae.*) filter (where ae.kind = 'click')      as clicks,
    c.review_note
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
