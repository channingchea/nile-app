-- Minor finding #13 (AD_PLATFORM_REVIEW_NOTES.md): abandoned Stripe Checkouts
-- leave ad_campaigns stuck in 'pending_payment' forever, plus their creative/
-- targeting rows and the uploaded image in the ad-creatives bucket.
--
-- Daily cron deletes pending_payment campaigns older than 24h (creative +
-- targeting cascade) and removes their orphaned storage objects. 24h is past
-- Stripe Checkout's max session expiry, so no live checkout can still land.
-- (Numbering note: the plan called this 0036; 0035 was freed up because
-- finding #10 needed no migration — people discovery is filtered client-side.)

create or replace function public.cleanup_abandoned_ad_checkouts()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  with doomed as (
    -- Capture storage object paths BEFORE the cascade deletes ad_creatives.
    -- image_url is a public bucket URL; the object name is everything after
    -- '/ad-creatives/' (portal convention: {account_id}/{uuid}.{ext}).
    select c.id as campaign_id,
           split_part(cr.image_url, '/ad-creatives/', 2) as object_name
    from ad_campaigns c
    left join ad_creatives cr on cr.campaign_id = c.id
    where c.status = 'pending_payment'
      and c.created_at < now() - interval '24 hours'
  ),
  del_objects as (
    delete from storage.objects o
    using doomed d
    where o.bucket_id = 'ad-creatives'
      and d.object_name is not null
      and d.object_name <> ''
      and o.name = d.object_name
    returning o.id
  ),
  del_campaigns as (
    delete from ad_campaigns c
    where c.id in (select campaign_id from doomed)
    returning c.id
  )
  select count(*) into v_count from del_campaigns;
  return v_count;
end;
$$;

comment on function public.cleanup_abandoned_ad_checkouts() is
  'Cron-invoked: deletes pending_payment ad campaigns older than 24h and their orphaned ad-creatives storage objects.';

-- Daily at 04:10 UTC (just after purge-expired-replays; off-peak).
select cron.schedule(
  'cleanup-abandoned-ad-checkouts',
  '10 4 * * *',
  $$ select public.cleanup_abandoned_ad_checkouts(); $$
);
