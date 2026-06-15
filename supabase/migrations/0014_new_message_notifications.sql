-- New-message notifications, part 2: notify the recipient of a DM via the
-- standard notifications path (push delivery is free via the phase-20 AFTER
-- INSERT trigger on notifications). Mirrors the operator_assigned pattern
-- (0010/0011). The 'new_message' enum value is added in part 1 (0013).
--
-- entity_id carries the conversation_id so a tap can open the thread; actor_id
-- is the sender, which the client uses to resolve the conversation.

-- ── Preference column ──────────────────────────────────────────────────────────

alter table notification_preferences
  add column if not exists new_message boolean not null default true;

-- ── notif_enabled: add the new type ────────────────────────────────────────────
-- Same fail-open contract: NULL (no row) is treated as enabled.

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
    end
  from notification_preferences
  where user_id = p_uid;
$$;

-- ── Trigger: notify recipient on each new message ──────────────────────────────
-- The recipient is the conversation participant who is not the sender. Gated by
-- the recipient's new_message preference (fail-open). One notification row per
-- message; clients collapse the inbox/badge as they see fit.

create or replace function public.notify_new_message()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recipient uuid;
begin
  select case when participant_a = new.sender_id then participant_b
              else participant_a end
    into v_recipient
  from public.conversations
  where id = new.conversation_id;

  if v_recipient is null then
    return new;
  end if;

  if notif_enabled(v_recipient, 'new_message') is not false then
    insert into notifications (recipient_id, actor_id, type, entity_id)
    values (v_recipient, new.sender_id, 'new_message', new.conversation_id);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_notify_new_message on public.messages;
create trigger trg_notify_new_message
  after insert on public.messages
  for each row execute function public.notify_new_message();
