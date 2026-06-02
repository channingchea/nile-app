-- Phase 17: "Host is live" + "Event ended" notifications
-- Run this entire file in the Supabase SQL editor.
--
-- Fired by an AFTER UPDATE trigger on events, so they fire on the genuine
-- status transition regardless of which client/code path sets it:
--   * event_live  — status → 'live'  → host's followers + paid-ticket holders
--   * event_ended — status → 'ended' → paid-ticket holders (replay is ready)
-- Host is the notification's actor; entity_id = event id (taps route to event).

-- ── Enum: add labels ──────────────────────────────────────────────────────────
-- IMPORTANT: each ALTER TYPE ... ADD VALUE must run as its own statement and
-- cannot share a transaction with later usage of the label. If the Supabase SQL
-- editor errors here, run these two lines first, then run the rest of the file.
alter type notification_type add value if not exists 'event_live';
alter type notification_type add value if not exists 'event_ended';

-- ── Shared fan-out helper ─────────────────────────────────────────────────────
-- Inserts one notification type for an event to a recipient set:
--   'followers_and_tickets' → host's followers ∪ paid-ticket holders
--   'tickets'               → paid-ticket holders only
-- Host is always excluded. Returns rows inserted.
create or replace function fanout_event_notification(
  p_event_id uuid,
  p_type     notification_type,
  p_audience text
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_host_id uuid;
  v_count   integer := 0;
begin
  select host_id into v_host_id from events where id = p_event_id;
  if v_host_id is null then
    return 0;
  end if;

  with recipients as (
    select buyer_id as uid from tickets
      where event_id = p_event_id and status = 'paid'
    union
    select follower_id as uid from follows
      where p_audience = 'followers_and_tickets' and following_id = v_host_id
  ),
  ins as (
    insert into notifications (recipient_id, actor_id, type, entity_id)
    select uid, v_host_id, p_type, p_event_id
    from recipients
    where uid <> v_host_id
    returning 1
  )
  select count(*) into v_count from ins;

  return v_count;
end;
$$;

-- ── Trigger: fire on status transition ────────────────────────────────────────
create or replace function notify_event_status_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Only act on a genuine change into the target status.
  if new.status = 'live' and old.status is distinct from 'live' then
    perform fanout_event_notification(new.id, 'event_live', 'followers_and_tickets');
  elsif new.status = 'ended' and old.status is distinct from 'ended' then
    perform fanout_event_notification(new.id, 'event_ended', 'tickets');
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_event_status_change on events;
create trigger trg_notify_event_status_change
  after update of status on events
  for each row execute function notify_event_status_change();
