-- 0062: Security hardening fix #8 — stop enumeration of public buckets.
-- Buckets stay public (individual objects still load via /object/public/ URLs,
-- which bypass RLS), but the blanket SELECT policies that let anyone list every
-- file are replaced with scoped ones:
--   avatars/posts   → owner folder only ({uid}/...), keeps upsert working
--   ad-creatives    → the advertiser account that owns the folder
--   events          → authenticated only (paths are {liveKitEventId}/cover.jpg,
--                     not uid-scoped, and upsert re-uploads need row visibility)
-- The messages bucket was handled in 0059 (fully private).

drop policy if exists "Public avatar read" on storage.objects;
create policy "avatars_owner_read" on storage.objects
  for select using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists posts_storage_public_read on storage.objects;
create policy "posts_owner_read" on storage.objects
  for select using (
    bucket_id = 'posts'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "ad-creatives: public read" on storage.objects;
create policy "ad_creatives_owner_read" on storage.objects
  for select using (
    bucket_id = 'ad-creatives'
    and exists (
      select 1 from advertiser_accounts a
      where a.auth_user_id = auth.uid()
        and a.id::text = (storage.foldername(objects.name))[1]
    )
  );

drop policy if exists events_storage_public_read on storage.objects;
create policy "events_authenticated_read" on storage.objects
  for select using (
    bucket_id = 'events'
    and auth.role() = 'authenticated'
  );
