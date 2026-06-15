-- The host can crew a camera themselves; they need an event_operators row to
-- carry their slot/device assignment (Crew Setup reads only those rows), so
-- drop the old "host is implicit, skip the row" early-return from
-- assign_event_operator. Never self-notify (covers the host-assigns-self case
-- and any future self-assign).

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
  v_actor   uuid;
  v_already boolean;
begin
  select host_id into v_host_id from events where id = p_event_id;
  v_actor := coalesce(auth.uid(), v_host_id);

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
     and p_operator_id is distinct from v_actor
     and notif_enabled(p_operator_id, 'operator_assigned') is not false then
    insert into notifications (recipient_id, actor_id, type, entity_id)
    values (p_operator_id, v_actor, 'operator_assigned', p_event_id);
  end if;
end;
$$;
