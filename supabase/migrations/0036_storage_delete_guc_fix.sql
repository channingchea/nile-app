-- Supabase's storage.protect_delete trigger now blocks direct deletes from
-- storage.objects unless the transaction-local GUC
-- storage.allow_delete_query = 'true' is set. Fix both cron functions that
-- delete storage objects directly:
--   - cleanup_abandoned_ad_checkouts (0035, minor finding #13)
--   - purge_expired_replays (0024) — had been silently failing at runtime
--     since the guard was introduced.
-- Deleting the storage.objects row makes the file inaccessible via the
-- Storage API (the underlying blob is garbage, same tradeoff 0024 took).

create or replace function public.cleanup_abandoned_ad_checkouts()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  perform set_config('storage.allow_delete_query', 'true', true);

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

create or replace function public.purge_expired_replays(p_retention_days int default 30)
returns integer
language plpgsql
security definer
set search_path = public, storage, pg_temp
as $$
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
    returning id
  )
  select count(*) into v_count from purged;
  return v_count;
end;
$$;
