-- 0120_age_assurance_signals.sql
-- P4 phase 1 — record the age category the App Store (or Play) vouches for,
-- not just the birthday the user typed.
--
-- Texas SB 2420, and now Utah and Louisiana, require the app to obtain the
-- store-held age category. That signal has no birthdate attached — it is a
-- bracket plus a statement of how it was established (self-declared, set by a
-- guardian, or confirmed against ID or a payment method). So the table that
-- until now assumed a birthdate has to hold both shapes, and say which one it
-- has.

alter table public.user_age_verification
  alter column birthdate drop not null;

alter table public.user_age_verification
  add column if not exists method text not null default 'self_declared_birthdate',
  add column if not exists age_lower_bound int,
  add column if not exists age_upper_bound int,
  add column if not exists declaration text,
  add column if not exists parental_communication_limits boolean not null default false;

comment on column public.user_age_verification.method is
  'How we know: self_declared_birthdate (the user typed it), app_store (Declared Age Range), or play (Play Age Signals).';
comment on column public.user_age_verification.declaration is
  'For store signals only: selfDeclared, guardianDeclared, or confirmed. A regulator will ask which of these we had.';

alter table public.user_age_verification
  drop constraint if exists user_age_verification_has_a_signal;
alter table public.user_age_verification
  add constraint user_age_verification_has_a_signal
  check (birthdate is not null or age_lower_bound is not null);

alter table public.user_age_verification
  drop constraint if exists user_age_verification_method_check;
alter table public.user_age_verification
  add constraint user_age_verification_method_check
  check (method in ('self_declared_birthdate', 'app_store', 'play'));

-- ── The store-signal write path ──────────────────────────────────────────
-- Sibling of record_compliance_consent (0117), same posture: the only way in,
-- re-checks the age server-side, and accepts the Terms in the same call so the
-- assured route is still one action for the user.
--
-- A store signal REPLACES an earlier typed birthday — it is strictly better
-- evidence — but a typed birthday never overwrites a store signal. That is
-- what the method check in the update clause is for.
create or replace function public.record_assured_age(
  p_lower_bound int,
  p_upper_bound int,
  p_declaration text,
  p_source text,
  p_communication_limits boolean,
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
  if p_source not in ('app_store', 'play') then
    raise exception 'Unknown age-signal source' using errcode = '22023';
  end if;
  -- A null lower bound is the store saying "under 13". Not an error, but not
  -- an account either.
  if p_lower_bound is null or p_lower_bound < 13 then
    raise exception 'You must be at least 13 years old to use Nile'
      using errcode = '22023';
  end if;

  insert into public.user_age_verification (
    user_id, birthdate, method, age_lower_bound, age_upper_bound,
    declaration, parental_communication_limits
  )
  values (
    v_uid, null, p_source, p_lower_bound, p_upper_bound,
    nullif(trim(coalesce(p_declaration, '')), ''), coalesce(p_communication_limits, false)
  )
  on conflict (user_id) do update
    set method = excluded.method,
        age_lower_bound = excluded.age_lower_bound,
        age_upper_bound = excluded.age_upper_bound,
        declaration = excluded.declaration,
        parental_communication_limits = excluded.parental_communication_limits,
        verified_at = now()
    where public.user_age_verification.method = 'self_declared_birthdate'
       or public.user_age_verification.age_lower_bound is distinct from excluded.age_lower_bound
       or public.user_age_verification.parental_communication_limits
          is distinct from excluded.parental_communication_limits;

  perform set_config('nile.consent_write', 'on', true);
  update public.profiles
     set terms_accepted_at = now(),
         terms_version = coalesce(nullif(trim(p_terms_version), ''), 'unversioned')
   where id = v_uid;
  perform set_config('nile.consent_write', 'off', true);
end;
$$;

-- `public` must be named: CREATE FUNCTION grants EXECUTE to PUBLIC.
revoke execute on function public.record_assured_age(int, int, text, text, boolean, text)
  from public, anon, authenticated;
grant execute on function public.record_assured_age(int, int, text, text, boolean, text)
  to authenticated;
