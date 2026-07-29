-- 0077: in-app bug & feature reporting (docs/plans/in-app-bug-reporting.md).
--
-- Signed-in users file a bug or a feature request from Settings (or by shaking
-- the device in beta builds). Each row carries auto-collected diagnostics, an
-- in-app error ring buffer, and up to 3 screenshots in a PRIVATE bucket — this
-- is the one place in the app where user-supplied media is admin-only rather
-- than public, because a bug screenshot can contain DMs or payout figures.
--
-- Triage happens in the advertiser portal (?view=feedback) under is_admin().
-- Resolving a report notifies the reporter in-app.

-- ── Enums ────────────────────────────────────────────────────────────────────

do $$ begin
  create type feedback_kind as enum ('bug', 'feature');
exception when duplicate_object then null; end $$;

do $$ begin
  create type feedback_status as enum
    ('new', 'triaged', 'in_progress', 'resolved', 'wont_fix');
exception when duplicate_object then null; end $$;

-- ── feedback_reports ─────────────────────────────────────────────────────────
-- reporter_id is nullable + ON DELETE SET NULL: a deleted account must not take
-- the bug report with it, the report is still worth acting on.

create table if not exists public.feedback_reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid references auth.users (id) on delete set null,
  kind        feedback_kind not null,
  title       text not null check (char_length(title) between 3 and 120),
  body        text not null check (char_length(body) between 10 and 4000),
  status      feedback_status not null default 'new',
  admin_note  text check (admin_note is null or char_length(admin_note) <= 4000),
  diagnostics jsonb not null default '{}'::jsonb,
  error_log   jsonb not null default '[]'::jsonb,
  -- <uid>/<report_id>/<n>.jpg in the private `feedback` bucket.
  image_paths text[] not null default '{}'::text[]
    check (coalesce(array_length(image_paths, 1), 0) <= 3),
  source      text not null default 'settings'
    check (source in ('settings', 'shake')),
  resolved_at timestamptz,
  resolved_by uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now()
);

create index if not exists feedback_reports_triage_idx
  on public.feedback_reports (status, created_at desc);
create index if not exists feedback_reports_reporter_idx
  on public.feedback_reports (reporter_id, created_at desc);

alter table public.feedback_reports enable row level security;

-- Reporters see their own reports (including the admin note — that IS the
-- reply channel). Admins see and triage everything. Nobody deletes: no delete
-- policy exists, so the retention job below is the only remover.
drop policy if exists "feedback_insert_own" on public.feedback_reports;
create policy "feedback_insert_own" on public.feedback_reports
  for insert to authenticated
  with check (reporter_id = auth.uid());

drop policy if exists "feedback_select_own_or_admin" on public.feedback_reports;
create policy "feedback_select_own_or_admin" on public.feedback_reports
  for select to authenticated
  using (reporter_id = auth.uid() or public.is_admin());

drop policy if exists "feedback_update_admin" on public.feedback_reports;
create policy "feedback_update_admin" on public.feedback_reports
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ── Rate limit ───────────────────────────────────────────────────────────────
-- 5/hour per reporter. SECURITY DEFINER so the count sees every row, not just
-- the caller's RLS view (which happens to be the same here, but relying on that
-- would break the moment the select policy narrows).

create or replace function public.feedback_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.reporter_id is not null and (
    select count(*) from public.feedback_reports
     where reporter_id = new.reporter_id
       and created_at > now() - interval '1 hour'
  ) >= 5 then
    raise exception 'feedback_rate_limited'
      using hint = 'Too many reports in the last hour.';
  end if;
  return new;
end;
$$;

drop trigger if exists feedback_reports_rate_limit on public.feedback_reports;
create trigger feedback_reports_rate_limit
  before insert on public.feedback_reports
  for each row execute function public.feedback_rate_limit();

-- ── Resolution stamp + reporter notification ─────────────────────────────────

create or replace function public.feedback_stamp_resolution()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status is distinct from old.status then
    if new.status in ('resolved', 'wont_fix') then
      new.resolved_at := coalesce(new.resolved_at, now());
      new.resolved_by := coalesce(new.resolved_by, auth.uid());
    else
      new.resolved_at := null;
      new.resolved_by := null;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists feedback_reports_stamp_resolution on public.feedback_reports;
create trigger feedback_reports_stamp_resolution
  before update on public.feedback_reports
  for each row execute function public.feedback_stamp_resolution();

