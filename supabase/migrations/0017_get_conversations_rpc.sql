-- Single-call conversation list for the Messages screen.
-- Replaces the client-side N+1 loop (one query per conversation for the last
-- message) plus separate unread and live-presence queries with one round trip.
--
-- SECURITY INVOKER (default): runs as the caller, so conversations/messages/
-- profiles/events RLS applies as usual. Only the caller's own conversations are
-- returned (participant filter on auth.uid()).
--
-- One row per conversation, newest activity first. Fields mirror what
-- MessageService.Conversation needs: counterpart profile, last message preview,
-- unread count, and whether the counterpart is currently hosting a live show
-- (status 'live' or 'soundcheck').

create or replace function public.get_conversations_for_user()
returns table (
  id uuid,
  participant_a uuid,
  participant_b uuid,
  last_message_at timestamptz,
  created_at timestamptz,
  other_user_id uuid,
  other_username text,
  other_avatar_url text,
  unread_count bigint,
  last_message_content text,
  is_live boolean
)
language sql
stable
as $$
  with me as (select auth.uid() as uid)
  select
    c.id,
    c.participant_a,
    c.participant_b,
    c.last_message_at,
    c.created_at,
    other.id as other_user_id,
    other.username as other_username,
    other.avatar_url as other_avatar_url,
    coalesce((
      select count(*)
      from messages m
      where m.conversation_id = c.id
        and m.sender_id <> me.uid
        and m.read_at is null
    ), 0) as unread_count,
    (
      select m.content
      from messages m
      where m.conversation_id = c.id
      order by m.created_at desc
      limit 1
    ) as last_message_content,
    exists (
      select 1
      from events e
      where e.host_id = other.id
        and e.status in ('live', 'soundcheck')
    ) as is_live
  from conversations c
  cross join me
  join profiles other
    on other.id = case
         when c.participant_a = me.uid then c.participant_b
         else c.participant_a
       end
  where c.participant_a = me.uid or c.participant_b = me.uid
  order by c.last_message_at desc nulls last;
$$;

grant execute on function public.get_conversations_for_user() to authenticated;
