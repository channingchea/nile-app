-- 0102_storage_owner_scoped_writes.sql
-- P0.3 — scope writes in the posts / events / messages buckets to the owner.
--
-- These three buckets' INSERT and UPDATE policies were `bucket_id = 'x' AND
-- auth.role() = 'authenticated'` — no owner check at all. 0059 and 0062
-- rewrote their SELECT policies and never touched the write side. The
-- currents, feedback, ad-creatives and ad-videos buckets are all owner-scoped
-- already, which is the shape copied here.
--
-- What was reachable before this migration:
--   posts     public bucket, paths are <uid>/<ts>.jpg — any signed-in account
--             could overwrite any other user's photo, and the replacement is
--             served worldwide from Nile's storage domain
--   events    paths are <livekit_room>/cover.jpg and the room slug is public,
--             so any signed-in account could deface any host's cover image
--   messages  private, paths are <uid>/<ts>.jpg — any signed-in account could
--             overwrite or move another user's DM attachment
--
-- Path conventions verified against prod before writing this: posts and
-- messages are 100% <uid>-foldered (13/13 and 2/2); events is 0% because it
-- folders by livekit_room. owner_id is populated on 100% of objects in all
-- three buckets, so it is a safe key for the events bucket.

begin;

-- ── posts: <uid>/<file> ────────────────────────────────────────────────────
drop policy if exists "posts_storage_authenticated_write" on storage.objects;
create policy "posts_storage_owner_write"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'posts'
    and (storage.foldername(name))[1] = (auth.uid())::text
  );

drop policy if exists "posts_storage_authenticated_update" on storage.objects;
create policy "posts_storage_owner_update"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'posts'
    and (storage.foldername(name))[1] = (auth.uid())::text
  )
  with check (
    bucket_id = 'posts'
    and (storage.foldername(name))[1] = (auth.uid())::text
  );

-- ── messages: <uid>/<file> ─────────────────────────────────────────────────
drop policy if exists "messages_storage_authenticated_write" on storage.objects;
create policy "messages_storage_owner_write"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'messages'
    and (storage.foldername(name))[1] = (auth.uid())::text
  );

drop policy if exists "messages_storage_authenticated_update" on storage.objects;
create policy "messages_storage_owner_update"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'messages'
    and (storage.foldername(name))[1] = (auth.uid())::text
  )
  with check (
    bucket_id = 'messages'
    and (storage.foldername(name))[1] = (auth.uid())::text
  );

-- ── events: <livekit_room>/cover.jpg ───────────────────────────────────────
-- Can't key on the uid folder here, and can't require the events row to exist
-- either: create_event_flow.dart uploads the cover BEFORE inserting the row
-- (:545 then :563), and older TestFlight builds do the same — an EXISTS check
-- would break event creation for everyone already on a shipped build.
--
-- INSERT therefore stays open to any authenticated user, which only permits
-- creating a NEW path. That is not the hole: an upsert over an existing object
-- routes through the UPDATE policy, so owner-scoping UPDATE is what actually
-- stops one host defacing another's cover. Squatting a path in advance is not
-- practical because livekit_room is a random UUID.
drop policy if exists "events_storage_authenticated_update" on storage.objects;
create policy "events_storage_owner_update"
  on storage.objects for update to authenticated
  using (bucket_id = 'events' and owner_id = (auth.uid())::text)
  with check (bucket_id = 'events' and owner_id = (auth.uid())::text);

-- The events bucket had no DELETE policy at all, so EventService.deleteEvent's
-- storage.remove() has always failed silently inside its catch — every cover
-- ever uploaded is still orphaned in the bucket. Owner-scoped delete fixes the
-- leak without opening anything up.
drop policy if exists "events_storage_owner_delete" on storage.objects;
create policy "events_storage_owner_delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'events' and owner_id = (auth.uid())::text);

commit;
