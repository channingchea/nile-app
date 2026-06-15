-- Operator-assigned notifications, part 2: preference column, notif_enabled
-- gating, and the notification insert inside assign_event_operator.
--
-- The client already renders operator_assigned notifications and exposes the
-- preference toggle (and even writes operator_assigned in its prefs upsert);
-- this migration supplies the missing server side. Push delivery is free via
-- the phase 20 AFTER INSERT trigger on notifications.

-- ── Preference column ─────────────────────────────────────────────────────────

alter table notification_preferences
  add column if not exists operator_assigned boolean not null default true;

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
      when 'post_like'         then post_like
      when 'post_comment'      then post_comment
      when 'follow'             then follow
      when 'event_starting'     then event_starting
      when 'event_live'         then event_live
      when 'event_ended'        then event_ended
      when 'operator_assigned'  then operator_assigned
    end
  from notification_preferences
  where user_id = p_uid;
$$;

-- ── assign_event_operator: notify on first assignment ─────────────────────────
-- Drop the stale pre-phase-23 3-arg overload first; with the 4th param
-- defaulted, a 3-arg call would otherwise be ambiguous.

drop function if exists assign_event_operator(uuid, uuid, uuid);

-- Replaces the phase 23 version. Notification fires only on a fresh
-- (event, operator) row — re-saving the crew with a different camera slot is
-- an UPDATE and stays silent — and only if the operator hasn't disabled the
-- operator_assigned preference. entity_id carries the event id so tapping the
-- notification can open the event.

create or replace function assign_event_operator(
  p_event_id          uuid,
  p_operator_id       uuid,
  p_camera_id         uuid    default null,
  p_is_audio_operator boolean default false
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_host_id uuid;
  v_already boolean;
begin
  select host_id into v_host_id from events where id = p_event_id;

  -- Host is always implicitly a crew member; skip inserting a row for them.
  if v_host_id = p_operator_id then
    return;
  end if;

  select exists (
    select 1 from event_operators
    where event_id = p_event_id and operator_id = p_operator_id
  ) into v_already;

  insert into event_operators (event_id, operator_id, camera_id, is_audio_operator)
  values (p_event_id, p_operator_id, p_camera_id, p_is_audio_operator)
  on conflict (event_id, operator_id)
  do update set
    camera_id = excluded.camera_id,
    is_audio_operator = excluded.is_audio_operator;

  if not v_already
     and notif_enabled(p_operator_id, 'operator_assigned') is not false then
    insert into notifications (recipient_id, actor_id, type, entity_id)
    values (p_operator_id, coalesce(auth.uid(), v_host_id), 'operator_assigned', p_event_id);
  end if;
end;
$$;
