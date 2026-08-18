-- P3 follow-up: an admin who has ever taken a moderation action could not
-- delete their own account.
--
-- Ten FKs point at auth.users with no ON DELETE clause (= NO ACTION), so the
-- final `auth.admin.deleteUser` step of delete-account raised a foreign key
-- violation. Every one of these columns is already nullable, so SET NULL is
-- the correct fix — but on the three audit tables it would silently erase who
-- did what. Snapshot the actor's email first, via a trigger so no writer can
-- forget it, then let the FK go NULL.

-- 1. actor_email snapshot on the audit tables.
alter table public.moderation_audit        add column if not exists actor_email text;
alter table public.ad_admin_audit          add column if not exists actor_email text;
alter table public.admin_management_audit  add column if not exists actor_email text;

comment on column public.moderation_audit.actor_email is
  'Denormalized at insert. Survives the actor deleting their account, when actor goes NULL.';

create or replace function public.fill_audit_actor_email()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'auth', 'pg_temp'
as $$
begin
  if new.actor is not null and new.actor_email is null then
    select u.email into new.actor_email from auth.users u where u.id = new.actor;
  end if;
  return new;
end;
$$;

revoke all on function public.fill_audit_actor_email() from public, anon, authenticated;

create trigger trg_moderation_audit_actor_email
  before insert on public.moderation_audit
  for each row execute function public.fill_audit_actor_email();

create trigger trg_ad_admin_audit_actor_email
  before insert on public.ad_admin_audit
  for each row execute function public.fill_audit_actor_email();

create trigger trg_admin_management_audit_actor_email
  before insert on public.admin_management_audit
  for each row execute function public.fill_audit_actor_email();

-- 2. Backfill the rows written before the trigger existed.
update public.moderation_audit a
   set actor_email = u.email
  from auth.users u
 where u.id = a.actor and a.actor_email is null;

update public.ad_admin_audit a
   set actor_email = u.email
  from auth.users u
 where u.id = a.actor and a.actor_email is null;

update public.admin_management_audit a
   set actor_email = u.email
  from auth.users u
 where u.id = a.actor and a.actor_email is null;

-- 3. Re-point every blocking FK to ON DELETE SET NULL.
alter table public.moderation_audit drop constraint moderation_audit_actor_fkey;
alter table public.moderation_audit add constraint moderation_audit_actor_fkey
  foreign key (actor) references auth.users(id) on delete set null;

alter table public.ad_admin_audit drop constraint ad_admin_audit_actor_fkey;
alter table public.ad_admin_audit add constraint ad_admin_audit_actor_fkey
  foreign key (actor) references auth.users(id) on delete set null;

alter table public.admin_management_audit drop constraint admin_management_audit_actor_fkey;
alter table public.admin_management_audit add constraint admin_management_audit_actor_fkey
  foreign key (actor) references auth.users(id) on delete set null;

alter table public.appeals drop constraint appeals_decided_by_fkey;
alter table public.appeals add constraint appeals_decided_by_fkey
  foreign key (decided_by) references auth.users(id) on delete set null;

alter table public.featured_content drop constraint featured_content_created_by_fkey;
alter table public.featured_content add constraint featured_content_created_by_fkey
  foreign key (created_by) references auth.users(id) on delete set null;

alter table public.posts drop constraint posts_removed_by_fkey;
alter table public.posts add constraint posts_removed_by_fkey
  foreign key (removed_by) references auth.users(id) on delete set null;

alter table public.post_comments drop constraint post_comments_removed_by_fkey;
alter table public.post_comments add constraint post_comments_removed_by_fkey
  foreign key (removed_by) references auth.users(id) on delete set null;

alter table public.currents drop constraint currents_removed_by_fkey;
alter table public.currents add constraint currents_removed_by_fkey
  foreign key (removed_by) references auth.users(id) on delete set null;

alter table public.current_comments drop constraint current_comments_removed_by_fkey;
alter table public.current_comments add constraint current_comments_removed_by_fkey
  foreign key (removed_by) references auth.users(id) on delete set null;

alter table public.events drop constraint events_removed_by_fkey;
alter table public.events add constraint events_removed_by_fkey
  foreign key (removed_by) references auth.users(id) on delete set null;
