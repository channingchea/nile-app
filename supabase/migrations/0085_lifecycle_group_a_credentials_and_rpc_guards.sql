-- 0085 — Group A of the 2026-08-11 event lifecycle review.
--
-- A1  Strip the plaintext credentials out of cron.job. jobid 1 embedded a
--     service_role JWT (exp 2036, bypasses all RLS); jobid 6 embedded an
--     sb_secret_ key. Both target functions are deployed verify_jwt:false and
--     ignore the Authorization header entirely (`serve(async (_req) => ...)`),
--     so the credentials bought nothing — they are removed rather than moved
--     to the vault. Both keys were read during the audit and must also be
--     rotated in the dashboard; this migration only stops the bleeding.
-- A3  assign_event_operator was SECURITY DEFINER, granted to anon, and never
--     compared host_id to auth.uid() — one anon call self-assigned operator on
--     any event, which grants free access to that event's paid replays and
--     publish rights. Guarded host-only (the guard publish_replay uses) and
--     revoked from anon.
-- A4  increment_viewer_count / decrement_viewer_count were SECURITY DEFINER,
--     anon-granted, and referenced no caller identity — anyone could pump or
--     zero any event's count. Nothing calls them: the livekit function derives
--     viewer_count from LiveKit's participant list via reconcile-viewers with
--     the service-role client, and the Dart wrappers are dead code (deleted in
--     the same change). Revoked from anon and authenticated; kept in place so
--     the reconcile path has a rollback target.

-- ── A1 ───────────────────────────────────────────────────────────────────────

select cron.alter_job(
  1,
  command => $job$
    select net.http_post(
      url     := 'https://jelmkkvyrliywcdkzhuu.functions.supabase.co/notify-event-starting',
      headers := jsonb_build_object('Content-Type', 'application/json')
    );
  $job$
);

select cron.alter_job(
  6,
  command => $job$
    select net.http_post(
      url     := 'https://jelmkkvyrliywcdkzhuu.functions.supabase.co/tally-ad-spend',
      headers := jsonb_build_object('Content-Type', 'application/json')
    );
  $job$
);

-- ── A3 ───────────────────────────────────────────────────────────────────────

create or replace function public.assign_event_operator(
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

revoke execute on function public.assign_event_operator(uuid, uuid, uuid, boolean) from anon;

-- ── A4 ───────────────────────────────────────────────────────────────────────

revoke execute on function public.increment_viewer_count(text) from anon, authenticated;
revoke execute on function public.decrement_viewer_count(text) from anon, authenticated;
