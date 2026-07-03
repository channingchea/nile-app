-- Replay retention + stuck-row reconcile.
--
-- (a) purge_expired_replays: deletes composited replay recordings (storage
--     object + DB row) older than a retention window so replay storage doesn't
--     grow unbounded. Mirrors the auto-end cron pattern (0005): a SECURITY
--     DEFINER function on a pg_cron schedule. Default window = 30 days from the
--     replay's created_at.
--
--     Order matters: delete the storage object FIRST (by matching object name to
--     replays.playback_path, which is exactly `<eventPk>/<startedAt>.mp4`), then
--     the row. If the object delete partially fails, the row stays and the next
--     run retries — no orphaned rows pointing at missing files mid-window.
--
-- (b) fail_stuck_replays (fix 3): the egress_ended webhook is the only thing
--     that flips a row out of 'recording'/'processing'. If that webhook never
--     arrives (egress crash, misconfig, signature failure), the row is stuck
--     forever and the event never shows a replay CTA. This sweep flips rows that
--     have been recording/processing for longer than a generous timeout to
--     'failed' so the UI settles on the inert "Stream Ended" state instead of
--     waiting indefinitely. 6h is far longer than any real show + egress
--     finalization, so a live long-running show is never falsely failed.

create or replace function public.purge_expired_replays(p_retention_days int default 30)
returns integer
language plpgsql
security definer
set search_path = public, storage, pg_temp
as $$
declare
  v_count integer;
begin
  -- Remove the underlying storage objects for expired replays.
  delete from storage.objects o
   using public.replays r
   where o.bucket_id = 'replays'
     and o.name = r.playback_path
     and r.created_at < now() - make_interval(days => p_retention_days);

  -- Remove the expired replay rows (covers failed rows with no playback_path too).
  with purged as (
    delete from public.replays
     where created_at < now() - make_interval(days => p_retention_days)
    returning id
  )
  select count(*) into v_count from purged;
  return v_count;
end;
$$;

comment on function public.purge_expired_replays(int) is
  'Cron-invoked: deletes replay storage objects + rows older than the retention window.';

-- Fail rows stuck mid-recording past the timeout (default 6h).
create or replace function public.fail_stuck_replays(p_timeout_hours int default 6)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  with stuck as (
    update public.replays
       set status = 'failed'
     where status in ('recording','processing')
       and created_at < now() - make_interval(hours => p_timeout_hours)
    returning id
  )
  select count(*) into v_count from stuck;
  return v_count;
end;
$$;

comment on function public.fail_stuck_replays(int) is
  'Cron-invoked: marks replays stuck in recording/processing past the timeout as failed.';

-- Run daily at 04:00 UTC (off-peak). SECURITY DEFINER → no extra auth needed.
select cron.schedule(
  'purge-expired-replays',
  '0 4 * * *',
  $$ select public.purge_expired_replays(30); $$
);

-- Reconcile stuck rows hourly so a missed webhook self-heals within the hour.
select cron.schedule(
  'fail-stuck-replays',
  '0 * * * *',
  $$ select public.fail_stuck_replays(6); $$
);
