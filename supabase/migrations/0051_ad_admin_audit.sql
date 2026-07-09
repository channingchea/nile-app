-- 0051_ad_admin_audit.sql
-- Ad platform hardening Part 1b: permanent audit trail for admin review actions.
--
-- Every approve/reject/pause/resume (admin) and withdraw (owner) leaves a row
-- here. The row is written by the `review-ad-campaign` Edge Function with the
-- service role (fire-and-forget: an insert failure logs but never fails the
-- action). No client write policy — same posture as `admins` (0032).
--
-- campaign_id has NO foreign key on purpose: a withdrawn campaign is deleted,
-- and the audit row must survive it. `campaign_name` snapshots the name at
-- action time so the log is still readable after the campaign is gone.

create table ad_admin_audit (
  id            bigint generated always as identity primary key,
  campaign_id   uuid,                         -- no FK: audit outlives the campaign
  campaign_name text,                         -- snapshot, readable post-deletion
  actor         uuid references auth.users (id),
  action        text not null
                check (action in ('approve', 'reject', 'pause', 'resume', 'withdraw')),
  note          text,
  created_at    timestamptz not null default now()
);

create index ad_admin_audit_created_at_idx on ad_admin_audit (created_at desc);

alter table ad_admin_audit enable row level security;

-- Admins may read the log (e.g. in Supabase Studio via an authenticated view).
-- Writes only ever happen through the service role in the Edge Function.
create policy "ad_admin_audit: admin read"
  on ad_admin_audit for select to authenticated
  using (is_admin());
