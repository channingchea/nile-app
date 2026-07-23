-- 0064_profile_is_official.sql
-- Phase 5 (new-user engagement): official Nile house-account badge.
--
-- Adds `profiles.is_official`. Only the service role (SQL / Edge Functions) or
-- an admin may set it — never the profile owner. Supabase grants the
-- `authenticated` role table-wide UPDATE, so a column-level REVOKE would be
-- ineffective; a BEFORE trigger is the reliable guard. Any client attempt to
-- flip the flag is silently ignored (the value reverts), so ordinary profile
-- edits still succeed.
--
-- Marking the house account official is an ops step (service role):
--   update profiles set is_official = true where username = 'nile';

alter table profiles
  add column is_official boolean not null default false;

create or replace function public.protect_is_official()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  -- Client roles ('authenticated', 'anon') are blocked; the service role,
  -- direct SQL (role null), and admins are allowed.
  authorized boolean := coalesce(auth.role(), '') not in ('authenticated', 'anon')
                        or public.is_admin();
begin
  if tg_op = 'INSERT' then
    if new.is_official and not authorized then
      new.is_official := false;
    end if;
  elsif new.is_official is distinct from old.is_official and not authorized then
    new.is_official := old.is_official;
  end if;
  return new;
end;
$$;

-- Trigger function only — never an RPC. Revoke client EXECUTE (matches 0060).
revoke execute on function public.protect_is_official() from public, anon, authenticated;

create trigger profiles_protect_is_official
  before insert or update on profiles
  for each row
  execute function public.protect_is_official();

-- Surface the counterpart's official flag in the Messages list (DM headers).
-- Return type changes, so the old signature must be dropped first.
drop function if exists public.get_conversations_for_user();
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
  other_is_official boolean,
  unread_count bigint,
  last_message_content text,
  is_live boolean
)
language sql
stable
set search_path = public
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
    other.is_official as other_is_official,
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
