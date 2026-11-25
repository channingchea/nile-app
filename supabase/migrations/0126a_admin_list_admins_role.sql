-- 0126a — admin_list_admins() gains the role column added in 0126, and loses
-- the grants it never needed. Split from 0126 only because the return type
-- changes, which needs a DROP.
--
-- Ordering puts super_admins first: the portal's Admins list is read to answer
-- "who can change this list", and that answer should be at the top.

drop function public.admin_list_admins();

create function public.admin_list_admins()
returns table(user_id uuid, email text, created_at timestamptz, role text)
language sql
stable
security definer
set search_path to 'public', 'auth', 'pg_temp'
as $function$
  select a.user_id, u.email::text, a.created_at, a.role
  from admins a
  join auth.users u on u.id = a.user_id
  order by (a.role = 'super_admin') desc, a.created_at asc;
$function$;

-- Only manage-admins calls this, on the service role.
revoke execute on function public.admin_list_admins() from public, anon, authenticated;
