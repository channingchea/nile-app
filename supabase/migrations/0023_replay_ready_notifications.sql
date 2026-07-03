-- Replay-ready notifications, part 2: preference column, notif_enabled gating,
-- and a fanout RPC the livekit-webhook calls when a replay finishes processing.
--
-- Recipients = the host's followers + everyone who holds a paid ticket to the
-- event (deduped; never the host themselves). Each recipient is gated by the
-- replay_ready preference (fail-open, like phase 18). Push delivery is free via
-- the phase 20 AFTER INSERT trigger on notifications. entity_id carries the
-- event id so tapping the notification opens the event (→ Watch Replay CTA).

-- ── Preference column ─────────────────────────────────────────────────────────

alter table notification_preferences
  add column if not exists replay_ready boolean not null default true;

-- ── notif_enabled: add the new type ───────────────────────────────────────────
-- Same fail-open contract as phase 18: NULL (no row) is treated as enabled.

create or replace function notif_enabled(p_uid uuid, p_type notification_type)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case p_type
      when 'post_like'          then post_like
      when 'post_comment'       then post_comment
      when 'follow'             then follow
      when 'event_starting'     then event_starting
      when 'event_live'         then event_live
      when 'event_ended'        then event_ended
      when 'operator_assigned'  then operator_assigned
      when 'replay_ready'       then replay_ready
    end
  from notification_preferences
  where user_id = p_uid;
$$;

-- ── Idempotency guard (fix 5) ─────────────────────────────────────────────────
-- LiveKit retries webhooks on any non-2xx, and the webhook can return 500 after
-- a partial update, so notify_replay_ready may be invoked more than once for the
-- same event. A partial unique index lets the fanout INSERT use ON CONFLICT DO
-- NOTHING, so a re-delivery can't duplicate replay_ready notifications.
create unique index if not exists notifications_replay_ready_uniq
  on notifications (recipient_id, entity_id)
  where type = 'replay_ready';

-- ── Fanout RPC ────────────────────────────────────────────────────────────────
-- Called by the webhook (service role) once per replay that becomes ready.
-- Idempotent: ON CONFLICT DO NOTHING against the partial unique index above, so
-- duplicate webhook deliveries never re-notify. p_event_id is the events PK.

create or replace function notify_replay_ready(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_host_id uuid;
begin
  select host_id into v_host_id from events where id = p_event_id;
  if v_host_id is null then
    return;
  end if;

  insert into notifications (recipient_id, actor_id, type, entity_id)
  select uid, v_host_id, 'replay_ready', p_event_id
  from (
    -- Followers of the host
    select follower_id as uid
    from follows
    where following_id = v_host_id
    union
    -- Paid-ticket holders for this event
    select buyer_id as uid
    from tickets
    where event_id = p_event_id and status = 'paid'
  ) recipients
  where uid <> v_host_id
    and notif_enabled(uid, 'replay_ready') is not false
  on conflict (recipient_id, entity_id) where (type = 'replay_ready') do nothing;
end;
$$;
