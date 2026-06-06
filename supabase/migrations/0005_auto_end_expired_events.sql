-- Duration-expiry auto-end.
-- Ends a LIVE show once it runs past its scheduled end (end_at = scheduled_at +
-- duration), plus a grace window. Mirrors the app's EventService.end(): sets
-- status='ended' and ended_at=now(). The existing AFTER UPDATE OF status trigger
-- (trg_notify_event_status_change) then fans out event_ended notifications, so
-- ticket holders are notified exactly as with a host-pressed End Stream.
--
-- Guards:
--   * only status='live' (a soundcheck past end_at is likely a host still
--     setting up; a never-started 'scheduled' event shouldn't be "ended").
--   * end_at IS NOT NULL (older events with unknown duration are left alone).
--   * GRACE keeps us from cutting a show off at the exact wire.
create or replace function public.auto_end_expired_events(p_grace_minutes int default 2)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  with expired as (
    update public.events
       set status = 'ended',
           ended_at = now()
     where status = 'live'
       and end_at is not null
       and end_at < now() - make_interval(mins => p_grace_minutes)
    returning id
  )
  select count(*) into v_count from expired;
  return v_count;
end;
$$;

comment on function public.auto_end_expired_events(int) is
  'Cron-invoked: ends live events past end_at + grace. Status trigger handles event_ended fanout.';

-- Run every 5 minutes. SECURITY DEFINER means the cron call needs no extra auth.
select cron.schedule(
  'auto-end-expired-events',
  '*/5 * * * *',
  $$ select public.auto_end_expired_events(2); $$
);
