-- Message-reaction notifications, part 2: notify a message's author when
-- someone reacts to their message, via the standard notifications path (push
-- delivery is free via the phase-20 AFTER INSERT trigger on notifications).
-- Mirrors new_message (0014). The 'message_reaction' enum value is added in
-- part 1 (0019).
--
-- entity_id carries the conversation_id so a tap opens the thread (reusing the
-- new_message routing); actor_id is the reactor. No notification fires on the
-- toggle-off delete path — only on insert.

-- ── Preference column ──────────────────────────────────────────────────────────

alter table notification_preferences
  add column if not exists message_reaction boolean not null default true;

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
      when 'message_reaction'   then message_reaction
    end
  from notification_preferences
  where user_id = p_uid;
$$;

-- ── Trigger: notify the message author on each new reaction ─────────────────────
-- The recipient is the message's sender. Never self-notify (you reacting to
-- your own message). Gated by the author's message_reaction preference
-- (fail-open). Fires on INSERT only, so un-reacting (a delete) is silent.

create or replace function public.notify_message_reaction()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_author uuid;
begin
  select sender_id into v_author
  from public.messages
  where id = new.message_id;

  if v_author is null or v_author = new.user_id then
    return new;
  end if;

  if notif_enabled(v_author, 'message_reaction') is not false then
    insert into notifications (recipient_id, actor_id, type, entity_id)
    values (v_author, new.user_id, 'message_reaction', new.conversation_id);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_notify_message_reaction on public.message_reactions;
create trigger trg_notify_message_reaction
  after insert on public.message_reactions
  for each row execute function public.notify_message_reaction();
