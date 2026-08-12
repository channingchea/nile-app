-- 0089 — C1, C7, C8, C13 from the 2026-08-11 event lifecycle review.
--
-- C1  events.status had no CHECK, no transition trigger and no policy predicate;
--     events_update_own is a bare USING (host_id = auth.uid()). A host could
--     PATCH any status from any status. Concretely that bypassed the payout
--     gate: trg_enforce_paid_publish_payable only fires WHEN new.status =
--     'scheduled', so writing 'live' directly published a paid event with no
--     Stripe account attached.
-- C7  started_at was the host device's wall clock, and the auto-end sweep
--     computes the whole run length from it — a phone 20 minutes fast billed 20
--     extra minutes of egress; 20 minutes slow cut the show off mid-set.
--     Stamped server-side here, so the client value is now ignored entirely.
-- C8  An event with neither end_at nor started_at could never match the sweep's
--     live branch and stayed LIVE forever. C7 guarantees started_at on every
--     live row, which closes it; the backfill below covers any existing rows.
-- C13 Sound Check had no upper bound, so a host entering hours after their slot
--     flipped the row to 'soundcheck' while every viewer surface said ENDED —
--     the Studio said SOUND CHECK and nobody could get in.

create or replace function public.enforce_event_status_transition()
returns trigger
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_ok      boolean;
  v_max     integer;
  v_end     timestamptz;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  -- The legal moves. Everything the app and the crons actually do is here;
  -- anything else is a client writing a status it has no business writing.
  v_ok := case old.status
    when 'draft'      then new.status in ('scheduled', 'cancelled')
    when 'scheduled'  then new.status in ('soundcheck', 'live', 'ended', 'cancelled')
    when 'soundcheck' then new.status in ('scheduled', 'live', 'ended', 'cancelled')
    when 'live'       then new.status in ('ended', 'cancelled')
    -- 'ended' and 'cancelled' are terminal. A finished show must not be
    -- resurrected: that re-fires the "is live" push to every follower and
    -- restarts billing on a fresh egress.
    else false
  end;

  if not v_ok then
    raise exception 'illegal event status transition: % -> %', old.status, new.status
      using errcode = 'check_violation';
  end if;

  -- C13: entering Sound Check on a show whose window has already closed puts
  -- the row in a state every viewer surface reads as ENDED. Same effective-end
  -- rule Event.isOver uses client-side (end_at, else scheduled_at + the cap).
  if new.status = 'soundcheck' then
    select max_stream_minutes into v_max from app_config where id = 1;
    v_end := coalesce(
      new.end_at,
      new.scheduled_at + make_interval(mins => coalesce(v_max, 480))
    );
    if v_end is not null and v_end < now() then
      raise exception 'this event''s window has already closed'
        using errcode = 'check_violation';
    end if;
  end if;

  -- C7: server clock, always. Never trust the device that pressed the button.
  if new.status = 'live' then
    new.started_at := now();
  end if;

  return new;
end;
$function$;

drop trigger if exists trg_enforce_event_status_transition on public.events;
create trigger trg_enforce_event_status_transition
  before update of status on public.events
  for each row
  execute function public.enforce_event_status_transition();

-- C8 backfill: any live row with no started_at could never be swept. None on
-- prod today, but the trigger only covers transitions from here forward.
update public.events
   set started_at = coalesce(started_at, created_at)
 where status = 'live' and started_at is null;
