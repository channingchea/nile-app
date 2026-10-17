-- 0130: Studio graphics library (Studio master host, phase 4).
--
-- A host's reusable on-screen graphics — lower thirds, logo/image bugs,
-- banners/tickers and full-screen slates — saved per account and pushed live
-- from the Studio (phase 5). Viewers never read this table: the Studio
-- snapshots a graphic's payload into the LiveKit room metadata when it pushes
-- it, so the library stays owner-only.
--
-- Payload shapes (also validated client-side in StudioGraphic.validate):
--   lower_third  { title (1-60), subtitle? (<=80) }
--   logo         { imagePath, corner: tl|tr|bl|br, size?: s|m|l }
--   banner       { text (1-140), scrolling: bool }
--   slate        { title (1-60), subtitle? (<=120), imagePath?, countdownSeconds? (1-86400) }
-- imagePath is an object path in the 'studio-graphics' bucket under <uid>/.

create type public.studio_graphic_kind as enum ('lower_third', 'logo', 'banner', 'slate');

create or replace function public.studio_graphic_payload_ok(k public.studio_graphic_kind, p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(p) = 'object' and case k
    when 'lower_third' then
      jsonb_typeof(p->'title') = 'string'
      and char_length(p->>'title') between 1 and 60
      and (p->'subtitle' is null or (jsonb_typeof(p->'subtitle') = 'string' and char_length(p->>'subtitle') <= 80))
    when 'logo' then
      jsonb_typeof(p->'imagePath') = 'string'
      and char_length(p->>'imagePath') between 1 and 300
      and p->>'corner' in ('tl', 'tr', 'bl', 'br')
      and (p->'size' is null or p->>'size' in ('s', 'm', 'l'))
    when 'banner' then
      jsonb_typeof(p->'text') = 'string'
      and char_length(p->>'text') between 1 and 140
      and jsonb_typeof(p->'scrolling') = 'boolean'
    when 'slate' then
      jsonb_typeof(p->'title') = 'string'
      and char_length(p->>'title') between 1 and 60
      and (p->'subtitle' is null or (jsonb_typeof(p->'subtitle') = 'string' and char_length(p->>'subtitle') <= 120))
      and (p->'imagePath' is null or (jsonb_typeof(p->'imagePath') = 'string' and char_length(p->>'imagePath') <= 300))
      and (p->'countdownSeconds' is null or (
        jsonb_typeof(p->'countdownSeconds') = 'number'
        and (p->>'countdownSeconds')::numeric between 1 and 86400))
  end
$$;

create table public.studio_graphics (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references public.profiles(id) on delete cascade,
  kind       public.studio_graphic_kind not null,
  name       text not null check (char_length(name) between 1 and 60),
  payload    jsonb not null check (public.studio_graphic_payload_ok(kind, payload)),
  sort       int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index studio_graphics_owner_sort on public.studio_graphics (owner_id, sort, created_at);

create or replace function public.studio_graphics_touch()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end
$$;

create trigger studio_graphics_touch
  before update on public.studio_graphics
  for each row execute function public.studio_graphics_touch();

alter table public.studio_graphics enable row level security;

create policy studio_graphics_owner_all on public.studio_graphics
  for all to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

-- A library is a tool, not a store: 200 graphics is far past any real show.
create or replace function public.studio_graphics_cap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select count(*) from public.studio_graphics where owner_id = new.owner_id) >= 200 then
    raise exception 'Graphics library is full (200 items)' using errcode = 'P0001';
  end if;
  return new;
end
$$;

create trigger studio_graphics_cap
  before insert on public.studio_graphics
  for each row execute function public.studio_graphics_cap();

-- ── Storage bucket ───────────────────────────────────────────────────────────
-- Public read (viewers load pushed logos/slate images by URL); writes scoped to
-- the uploader's own <uid>/ folder; images only, 2 MB each.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('studio-graphics', 'studio-graphics', true, 2097152,
        array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

create policy "studio_graphics_storage_public_read"
  on storage.objects for select using (bucket_id = 'studio-graphics');
create policy "studio_graphics_storage_owner_write"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'studio-graphics'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
create policy "studio_graphics_storage_owner_update"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'studio-graphics'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
create policy "studio_graphics_storage_owner_delete"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'studio-graphics'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
