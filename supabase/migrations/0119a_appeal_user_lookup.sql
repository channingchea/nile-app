-- 0119a_appeal_user_lookup.sql
-- Companion to 0119. submit-appeal runs unauthenticated, so it has an email
-- address and nothing else; this is how it attaches the appeal to an account
-- for the admin queue.
--
-- It is an email → user-id oracle, so it is granted to service_role ONLY.
-- Nothing reachable with an anon or user JWT can call it.

create or replace function public.appeal_user_id_for_email(p_email text)
returns uuid
language sql
security definer
set search_path = pg_catalog, public, auth
as $$
  select id from auth.users where lower(email) = lower(trim(p_email)) limit 1;
$$;

revoke execute on function public.appeal_user_id_for_email(text)
  from public, anon, authenticated;
grant execute on function public.appeal_user_id_for_email(text) to service_role;
