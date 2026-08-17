-- 0117_compliance_consent_and_age_gate.sql
-- P3 #29 (no EULA/privacy consent in the app) and #30 (no age gate).
--
-- Two records the app has never kept: which version of the Terms a user
-- agreed to, and that they are old enough to be here at all. Apple 1.2 wants
-- the first at signup; COPPA and GDPR Art. 8 want the second.

-- ── 1. Recorded consent ──────────────────────────────────────────────────
alter table public.profiles
  add column if not exists terms_accepted_at timestamptz,
  add column if not exists terms_version text;

comment on column public.profiles.terms_accepted_at is
  'When this user last agreed to the Terms + Privacy Policy. Written only by the signup trigger or record_compliance_consent().';

-- Same shape as profiles_protect_suspension: the columns exist on a
-- world-readable, owner-updatable table, so a raw column UPDATE from the app
-- could otherwise forge a consent record. Only the RPC (which sets the flag
-- below) and the service role may move them.
create or replace function public.protect_profile_consent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.client_role_blocked()
     and coalesce(current_setting('nile.consent_write', true), '') <> 'on' then
    new.terms_accepted_at := old.terms_accepted_at;
    new.terms_version     := old.terms_version;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_protect_consent on public.profiles;
create trigger profiles_protect_consent
  before update on public.profiles
  for each row execute function public.protect_profile_consent();

-- ── 2. Age verification ──────────────────────────────────────────────────
-- Deliberately NOT a column on profiles: profiles is world-readable, and a
-- birthdate is not public information.
create table if not exists public.user_age_verification (
  user_id     uuid primary key references public.profiles(id) on delete cascade,
  birthdate   date not null,
  verified_at timestamptz not null default now()
);

alter table public.user_age_verification enable row level security;

-- Read your own row (the gate needs to know whether to ask). Nothing writes
-- through the API — rows arrive from handle_new_user or the RPC below, both
-- of which check the age first — so there is no INSERT policy, and no UPDATE
-- policy at all: a birthdate is stated once and cannot be edited afterwards.
drop policy if exists user_age_verification_select_own on public.user_age_verification;
create policy user_age_verification_select_own on public.user_age_verification
  for select using (user_id = auth.uid());

-- Supabase's default privileges hand anon and authenticated ALL on every new
-- public table, so this REVOKE is the actual lock; RLS is the second layer.
revoke all on public.user_age_verification from public, anon, authenticated;
grant select on public.user_age_verification to authenticated;

-- ── 3. The one write path ────────────────────────────────────────────────
-- Used by the in-app compliance gate: OAuth signups and every account that
-- existed before this migration have no birthdate on file.
create or replace function public.record_compliance_consent(
  p_birthdate date,
  p_terms_version text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Not signed in' using errcode = '28000';
  end if;
  if p_birthdate is null or p_birthdate > (current_date - interval '13 years') then
    raise exception 'You must be at least 13 years old to use Nile'
      using errcode = '22023';
  end if;

  -- First birthdate wins. A user who mis-typed theirs contacts support; they
  -- cannot quietly re-state it after being told they are too young.
  insert into public.user_age_verification (user_id, birthdate)
  values (v_uid, p_birthdate)
  on conflict (user_id) do nothing;

  perform set_config('nile.consent_write', 'on', true);
  update public.profiles
     set terms_accepted_at = now(),
         terms_version = coalesce(nullif(trim(p_terms_version), ''), 'unversioned')
   where id = v_uid;
  perform set_config('nile.consent_write', 'off', true);
end;
$$;

-- REVOKE ... FROM anon, authenticated alone is a no-op: CREATE FUNCTION grants
-- EXECUTE to PUBLIC. `public` must be named (the lesson from 0093/0085/0094).
revoke execute on function public.record_compliance_consent(date, text)
  from public, anon, authenticated;
grant execute on function public.record_compliance_consent(date, text) to authenticated;

-- ── 4. Signup carries both, so the gate never fires for a fresh email signup ──
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
-- Unchanged from the original definition; do not narrow it here.
set search_path = pg_catalog, public, pg_temp
as $$
declare
  meta_username text := nullif(trim(NEW.raw_user_meta_data->>'username'), '');
  v_username text;
  v_provisional boolean := false;
  v_birthdate date;
  v_terms_version text := nullif(trim(NEW.raw_user_meta_data->>'terms_version'), '');
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

  -- Signup metadata is user-supplied text. A malformed date must not take the
  -- whole signup down with it — it just means no birthdate on file, and the
  -- in-app gate asks for one.
  begin
    v_birthdate := nullif(NEW.raw_user_meta_data->>'birthdate', '')::date;
  exception when others then
    v_birthdate := null;
  end;

  insert into public.profiles
    (id, username, display_name, avatar_url, username_is_provisional,
     terms_accepted_at, terms_version)
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
    v_provisional,
    case when v_terms_version is not null then now() end,
    v_terms_version
  );

  if v_birthdate is not null
     and v_birthdate <= (current_date - interval '13 years') then
    insert into public.user_age_verification (user_id, birthdate)
    values (NEW.id, v_birthdate)
    on conflict (user_id) do nothing;
  end if;

  return NEW;
end;
$$;
