-- 0091 — C14, C15, C16 from the 2026-08-11 event lifecycle review.
--
-- C14 fail_stuck_replays(6) ran hourly and failed any recording older than 6
--     hours, but max_stream_minutes is 480 (8h) and the pricing model sells
--     shows that long. A 7-hour show had its recording marked 'failed' while
--     still running; every recovery path filters on status = 'recording', so
--     End Show never stopped the egress and it billed into dead air. A restart
--     hit the same filter and cheerfully started a SECOND concurrent recording.
--     And 'failed' is a dead end because auto_publish_replays only selects
--     'ready'. Default raised above the cap plus finalization time, and the
--     cron argument (jobid 5) raised to match.
-- C15 auto_publish_replays ignored removed_at, so a moderator-removed event's
--     replay auto-published 48h later and pushed "replay ready" to every
--     follower — moderation undone by a cron job.
-- C16 events.price has no upper bound; replay_price is capped at 50000. One
--     $600 event raised inside the single-transaction loop and rolled back
--     every publication in that run, hourly, forever. Price is now clamped and
--     each row is isolated so one bad row can't take the batch down.

create or replace function public.fail_stuck_replays(p_timeout_hours integer default 10)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_count integer;
  v_max   integer;
  v_floor integer;
begin
  -- Never fail a recording that could still legitimately be running: the hard
  -- stream cap plus an hour for egress finalization.
  select max_stream_minutes into v_max from app_config where id = 1;
  v_floor := ceil(coalesce(v_max, 480) / 60.0)::integer + 1;
  if p_timeout_hours < v_floor then
    p_timeout_hours := v_floor;
  end if;

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
$function$;

select cron.alter_job(5, command => $job$ select public.fail_stuck_replays(10); $job$);

create or replace function public.auto_publish_replays(p_hours integer default 48)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  r          record;
  v_max      integer := 50000; -- mirrors publish_replay's ceiling
  v_price    integer;
begin
  for r in
    select e.id, coalesce(e.price, 0) as live_price
      from events e
     where e.replay_published_at is null
       -- C15: a moderator-removed event must not publish anything, least of all
       -- with a push to every follower.
       and e.removed_at is null
       and exists (
         select 1 from replays rp
          where rp.event_id = e.id
            and rp.status = 'ready'
            and rp.created_at < now() - make_interval(hours => p_hours)
       )
  loop
    -- C16: one row must never be able to roll back the whole run. Clamp the
    -- price into the allowed range and isolate the failure.
    begin
      v_price := least(greatest(r.live_price, 0), v_max);

      update events
         set replay_price = v_price,
             replay_published_at = now()
       where id = r.id and replay_published_at is null;

      perform fanout_replay_ready(r.id);
    exception when others then
      raise warning 'auto_publish_replays: skipped event % (%)', r.id, sqlerrm;
    end;
  end loop;
end;
$function$;
