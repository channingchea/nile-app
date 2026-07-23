-- 0063_featured_content.sql
-- Editorially-curated "Featured" content for the app's Discover rails and the
-- onboarding follow step. Admins manage rows from the portal via the
-- `manage-featured` Edge Function (service role); the table has NO client
-- write policies — same locked-down posture as `admins` (0032) and the admin
-- audit table (0055). Any authenticated user may read it (the app renders the
-- rails).

create table featured_content (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('event', 'creator')),
  -- events.id when kind = 'event', profiles.id when kind = 'creator'.
  -- Polymorphic, so no single FK; a deleted target just drops out of the
  -- hydrated rail (the manage-featured list / app read skip unresolved ids).
  target_id   uuid not null,
  position    int  not null default 0,
  created_by  uuid references auth.users (id),
  created_at  timestamptz not null default now(),
  unique (kind, target_id)
);

-- Rails render in curated order within each kind.
create index featured_content_kind_position_idx
  on featured_content (kind, position asc, created_at asc);

alter table featured_content enable row level security;

-- Any signed-in user may read the curated list (the app builds the rails).
create policy "featured_content: authenticated read"
  on featured_content for select to authenticated
  using (true);

-- No insert/update/delete policies: clients cannot write. All mutations go
-- through the service-role `manage-featured` Edge Function, which bypasses RLS.
