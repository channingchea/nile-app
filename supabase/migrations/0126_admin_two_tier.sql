-- 0126 — P4 #42 from the 2026-08-16 platform review: a single-tier admin model.
--
-- Any admin could mint or remove any other admin. One phished account
-- therefore owned moderation, ad approval, featured placement AND the admin
-- list itself — enough to remove everyone else and keep the platform. The
-- only guardrails were "not yourself" and "not the last one", neither of which
-- slows down an attacker who adds their own account first.
--
-- Two changes, and they do different jobs:
--
--   1. A super_admin tier. Ordinary admins keep every day-to-day power —
--      moderation, reports, appeals, ad review, featured — and lose exactly
--      one: the ability to change who is an admin. That is the power worth
--      separating, because it is the only one that can be used to keep the
--      others.
--
--   2. Four-eyes on admin changes. A super_admin PROPOSES; a DIFFERENT
--      super_admin approves; only then does anything change. Tier alone
--      doesn't help if the phished account is the super_admin.
--
-- The bootstrap case is real and has to be handled honestly rather than
-- deadlocking: with exactly one super_admin there is nobody who could ever
-- approve, so that person acts alone and the audit row says so
-- (`unilateral = true`). Adding a second super_admin is what switches the
-- four-eyes rule on, which is the right incentive.

-- ── the tier ────────────────────────────────────────────────────────────────
alter table public.admins
  add column if not exists role text not null default 'admin';

alter table public.admins drop constraint if exists admins_role_check;
alter table public.admins add constraint admins_role_check
  check (role in ('admin', 'super_admin'));

comment on column public.admins.role is
  'admin = every operational power. super_admin = that, plus proposing and approving changes to this table.';

-- Both rows today are Channing (channingchea@yahoo.com, channing@c1gnus.com).
-- Promoting both is deliberate: it avoids starting with nobody able to manage
-- admins, and it means the four-eyes path is live from the first third-party
-- admin rather than sitting dormant behind a bootstrap exception.
update public.admins set role = 'super_admin';

create or replace function public.is_super_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from admins
    where user_id = auth.uid() and role = 'super_admin'
  );
$$;

revoke execute on function public.is_super_admin() from public, anon;
grant  execute on function public.is_super_admin() to authenticated;

-- ── the proposal queue ──────────────────────────────────────────────────────
create table if not exists public.admin_change_requests (
  id                 uuid primary key default gen_random_uuid(),
  action             text not null check (action in ('add', 'remove', 'promote', 'demote')),
  target_user_id     uuid references auth.users(id) on delete cascade,
  target_email       text not null,
  reason             text,
  -- Nullable + SET NULL, and an email snapshot beside it: 0122's lesson, that
  -- a NOT NULL actor FK is what stops a person deleting their own account.
  requested_by       uuid references auth.users(id) on delete set null,
  requested_by_email text,
  status             text not null default 'pending'
                       check (status in ('pending', 'applied', 'rejected', 'cancelled', 'expired')),
  decided_by         uuid references auth.users(id) on delete set null,
  decided_by_email   text,
  decided_at         timestamptz,
  unilateral         boolean not null default false,
  created_at         timestamptz not null default now(),
  expires_at         timestamptz not null default now() + interval '7 days'
);

comment on table public.admin_change_requests is
  'Proposed changes to public.admins. Applied only when a second super_admin approves — or immediately, flagged unilateral, when only one super_admin exists.';

-- One open proposal per target at a time: two admins racing to add the same
-- person shouldn''t create two rows that both apply.
create unique index if not exists admin_change_requests_one_open_per_target
  on public.admin_change_requests (target_email)
  where status = 'pending';

alter table public.admin_change_requests enable row level security;
-- No policies on purpose. Everything goes through manage-admins on the service
-- role, exactly like public.admins itself (0032/0055).

-- The audit table only knew 'added' and 'removed'.
alter table public.admin_management_audit
  drop constraint if exists admin_management_audit_action_check;
alter table public.admin_management_audit
  add constraint admin_management_audit_action_check
  check (action in ('added', 'removed', 'promoted', 'demoted', 'proposed', 'rejected'));

-- ── applying a proposal ─────────────────────────────────────────────────────
-- Deliberately one transactional DB function rather than a sequence of calls
-- from the edge function: the guardrail checks and the mutation have to see
-- the same state, or two concurrent approvals can each believe another
-- super_admin remains and between them leave zero.
create or replace function public.admin_apply_change_request(
  p_request_id uuid,
  p_decider    uuid,
  p_unilateral boolean default false
)
returns text
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  r            admin_change_requests%rowtype;
  v_super_cnt  int;
  v_admin_cnt  int;
  v_email      text;
begin
  -- FOR UPDATE: serialize concurrent approvals of the same proposal.
  select * into r from admin_change_requests
   where id = p_request_id and status = 'pending'
   for update;
  if not found then return 'not_pending'; end if;

  if r.expires_at < now() then
    update admin_change_requests set status = 'expired' where id = r.id;
    return 'expired';
  end if;

  -- Four eyes, unless there is genuinely no second pair.
  if not p_unilateral and r.requested_by is not distinct from p_decider then
    return 'same_person';
  end if;

  select count(*) into v_super_cnt from admins where role = 'super_admin';
  select count(*) into v_admin_cnt from admins;
  select email into v_email from auth.users where id = p_decider;

  if r.action = 'add' then
    if exists (select 1 from admins where user_id = r.target_user_id) then
      update admin_change_requests set status = 'applied', decided_by = p_decider,
             decided_by_email = v_email, decided_at = now(), unilateral = p_unilateral
       where id = r.id;
      return 'already_admin';
    end if;
    insert into admins (user_id, role) values (r.target_user_id, 'admin');
    insert into admin_management_audit (actor, action, target_user_id, target_email)
      values (p_decider, 'added', r.target_user_id, r.target_email);

  elsif r.action = 'remove' then
    if v_admin_cnt <= 1 then return 'last_admin'; end if;
    if (select role from admins where user_id = r.target_user_id) = 'super_admin'
       and v_super_cnt <= 1 then
      return 'last_super_admin';
    end if;
    delete from admins where user_id = r.target_user_id;
    insert into admin_management_audit (actor, action, target_user_id, target_email)
      values (p_decider, 'removed', r.target_user_id, r.target_email);

  elsif r.action = 'promote' then
    update admins set role = 'super_admin' where user_id = r.target_user_id;
    insert into admin_management_audit (actor, action, target_user_id, target_email)
      values (p_decider, 'promoted', r.target_user_id, r.target_email);

  elsif r.action = 'demote' then
    if v_super_cnt <= 1
       and (select role from admins where user_id = r.target_user_id) = 'super_admin' then
      return 'last_super_admin';
    end if;
    update admins set role = 'admin' where user_id = r.target_user_id;
    insert into admin_management_audit (actor, action, target_user_id, target_email)
      values (p_decider, 'demoted', r.target_user_id, r.target_email);
  end if;

  update admin_change_requests
     set status = 'applied', decided_by = p_decider, decided_by_email = v_email,
         decided_at = now(), unilateral = p_unilateral
   where id = r.id;
  return 'applied';
end;
$$;

revoke execute on function public.admin_apply_change_request(uuid, uuid, boolean)
  from public, anon, authenticated;
-- service_role only: the edge function is the sole caller, after it has
-- established that the caller is a super_admin.
