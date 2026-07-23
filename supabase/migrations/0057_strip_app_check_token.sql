-- 0057: strip the App Check attestation token from user metadata at insert.
--
-- The app sends a short-lived Firebase App Check JWT in signup metadata so
-- the before-user-created hook can verify it. Once verified it has no
-- further use — remove it so it never persists in auth.users.

create or replace function public.strip_app_check_token()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  new.raw_user_meta_data := coalesce(new.raw_user_meta_data, '{}'::jsonb)
    - 'app_check_token';
  return new;
end;
$$;

drop trigger if exists strip_app_check_token on auth.users;
create trigger strip_app_check_token
  before insert on auth.users
  for each row execute function public.strip_app_check_token();
