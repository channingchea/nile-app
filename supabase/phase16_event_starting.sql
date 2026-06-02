-- Phase 16: "Event starting soon" notifications
-- Run this entire file in the Supabase SQL editor.
--
-- A cron-invoked Edge Function (notify-event-starting) fans out an
-- 'event_starting' notification ~15 minutes before a scheduled event begins.
-- Recipients are the host's followers plus anyone holding a paid ticket.
-- The host is the notification's actor (their avatar/name render on the tile);
-- entity_id is the event id, so tapping routes to the event.

-- ── Enum: add 'event_starting' ────────────────────────────────────────────────
-- IMPORTANT: run this single statement on its own (it cannot share a
-- transaction with later DDL/usage of the new label). The Supabase SQL editor
-- runs the whole file in one txn, so if it errors here, run just this line
-- first, then run the rest of the file.
alter type notification_type add value if not exists 'event_starting';

-- ── Idempotency flag on events ────────────────────────────────────────────────
-- Set once the reminder has been fanned out, so re-runs of the cron skip the
-- event. Cleared paths: never (one reminder per event lifetime).
alter table events
  add column if not exists starting_notified_at timestamptz;

-- Cron scan path: scheduled events in the reminder window that haven't fired.
create index if not exists events_starting_scan_idx
  on events (status, scheduled_at)
  where starting_notified_at is null;

-- ── Fan-out function (SECURITY DEFINER) ───────────────────────────────────────
-- Inserts notifications for one event and stamps starting_notified_at in the
-- same statement-scope, so it is safe to call repeatedly. Returns rows inserted.
create or replace function fanout_event_starting(p_event_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_host_id uuid;
  v_already timestamptz;
  v_count   integer := 0;
begin
  select host_id, starting_notified_at
    into v_host_id, v_already
  from events
  where id = p_event_id
  for update;

  if v_host_id is null or v_already is not null then
    return 0;  -- unknown event, or already fanned out.
  end if;

  with recipients as (
    -- Host's followers.
    select follower_id as uid from follows where following_id = v_host_id
    union
    -- Paid ticket holders.
    select buyer_id as uid from tickets
      where event_id = p_event_id and status = 'paid'
  ),
  ins as (
    insert into notifications (recipient_id, actor_id, type, entity_id)
    select uid, v_host_id, 'event_starting', p_event_id
    from recipients
    where uid <> v_host_id  -- never notify the host about their own event.
    returning 1
  )
  select count(*) into v_count from ins;

  update events set starting_notified_at = now() where id = p_event_id;

  return v_count;
end;
$$;

-- The Edge Function selects due events and calls fanout_event_starting per id
-- using the service-role key, so no extra client grant is required.
