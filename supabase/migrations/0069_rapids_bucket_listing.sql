-- 0069: Rapids — drop the broad SELECT policies on the rapids / ad-videos
-- buckets. Public buckets serve objects by URL without any storage.objects
-- SELECT policy; a broad policy only re-enables API listing of every object,
-- which 0062 disabled platform-wide (advisor: public_bucket_allows_listing).
-- Playback URLs, uploads (owner-scoped insert policies), owner deletes, and
-- the purge crons (SECURITY DEFINER SQL) are all unaffected.

drop policy if exists "rapids_storage_public_read" on storage.objects;
drop policy if exists "ad-videos: public read" on storage.objects;
