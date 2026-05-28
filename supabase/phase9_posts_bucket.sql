-- Phase 9: Storage bucket for post images
-- Run this in the Supabase SQL Editor (only after creating the `posts`
-- bucket via Dashboard → Storage → New bucket, marked Public).

drop policy if exists "posts_storage_public_read"          on storage.objects;
drop policy if exists "posts_storage_authenticated_write"  on storage.objects;
drop policy if exists "posts_storage_authenticated_update" on storage.objects;
drop policy if exists "posts_storage_owner_delete"         on storage.objects;

-- Anyone can read post images.
create policy "posts_storage_public_read"
  on storage.objects for select
  using (bucket_id = 'posts');

-- Any signed-in user can upload a post image.
create policy "posts_storage_authenticated_write"
  on storage.objects for insert
  with check (bucket_id = 'posts' and auth.role() = 'authenticated');

create policy "posts_storage_authenticated_update"
  on storage.objects for update
  using (bucket_id = 'posts' and auth.role() = 'authenticated');

-- Authors can delete their own post images (path prefix = their uid).
create policy "posts_storage_owner_delete"
  on storage.objects for delete
  using (
    bucket_id = 'posts'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