-- One notification per report, so re-opening and re-resolving doesn't spam.
create unique index if not exists notifications_feedback_resolved_uniq
  on notifications (recipient_id, entity_id)
  where type = 'feedback_resolved';

create or replace function public.notify_feedback_resolved()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status is not distinct from old.status
     or new.status not in ('resolved', 'wont_fix')
     or new.reporter_id is null then
    return new;
  end if;

  insert into notifications (recipient_id, actor_id, type, entity_id)
  select new.reporter_id,
         coalesce(new.resolved_by, new.reporter_id),
         'feedback_resolved',
         new.id
   where notif_enabled(new.reporter_id, 'feedback_resolved') is not false
  on conflict (recipient_id, entity_id) where (type = 'feedback_resolved')
    do nothing;

  return new;
end;
$$;

drop trigger if exists feedback_reports_notify_resolved on public.feedback_reports;
create trigger feedback_reports_notify_resolved
  after update of status on public.feedback_reports
  for each row execute function public.notify_feedback_resolved();

-- Trigger functions have no business being reachable over PostgREST; without
-- this they show up in the security advisor as anon/authenticated-callable
-- SECURITY DEFINER functions.
revoke execute on function public.feedback_rate_limit()
  from public, anon, authenticated;
revoke execute on function public.feedback_stamp_resolution()
  from public, anon, authenticated;
revoke execute on function public.notify_feedback_resolved()
  from public, anon, authenticated;

-- ── notif_enabled: teach it the new type ─────────────────────────────────────

create or replace function notif_enabled(p_uid uuid, p_type notification_type)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case p_type
      when 'post_like'           then post_like
      when 'post_comment'        then post_comment
      when 'follow'              then follow
      when 'event_starting'      then event_starting
      when 'event_live'          then event_live
      when 'event_ended'         then event_ended
      when 'operator_assigned'   then operator_assigned
      when 'new_message'         then new_message
      when 'message_reaction'    then message_reaction
      when 'replay_ready'        then replay_ready
      when 'tip_received'        then tip_received
      when 'soundcheck_open'     then soundcheck_open
      when 'replay_price_prompt' then replay_price_prompt
      when 'feedback_resolved'   then feedback_resolved
    end
  from notification_preferences
  where user_id = p_uid;
$$;

-- ── Storage: private `feedback` bucket ───────────────────────────────────────
-- Private, unlike `rapids`/`posts`: screenshots are read by their author and by
-- admins only, through signed URLs.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('feedback', 'feedback', false, 10485760, -- 10 MB
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "feedback_storage_owner_write" on storage.objects;
create policy "feedback_storage_owner_write"
  on storage.objects for insert
  with check (
    bucket_id = 'feedback'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "feedback_storage_read_own_or_admin" on storage.objects;
create policy "feedback_storage_read_own_or_admin"
  on storage.objects for select
  using (
    bucket_id = 'feedback'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin())
  );

drop policy if exists "feedback_storage_owner_delete" on storage.objects;
create policy "feedback_storage_owner_delete"
  on storage.objects for delete
  using (
    bucket_id = 'feedback'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ── Retention: drop screenshots after 90 days, keep the text ─────────────────
-- The written report stays forever (it's the record); only the media ages out,
-- since that's what carries incidental personal data.

create or replace function public.purge_feedback_screenshots(p_days int default 90)
returns integer
language plpgsql
security definer
set search_path = public, storage, pg_temp
as $$
declare
  v_count integer;
begin
  perform set_config('storage.allow_delete_query', 'true', true);

  delete from storage.objects o
   using public.feedback_reports f
   where o.bucket_id = 'feedback'
     and o.name = any (f.image_paths)
     and f.created_at < now() - make_interval(days => p_days);

  with cleared as (
    update public.feedback_reports
       set image_paths = '{}'::text[]
     where created_at < now() - make_interval(days => p_days)
       and coalesce(array_length(image_paths, 1), 0) > 0
    returning id
  )
  select count(*) into v_count from cleared;
  return v_count;
end;
$$;

revoke execute on function public.purge_feedback_screenshots(int)
  from public, anon, authenticated;

select cron.schedule(
  'purge-feedback-screenshots',
  '45 4 * * *', -- daily, offset from the other retention sweeps
  $$select public.purge_feedback_screenshots()$$
);
