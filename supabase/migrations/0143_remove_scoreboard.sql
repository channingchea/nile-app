-- 0143: Undo 0142 — the Studio scoreboard was removed before shipping
-- (2026-10-26). Nothing had been saved in any of these (checked first).

drop trigger if exists events_final_score on public.events;
drop function if exists public.events_final_score();
alter table public.events drop column if exists final_score;

-- assign_event_operator back to its 0085 form (four arguments, no scorekeeper).
drop function if exists public.assign_event_operator(uuid, uuid, uuid, boolean, boolean);

create function public.assign_event_operator(
  p_event_id uuid,
  p_operator_id uuid,
  p_camera_id uuid default null,
  p_is_audio_operator boolean default false
)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_host_id uuid;
  v_already boolean;
begin
  select host_id into v_host_id from events where id = p_event_id;

  -- Host-only (never trust the client). 0012 allowed a null auth.uid() so the
  -- host's own row could be seeded; every real caller is the host acting as
  -- themselves, so the fallback only ever served an anon attacker.
  if v_host_id is null or v_host_id is distinct from auth.uid() then
    raise exception 'not authorized';
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
     and p_operator_id is distinct from v_host_id
     and notif_enabled(p_operator_id, 'operator_assigned') is not false then
    insert into notifications (recipient_id, actor_id, type, entity_id)
    values (p_operator_id, v_host_id, 'operator_assigned', p_event_id);
  end if;
end;
$function$;

revoke all on function public.assign_event_operator(uuid, uuid, uuid, boolean) from public, anon;
grant execute on function public.assign_event_operator(uuid, uuid, uuid, boolean) to authenticated, service_role;

alter table public.event_operators drop column if exists is_scorekeeper;

drop table if exists public.studio_teams;
drop function if exists public.studio_teams_cap();
