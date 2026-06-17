-- Replay retention.
-- Deletes composited replay recordings (storage object + DB row) older than a
-- retention window so replay storage doesn't grow unbounded. Mirrors the
-- auto-end cron pattern (0005): a SECURITY DEFINER function on a pg_cron
-- schedule. Default window = 30 days from the replay's created_at.
--
-- Order matters: delete the storage object FIRST (by matching object name to
-- replays.playback_path, which is exactly `<eventPk>/<startedAt>.mp4`), then the
-- row. If the object delete partially fails, the row stays and the next run
-- retries — no orphaned rows pointing at missing files mid-window.

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

-- Run daily at 04:00 UTC (off-peak). SECURITY DEFINER → no extra auth needed.
select cron.schedule(
  'purge-expired-replays',
  '0 4 * * *',
  $$ select public.purge_expired_replays(30); $$
);
