-- 0053_report_moderation.sql
-- Reported-content review — Phase 1: schema & visibility.
--
-- Adds soft-removal / suspension columns, makes removed content invisible
-- app-wide via existing block-aware select policies, gives admins read access
-- to `reports`, adds a permanent moderation audit log, and adds the grouped
-- review-queue RPC the portal will call in Phase 3. No client-facing writes
-- are added here — status transitions happen in the `moderate-report` Edge
-- Function (Phase 2), which re-checks is_admin() with the service role.

-- ════════════════════════════════════════════════════════════════════════════
-- Soft-removal / suspension columns
-- ════════════════════════════════════════════════════════════════════════════

alter table posts add column if not exists removed_at timestamptz;
alter table posts add column if not exists removed_by uuid references auth.users (id);

alter table post_comments add column if not exists removed_at timestamptz;
alter table post_comments add column if not exists removed_by uuid references auth.users (id);

alter table events add column if not exists removed_at timestamptz;
alter table events add column if not exists removed_by uuid references auth.users (id);

alter table profiles add column if not exists suspended_at timestamptz;

-- ════════════════════════════════════════════════════════════════════════════
-- Select policies: removed content vanishes for everyone except admins.
-- Rebuilt on top of the block-aware policies from phase19 (and, for events,
-- the draft-hiding clause added later) — same shape, with the removal guard
-- added as a leading AND.
-- ════════════════════════════════════════════════════════════════════════════

drop policy if exists "posts_select_visible" on posts;
create policy "posts_select_visible" on posts for select
  using (
    (removed_at is null or is_admin())
    and not is_blocked(auth.uid(), user_id)
  );

drop policy if exists "events_select_visible" on events;
create policy "events_select_visible" on events for select
  using (
    (removed_at is null or is_admin())
    and not is_blocked(auth.uid(), host_id)
    and (status <> 'draft'::event_status or host_id = auth.uid())
  );

drop policy if exists "post_comments_select_visible" on post_comments;
create policy "post_comments_select_visible" on post_comments for select
  using (
    (removed_at is null or is_admin())
    and not is_blocked(auth.uid(), user_id)
  );

-- ════════════════════════════════════════════════════════════════════════════
-- reports: admin read access (writes stay function-only — no client
-- update/delete policy, matching the ad-review posture from 0032/0051).
-- ════════════════════════════════════════════════════════════════════════════

drop policy if exists "reports_admin_read" on reports;
create policy "reports_admin_read" on reports for select to authenticated
  using (is_admin());

-- Queue scan: only open/reviewing reports are ever read by get_report_queue.
create index if not exists reports_open_queue_idx
  on reports (status, created_at)
  where status in ('open', 'reviewing');

-- ════════════════════════════════════════════════════════════════════════════
-- moderation_audit — permanent trail for every moderation action.
-- Kept separate from ad_admin_audit (0051), which is campaign-shaped. Written
-- by the moderate-report Edge Function with the service role (fire-and-forget);
-- no client write policy.
-- ════════════════════════════════════════════════════════════════════════════

create table if not exists moderation_audit (
  id          bigint generated always as identity primary key,
  actor       uuid references auth.users (id),
  action      text not null
              check (action in (
                'resolve', 'dismiss', 'remove_content', 'restore_content',
                'suspend_user', 'unsuspend_user'
              )),
  target_type text not null check (target_type in ('user', 'post', 'event', 'comment', 'ad')),
  target_id   uuid not null,
  note        text,
  created_at  timestamptz not null default now()
);

create index if not exists moderation_audit_created_at_idx on moderation_audit (created_at desc);

alter table moderation_audit enable row level security;

drop policy if exists "moderation_audit: admin read" on moderation_audit;
create policy "moderation_audit: admin read" on moderation_audit for select to authenticated
  using (is_admin());

