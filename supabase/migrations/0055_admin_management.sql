-- 0055_admin_management.sql
-- Admin management UI: audit trail + auth.users lookup helpers for the
-- `manage-admins` Edge Function. Admins add/remove admins from the portal;
-- the `admins` table itself stays client-unwritable (same posture as 0032).
--
-- The two helper functions exist because PostgREST does not expose the auth
-- schema: the Edge Function (service role) needs to resolve an email to a
-- user id and to list admin emails. SECURITY DEFINER + service_role-only
-- execute — never callable from the browser.

create table admin_management_audit (
  id             bigint generated always as identity primary key,
  actor          uuid references auth.users (id),
  action         text not null check (action in ('added', 'removed')),
  target_user_id uuid,                       -- no FK: audit outlives the account
  target_email   text,                       -- snapshot, readable post-deletion
  created_at     timestamptz not null default now()
);

create index admin_management_audit_created_at_idx
  on admin_management_audit (created_at desc);

alter table admin_management_audit enable row level security;

-- Admins may read the log; writes only happen via the service role.
create policy "admin_management_audit: admin read"
  on admin_management_audit for select to authenticated
  using (is_admin());

-- Resolve an email (case-insensitive) to an auth user.
create or replace function public.admin_lookup_user_by_email(p_email text)
returns table (id uuid, email text)
language sql
stable
security definer
set search_path = public
as $$
  select u.id, u.email::text
  from auth.users u
  where lower(u.email) = lower(trim(p_email))
  limit 1;
$$;

-- Full admin list with emails for the manage-admins UI.
create or replace function public.admin_list_admins()
returns table (user_id uuid, email text, created_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select a.user_id, u.email::text, a.created_at
  from admins a
  join auth.users u on u.id = a.user_id
  order by a.created_at asc;
$$;

-- Service-role only: these expose auth.users data.
revoke execute on function public.admin_lookup_user_by_email(text) from public, anon, authenticated;
revoke execute on function public.admin_list_admins() from public, anon, authenticated;
grant execute on function public.admin_lookup_user_by_email(text) to service_role;
grant execute on function public.admin_list_admins() to service_role;
