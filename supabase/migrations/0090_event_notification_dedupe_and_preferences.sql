-- 0090 — C3 + C4 from the 2026-08-11 event lifecycle review.
--
-- C3 Five notification types have partial unique indexes; event_live,
--    event_ended and event_starting didn't. Two duplicate event_live pairs were
--    already in prod, both on sub-minute events — a drop-and-restart
--    double-notified those audiences. The 0089 transition trigger stops the
--    ended→live resurrection that caused it, but the index is the backstop.
-- C4 Every other type checks notif_enabled; fanout_event_notification and
--    fanout_event_starting didn't, so the event_starting / event_live /
--    event_ended toggles in Settings were inert. Fail-open on a missing
--    preferences row (`is not false`), matching every other caller.

-- ── C4: teach notif_enabled about event_no_show ─────────────────────────────
-- Deliberately mapped onto the existing event_ended column rather than adding a
-- new one: it is the same "this show is over" toggle from the user's point of
-- view, and a new column would ship a Settings row nobody asked for.
create or replace function public.notif_enabled(p_uid uuid, p_type notification_type)
returns boolean
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select case p_type
      when 'post_like'           then post_like
      when 'post_comment'        then post_comment
      when 'follow'              then follow
      when 'event_starting'      then event_starting
      when 'event_live'          then event_live
      when 'event_ended'         then event_ended
      when 'event_no_show'       then event_ended
      when 'operator_assigned'   then operator_assigned
      when 'new_message'         then new_message
      when 'message_reaction'    then message_reaction
      when 'replay_ready'        then replay_ready
      when 'tip_received'        then tip_received
      when 'soundcheck_open'     then soundcheck_open
      when 'replay_price_prompt' then replay_price_prompt
      when 'feedback_resolved'   then feedback_resolved
    end
  from notification_preferences
  where user_id = p_uid;
$function$;

-- ── C4: honour the toggles in both fan-outs ─────────────────────────────────

create or replace function public.fanout_event_notification(
  p_event_id uuid,
  p_type notification_type,
  p_audience text
)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
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
      and notif_enabled(uid, p_type) is not false
    -- C3: partial unique indexes below make a repeat fan-out a no-op rather
    -- than a second push.
    on conflict do nothing
    returning 1
  )
  select count(*) into v_count from ins;

  return v_count;
end;
$function$;

create or replace function public.fanout_event_starting(p_event_id uuid)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
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
    return 0;
  end if;

  with recipients as (
    select follower_id as uid from follows where following_id = v_host_id
    union
    select buyer_id as uid from tickets
      where event_id = p_event_id and status = 'paid'
  ),
  ins as (
    insert into notifications (recipient_id, actor_id, type, entity_id)
    select uid, v_host_id, 'event_starting', p_event_id
    from recipients
    where uid <> v_host_id
      and notif_enabled(uid, 'event_starting') is not false
    on conflict do nothing
    returning 1
  )
  select count(*) into v_count from ins;

  update events set starting_notified_at = now() where id = p_event_id;

  return v_count;
end;
$function$;

-- ── C3: dedupe what's already there, then index ─────────────────────────────

delete from notifications a
 using notifications b
 where a.type = b.type
   and a.recipient_id = b.recipient_id
   and a.entity_id is not distinct from b.entity_id
   and a.type in ('event_live', 'event_ended', 'event_starting', 'event_no_show')
   and a.ctid > b.ctid;

create unique index if not exists notifications_event_live_uniq
  on public.notifications (recipient_id, entity_id)
  where type = 'event_live';

create unique index if not exists notifications_event_ended_uniq
  on public.notifications (recipient_id, entity_id)
  where type = 'event_ended';

create unique index if not exists notifications_event_starting_uniq
  on public.notifications (recipient_id, entity_id)
  where type = 'event_starting';

create unique index if not exists notifications_event_no_show_uniq
  on public.notifications (recipient_id, entity_id)
  where type = 'event_no_show';
