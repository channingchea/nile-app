-- 0130_admin_overview.sql
-- One read for the /admin overview home.
--
-- The staff portal's landing page shows five queue counts plus four groups of
-- platform stats. Doing that from the client would be ~20 round trips against
-- tables whose RLS is admin-only anyway, so it's a single security-definer RPC
-- that refuses anyone without an `admins` row and returns one jsonb payload.
-- The sidebar badges on every /admin page come from the same call.
--
-- No rollup table and no cron: everything here is a count or a sum over an
-- indexed timestamp. If these get slow the fix is a nightly rollup, not an
-- index on a full-table aggregate.

create or replace function public.get_admin_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_now    timestamptz := now();
  v_7d     timestamptz := now() - interval '7 days';
  v_30d    timestamptz := now() - interval '30 days';
  v_median numeric;
begin
  if not public.is_admin() then
    raise exception 'Admins only' using errcode = '42501';
  end if;

  -- Median hours from the first report on a target to the first moderation
  -- action taken on it. Joined on (target_type, target_id) because reports and
  -- moderation_audit share no key — the audit row is written by moderate-report
  -- against the target, not against the report.
  select percentile_cont(0.5) within group (
           order by extract(epoch from (a.created_at - r.first_at)) / 3600.0)
    into v_median
    from public.moderation_audit a
    join lateral (
      select min(created_at) as first_at
        from public.reports
       where target_type::text = a.target_type
         and target_id = a.target_id
         and created_at <= a.created_at
    ) r on r.first_at is not null
   where a.created_at >= v_30d;

  return jsonb_build_object(
    'generated_at', v_now,

    -- Queue counts. These are also the sidebar badges, so each one must match
    -- exactly what its page shows on open — a badge that disagrees with the
    -- list under it is worse than no badge.
    'queues', jsonb_build_object(
      'pending_review', (select count(*) from ad_campaigns where status = 'pending_review'),
      'spotcheck',      (select count(*) from ad_campaigns where placement = 'lobby' and status = 'pending_host'),
      'reports',        (select count(*) from reports where status in ('open', 'reviewing')),
      'appeals',        (select count(*) from appeals where status = 'open'),
      'feedback',       (select count(*) from feedback_reports where status = 'new')
    ),

    'users', jsonb_build_object(
      'total',     (select count(*) from profiles),
      'new_7d',    (select count(*) from profiles where created_at >= v_7d),
      'new_30d',   (select count(*) from profiles where created_at >= v_30d),
      'suspended', (select count(*) from profiles where suspended_at is not null)
    ),

    'events', jsonb_build_object(
      'live_now',     (select count(*) from events where status = 'live'),
      'scheduled_7d', (select count(*) from events
                        where status = 'scheduled'
                          and scheduled_at between v_now and v_now + interval '7 days'),
      'streamed_7d',  (select count(*) from events where started_at >= v_7d),
      'hosts_30d',    (select count(distinct host_id) from events where started_at >= v_30d)
    ),

    -- ad_campaigns.spent_cents is a running total with no per-day history, so
    -- "ad spend in the last 7 days" is not a question this schema can answer.
    -- What it can answer is what advertisers committed in the window and what
    -- has been delivered against it to date — labelled that way in the UI.
    'money', jsonb_build_object(
      'ads_booked_7d',  (select coalesce(sum(budget_cents), 0) from ad_campaigns
                          where status in ('active', 'paused', 'completed') and created_at >= v_7d),
      'ads_booked_30d', (select coalesce(sum(budget_cents), 0) from ad_campaigns
                          where status in ('active', 'paused', 'completed') and created_at >= v_30d),
      'ads_delivered_total', (select coalesce(sum(spent_cents), 0) from ad_campaigns),
      'tips_7d',        (select coalesce(sum(amount_cents), 0) from tips
                          where status = 'paid' and created_at >= v_7d),
      'tips_30d',       (select coalesce(sum(amount_cents), 0) from tips
                          where status = 'paid' and created_at >= v_30d),
      'tickets_30d',    (select coalesce(sum(amount_cents), 0) from tickets
                          where status = 'paid' and created_at >= v_30d),
      'ad_refunds_30d', (select coalesce(sum(amount_cents), 0) from ad_refunds where created_at >= v_30d),
      -- Money owed but not yet moved. Both are work items, not history.
      'sponsor_refunds_due', (select count(*) from sponsorship_refunds where status = 'due'),
      'disputes_open',       (select count(*) from payment_disputes where closed_at is null)
    ),

    'moderation', jsonb_build_object(
      'reports_opened_7d',      (select count(*) from reports where created_at >= v_7d),
      'actions_taken_7d',       (select count(*) from moderation_audit where created_at >= v_7d),
      -- null, not 0, when nothing has been actioned in 30 days: "no data" and
      -- "we act instantly" must not render the same.
      'median_hours_to_action', round(v_median, 1),
      'appeals_decided_30d',    (select count(*) from appeals where decided_at >= v_30d),
      'appeals_overturned_30d', (select count(*) from appeals
                                  where decided_at >= v_30d and status = 'overturned')
    )
  );
end;
$$;

-- `public` must be named: CREATE FUNCTION grants EXECUTE to PUBLIC, so
-- revoking from anon and authenticated alone would be a no-op.
revoke execute on function public.get_admin_overview() from public, anon, authenticated;
grant execute on function public.get_admin_overview() to authenticated;
