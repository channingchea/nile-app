-- 0054_report_moderation_rls_perf.sql
-- Follow-up to 0053, prompted by get_advisors (performance) right after applying it.
--
-- 1) "Auth RLS Initialization Plan" WARN on the three policies 0053 rewrote:
--    auth.uid() / is_admin() called bare in a USING clause get re-evaluated per
--    row instead of once per statement. Wrapping them as (select ...) lets the
--    planner cache the value. This is exactly the concern flagged as an open
--    question in the reported-content-review plan ("is_admin() in hot-path
--    select policies adds a per-row stable function call").
-- 2) INFO: unindexed FKs on the three new removed_by columns + the new
--    moderation_audit.actor column. Partial (removed_by is mostly null) /
--    plain indexes, cheap to add now.

drop policy if exists "posts_select_visible" on posts;
create policy "posts_select_visible" on posts for select
  using (
    (removed_at is null or (select is_admin()))
    and not is_blocked((select auth.uid()), user_id)
  );

drop policy if exists "events_select_visible" on events;
create policy "events_select_visible" on events for select
  using (
    (removed_at is null or (select is_admin()))
    and not is_blocked((select auth.uid()), host_id)
    and (status <> 'draft'::event_status or host_id = (select auth.uid()))
  );

drop policy if exists "post_comments_select_visible" on post_comments;
create policy "post_comments_select_visible" on post_comments for select
  using (
    (removed_at is null or (select is_admin()))
    and not is_blocked((select auth.uid()), user_id)
  );

create index if not exists posts_removed_by_idx         on posts (removed_by)         where removed_by is not null;
create index if not exists post_comments_removed_by_idx  on post_comments (removed_by) where removed_by is not null;
create index if not exists events_removed_by_idx         on events (removed_by)        where removed_by is not null;
create index if not exists moderation_audit_actor_idx    on moderation_audit (actor);
