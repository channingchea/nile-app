-- 0043 — 2FA backup recovery codes.
-- Supabase MFA (TOTP) has no native backup-code mechanism, so we store our own.
-- One row per generated code, holding only a hash (never the plaintext). Codes
-- are shown to the user exactly once at generation time; the plaintext never
-- touches this table. The `mfa-recovery` edge function (service role) generates,
-- consumes (verifies + marks used), and reports status. Clients may only READ
-- their own rows' *status* (used_at / created_at) to show remaining counts —
-- they can never read a hash or write these rows.

create table if not exists public.mfa_recovery_codes (
  id         uuid        primary key default gen_random_uuid(),
  user_id    uuid        not null references auth.users (id) on delete cascade,
  code_hash  text        not null,
  used_at    timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists mfa_recovery_codes_user_idx
  on public.mfa_recovery_codes (user_id);

alter table public.mfa_recovery_codes enable row level security;

-- Owners may read their own rows (used to show remaining/used counts in
-- Settings). `code_hash` is a keyed HMAC-SHA-256 digest of a high-entropy code,
-- so exposing the row's status is safe; the hash is not reversible without the
-- server secret. All writes go through the service role in
-- the edge function — there are deliberately NO insert/update/delete policies,
-- so RLS denies every client mutation.
drop policy if exists mfa_recovery_codes_select_own on public.mfa_recovery_codes;
create policy mfa_recovery_codes_select_own on public.mfa_recovery_codes
  for select using (user_id = auth.uid());
