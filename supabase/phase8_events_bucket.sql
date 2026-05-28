-- Phase 8: Storage bucket for event cover photos
-- Run this in the Supabase SQL Editor (only after creating the `events`
-- bucket via Dashboard → Storage → New bucket, marked Public).

-- Idempotent: drop policies first so re-runs don't error.
drop policy if exists "events_storage_public_read"           on storage.objects;
drop policy if exists "events_storage_authenticated_write"   on storage.objects;
drop policy if exists "events_storage_authenticated_update"  on storage.objects;

-- Anyone can read event covers.
create policy "events_storage_public_read"
  on storage.objects for select
  using (bucket_id = 'events');

-- Any signed-in user can upload an event cover.
create policy "events_storage_authenticated_write"
  on storage.objects for insert
  with check (bucket_id = 'events' and auth.role() = 'authenticated');

create policy "events_storage_authenticated_update"
  on storage.objects for update
  using (bucket_id = 'events' and auth.role() = 'authenticated');
