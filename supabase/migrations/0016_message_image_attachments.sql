-- ── DM image attachments ────────────────────────────────────────────────────
-- Adds an optional image_url to messages and a dedicated public 'messages'
-- storage bucket (mirrors the 'posts' bucket policy pattern). The existing
-- content CHECK (1..1000 chars) still applies, so image-only messages carry a
-- short placeholder body (e.g. 'Photo') set by the client.

alter table public.messages
  add column if not exists image_url text;

-- Storage bucket for message images.
insert into storage.buckets (id, name, public)
values ('messages', 'messages', true)
on conflict (id) do nothing;

-- Public read.
drop policy if exists "messages_storage_public_read" on storage.objects;
create policy "messages_storage_public_read" on storage.objects
  for select using (bucket_id = 'messages');

-- Any authenticated user may upload (path is namespaced by uid client-side).
drop policy if exists "messages_storage_authenticated_write" on storage.objects;
create policy "messages_storage_authenticated_write" on storage.objects
  for insert with check (
    bucket_id = 'messages' and auth.role() = 'authenticated'
  );

drop policy if exists "messages_storage_authenticated_update" on storage.objects;
create policy "messages_storage_authenticated_update" on storage.objects
  for update using (
    bucket_id = 'messages' and auth.role() = 'authenticated'
  );

-- Owner (first path segment = uid) may delete their own uploads.
drop policy if exists "messages_storage_owner_delete" on storage.objects;
create policy "messages_storage_owner_delete" on storage.objects
  for delete using (
    bucket_id = 'messages' and (storage.foldername(name))[1] = (auth.uid())::text
  );
