-- Auto-end anchored to the ACTUAL start, not the scheduled end.
--
-- 0005 ended live shows once now() passed end_at (= scheduled_at + duration).
-- If the host went live late, the show got cut short: a 60-min show starting
-- 30 min late only got 30 min. Fix: give every live show its full purchased
-- duration measured from started_at. Events missing started_at/scheduled_at
-- fall back to the old end_at behaviour. Host-pressed End Stream is untouched.
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
       and coalesce(
             started_at + (end_at - scheduled_at), -- duration from actual start
             end_at                                -- fallback: scheduled end
           ) < now() - make_interval(mins => p_grace_minutes)
    returning id
  )
  select count(*) into v_count from expired;
  return v_count;
end;
$$;

comment on function public.auto_end_expired_events(int) is
  'Cron-invoked: ends live events after their full duration measured from started_at (fallback end_at), plus grace.';
