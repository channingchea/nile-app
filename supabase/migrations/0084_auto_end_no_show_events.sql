-- 0084 — auto-end events the host never started.
--
-- auto_end_expired_events only swept status = 'live', so an event whose host
-- never went live (row still 'scheduled') or who opened Sound Check and quit
-- (row still 'soundcheck') stayed in that status forever. Event detail then
-- kept promising viewers "Waiting for host to start the stream…" on shows that
-- were days old, and the events stayed in feeds. Widen the sweep to close
-- those windows too. Applied to prod 2026-08-11 (backfilled 9 rows).

create or replace function public.auto_end_expired_events(p_grace_minutes integer default 2)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_count       integer;
  v_max_minutes integer;
begin
  select max_stream_minutes into v_max_minutes
    from public.app_config where id = 1;
  v_max_minutes := coalesce(v_max_minutes, 480);

  with expired as (
    update public.events e
       set status = 'ended',
           -- A no-show never ran, so stamp it with the close of its scheduled
           -- window rather than now() — otherwise a June event backfilled
           -- today would read as having "just ended".
           ended_at = case
             when e.status = 'live' then now()
             else least(
                    now(),
                    coalesce(
                      e.end_at,
                      e.scheduled_at + make_interval(mins => v_max_minutes)
                    )
                  )
           end
     where (
       -- Went live, but is past its planned duration or the hard stream cap.
       e.status = 'live'
       and (
         (e.end_at is not null
          and coalesce(
                e.started_at + (e.end_at - e.scheduled_at),
                e.end_at
              ) < now() - make_interval(mins => p_grace_minutes))
         or (e.started_at is not null
             and e.started_at < now()
                 - make_interval(mins => v_max_minutes + p_grace_minutes))
       )
     ) or (
       -- Never went live: host no-show, or an abandoned Sound Check. Events
       -- with neither end_at nor scheduled_at are left alone (coalesce is
       -- null, so the comparison is null and the row is not matched).
       -- A host sitting in Sound Check past their own scheduled end is off
       -- schedule but still actively setting up, so give that state a
       -- 30-minute cushion; a 'scheduled' row means nobody ever opened it.
       e.status in ('scheduled', 'soundcheck')
       and coalesce(
             e.end_at,
             e.scheduled_at + make_interval(mins => v_max_minutes)
           ) < now() - make_interval(
                 mins => case when e.status = 'soundcheck'
                              then greatest(p_grace_minutes, 30)
                              else p_grace_minutes end
               )
     )
    returning e.id
  )
  select count(*) into v_count from expired;
  return v_count;
end;
$function$;

-- One-time backfill of rows the old sweep never touched. The pg_cron job
-- (jobid 3, every 5 minutes) keeps calling this from here on.
select public.auto_end_expired_events(2);