-- ════════════════════════════════════════════════════════════════════════════
-- get_report_queue — grouped review queue for the portal.
-- One row per reported TARGET (not per report row), scoped to targets that
-- still have at least one open/reviewing report — resolving/dismissing every
-- report for a target drops it out of the queue. SECURITY DEFINER with a hard
-- is_admin() check inside (language plpgsql so the check can raise). Keyset
-- paged like the other portal RPCs: cursor = newest report time per target.
-- ════════════════════════════════════════════════════════════════════════════

create or replace function public.get_report_queue(
  p_limit  integer     default 20,
  p_before timestamptz default null
)
returns table (
  target_type      report_target_type,
  target_id        uuid,
  report_count     bigint,
  reasons          report_reason[],
  notes            text[],
  statuses         report_status[],
  newest_report_at timestamptz,
  is_removed       boolean,
  is_suspended     boolean,
  preview          jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not authorized';
  end if;

  return query
  with grouped as (
    select
      r.target_type,
      r.target_id,
      count(*)                                       as report_count,
      array_agg(distinct r.reason)                    as reasons,
      array_remove(array_agg(distinct r.note), null)  as notes,
      array_agg(distinct r.status)                    as statuses,
      max(r.created_at)                               as newest_report_at
    from reports r
    where r.status in ('open', 'reviewing')
    group by r.target_type, r.target_id
  )
  select
    g.target_type,
    g.target_id,
    g.report_count,
    g.reasons,
    g.notes,
    g.statuses,
    g.newest_report_at,
    coalesce(p.removed_at, c.removed_at, ev.removed_at) is not null as is_removed,
    (g.target_type = 'user' and prof.suspended_at is not null)      as is_suspended,
    case g.target_type
      when 'post' then jsonb_build_object(
        'exists', p.id is not null,
        'content', p.content,
        'image_url', p.image_url,
        'image_urls', p.image_urls,
        'author_id', p.user_id,
        'author_username', pu.username
      )
      when 'comment' then jsonb_build_object(
        'exists', c.id is not null,
        'body', c.body,
        'post_id', c.post_id,
        'author_id', c.user_id,
        'author_username', cu.username
      )
      when 'event' then jsonb_build_object(
        'exists', ev.id is not null,
        'title', ev.title,
        'cover_image_url', ev.cover_image_url,
        'status', ev.status,
        'host_id', ev.host_id,
        'host_username', eu.username
      )
      when 'ad' then jsonb_build_object(
        'exists', acamp.id is not null,
        'headline', ac.headline,
        'body', ac.body,
        'image_url', ac.image_url,
        'campaign_name', acamp.name,
        'campaign_status', acamp.status,
        'advertiser_name', aacct.name
      )
      when 'user' then jsonb_build_object(
        'exists', prof.id is not null,
        'username', prof.username,
        'display_name', prof.display_name,
        'avatar_url', prof.avatar_url,
        'bio', prof.bio
      )
    end as preview
  from grouped g
  left join posts           p     on g.target_type = 'post'    and p.id = g.target_id
  left join profiles        pu    on pu.id = p.user_id
  left join post_comments   c     on g.target_type = 'comment' and c.id = g.target_id
  left join profiles        cu    on cu.id = c.user_id
  left join events           ev   on g.target_type = 'event'   and ev.id = g.target_id
  left join profiles        eu    on eu.id = ev.host_id
  left join ad_campaigns    acamp on g.target_type = 'ad'      and acamp.id = g.target_id
  left join ad_creatives    ac    on ac.campaign_id = acamp.id
  left join advertiser_accounts aacct on aacct.id = acamp.advertiser_account_id
  left join profiles        prof  on g.target_type = 'user'    and prof.id = g.target_id
  where (p_before is null or g.newest_report_at < p_before)
  order by g.newest_report_at desc
  limit greatest(1, least(p_limit, 100));
end;
$$;

grant execute on function public.get_report_queue(integer, timestamptz) to authenticated;
