-- Sound-check-open crew notifications, part 2: preference column, notif_enabled
-- gating, and a fan-out RPC the host client calls when it enters sound check.
--
-- When the host opens sound check, every assigned operator on the event gets a
-- 'soundcheck_open' notification (push delivery is free via the phase 20 AFTER
-- INSERT trigger on notifications) so crew know to join and ready up. Gated by
-- the per-user preference and deduped so re-entering sound check for the same
-- event stays quiet.

-- ── Preference column ─────────────────────────────────────────────────────────

alter table notification_preferences
  add column if not exists soundcheck_open boolean not null default true;

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
      when 'new_message'        then new_message
      when 'message_reaction'   then message_reaction
      when 'replay_ready'       then replay_ready
      when 'tip_received'       then tip_received
      when 'soundcheck_open'    then soundcheck_open
    end
  from notification_preferences
  where user_id = p_uid;
$$;

-- ── Dedupe guard ──────────────────────────────────────────────────────────────
-- One soundcheck_open per (recipient, event) — a host who drops and re-enters
-- sound check for the same show won't re-notify the crew.
create unique index if not exists notifications_soundcheck_open_uniq
  on notifications (recipient_id, entity_id)
  where type = 'soundcheck_open';

-- ── Fan-out RPC ───────────────────────────────────────────────────────────────
-- Called by the host client on entering sound check. Resolves the event by its
-- LiveKit slug, verifies the caller is the host (so only the host can trigger a
-- crew ping), then inserts a soundcheck_open for each assigned operator that
-- hasn't disabled the preference. entity_id carries the event id so tapping the
-- notification opens the event.

create or replace function notify_soundcheck_open(p_livekit_room text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event_id uuid;
  v_host_id  uuid;
begin
  select id, host_id into v_event_id, v_host_id
    from events where livekit_room = p_livekit_room;

  -- Unknown event, or caller isn't the host: no-op (never trust the client).
  if v_event_id is null or v_host_id is distinct from auth.uid() then
    return;
  end if;

  insert into notifications (recipient_id, actor_id, type, entity_id)
  select eo.operator_id, v_host_id, 'soundcheck_open', v_event_id
    from event_operators eo
   where eo.event_id = v_event_id
     and eo.operator_id <> v_host_id
     and notif_enabled(eo.operator_id, 'soundcheck_open') is not false
  on conflict do nothing;
end;
$$;
