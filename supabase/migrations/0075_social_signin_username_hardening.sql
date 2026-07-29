-- 0075: Social sign-in username hardening (Phase 2 of social sign-in plan)
--
-- Fixes two live signup bugs and prepares for OAuth users who arrive with no
-- username:
--   1. handle_new_user's old fallback (split_part(email, '@', 1)) could emit
--      usernames violating the app's ^[a-z0-9_]+$ rule, and on a uniqueness
--      collision the raise rolled back the entire auth.users insert (opaque 500).
--   2. No marker existed for "username was auto-generated" — OAuth users need
--      to be routed through a claim screen.

-- 1. Provisional flag ---------------------------------------------------------

alter table public.profiles
  add column username_is_provisional boolean not null default false;

-- 2. Username generator -------------------------------------------------------
-- Sanitizes a seed into the app's username alphabet, then appends a random
-- 4-digit suffix, retrying until unique (case-insensitive).

create or replace function public.gen_username(seed text)
returns text
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $$
declare
  base text;
  candidate text;
begin
  base := lower(coalesce(seed, ''));
  base := regexp_replace(base, '[^a-z0-9_]', '', 'g');
  -- Base capped at 16 so base + 4-digit suffix fits the app's 20-char max.
  base := left(base, 16);
  if base = '' then
    base := 'nile';
  elsif char_length(base) < 3 then
    base := rpad(base, 3, '0');
  end if;

  loop
    candidate := base || lpad(floor(random() * 10000)::int::text, 4, '0');
    exit when not exists (
      select 1 from public.profiles where lower(username) = candidate
    );
  end loop;

  return candidate;
end;
$$;

-- Internal-only: called by the handle_new_user trigger, never from clients.
revoke execute on function public.gen_username(text) from public, anon, authenticated;

-- 3. handle_new_user rewrite --------------------------------------------------
-- Explicit username from the signup form is used as-is; otherwise (OAuth, or
-- any signup without metadata) a unique provisional username is generated.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $$
declare
  meta_username text := nullif(trim(NEW.raw_user_meta_data->>'username'), '');
  v_username text;
  v_provisional boolean := false;
begin
  if meta_username is not null then
    v_username := meta_username;
  else
    v_username := public.gen_username(coalesce(
      nullif(NEW.raw_user_meta_data->>'preferred_username', ''),
      nullif(NEW.raw_user_meta_data->>'name', ''),
      nullif(NEW.raw_user_meta_data->>'full_name', ''),
      split_part(coalesce(NEW.email, ''), '@', 1)
    ));
    v_provisional := true;
  end if;

  insert into public.profiles
    (id, username, display_name, avatar_url, username_is_provisional)
  values (
    NEW.id,
    v_username,
    coalesce(
      nullif(NEW.raw_user_meta_data->>'display_name', ''),
      nullif(NEW.raw_user_meta_data->>'full_name', ''),
      nullif(NEW.raw_user_meta_data->>'name', ''),
      nullif(split_part(coalesce(NEW.email, ''), '@', 1), ''),
      v_username
    ),
    NEW.raw_user_meta_data->>'avatar_url',
    v_provisional
  );
  return NEW;
end;
$$;

-- 4. Case-insensitive uniqueness ----------------------------------------------
-- Closes the John/john gap. Verified no existing collisions before applying.

create unique index if not exists profiles_username_lower_key
  on public.profiles (lower(username));
