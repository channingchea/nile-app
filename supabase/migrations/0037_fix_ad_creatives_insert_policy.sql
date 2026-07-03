-- 0037: Fix ad-creatives bucket INSERT policy.
-- The prior policy called storage.foldername(a.name) — the advertiser account's
-- display name — instead of the uploaded object's path. The EXISTS was therefore
-- always false, so every portal upload failed with "new row violates row-level
-- security policy". Reference the object path (storage.objects.name) so the first
-- folder segment ({account_id}/...) is matched against an account the user owns.

drop policy if exists "ad-creatives: insert own" on storage.objects;
create policy "ad-creatives: insert own" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'ad-creatives'
  and exists (
    select 1 from advertiser_accounts a
    where a.auth_user_id = auth.uid()
      and (a.id)::text = (storage.foldername(storage.objects.name))[1]
  )
);
