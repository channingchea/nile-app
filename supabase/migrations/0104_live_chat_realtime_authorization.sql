-- 0104 — put the live-chat Realtime Authorization rules under version control.
--
-- P1 #15. chat_service.dart cites "migration 0099" for these, but 0099 is the
-- sponsorship offer dedupe migration and no migration in the repo mentions
-- `realtime.` at all. They were applied straight to prod and never committed.
--
-- Checked against prod 2026-08-17 before writing this: chat is NOT broken. The
-- function and both policies are live and doing their job, so the exposure is
-- purely that they exist in exactly one place. Restore this database from a
-- backup, or stand up a second environment, and they would be silently absent —
-- and the failure mode of an absent policy here is not "chat stops working",
-- it is "anyone who knows the slug is in the paid show's chat", because the
-- slug is in the public share URL.
--
-- This migration therefore records what is already running, verbatim. It does
-- not change behaviour on prod: every statement is guarded so it is a no-op
-- when the object already exists.
--
-- Deliberately NOT changed here: `can_join_live_chat` still carries EXECUTE for
-- PUBLIC and anon (0100 listed it as an exception to its revoke rule). It is
-- SECURITY DEFINER and returns false whenever auth.uid() is null, so anon can
-- never get a true out of it. Tightening that is a behaviour change and belongs
-- in its own migration, not in one whose whole purpose is to make the current
-- state reproducible.

-- ── The gate ────────────────────────────────────────────────────────────────
-- Same rule the viewer-token mint applies: host and assigned crew always; a
-- free show admits any signed-in viewer; a paid show needs a paid ticket.
create or replace function public.can_join_live_chat(p_topic text)
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_slug  text;
  v_event record;
  v_uid   uuid := auth.uid();
begin
  if v_uid is null then
    return false;
  end if;

  v_slug := split_part(p_topic, ':', 2);
  if v_slug is null or v_slug = '' then
    return false;
  end if;

  select id, host_id, coalesce(price, 0) as price
    into v_event
    from events
   where livekit_room = v_slug;
  if not found then
    return false;
  end if;

  -- Host and assigned crew are always in the room.
  if v_event.host_id = v_uid then
    return true;
  end if;
  if exists (
    select 1 from event_operators o
     where o.event_id = v_event.id and o.operator_id = v_uid
  ) then
    return true;
  end if;

  -- Free show: any signed-in viewer. Paid show: a paid ticket, same gate the
  -- viewer-token mint applies.
  if v_event.price = 0 then
    return true;
  end if;
  return exists (
    select 1 from tickets t
     where t.event_id = v_event.id
       and t.buyer_id = v_uid
       and t.status = 'paid'
  );
end;
$function$;

-- ── The policies ────────────────────────────────────────────────────────────
-- realtime.messages is owned by supabase_realtime_admin, but postgres is
-- granted policy management on it (verified on prod before writing this).
--
-- Created only if absent. Dropping and recreating would open a window — however
-- brief — in which a paid show's chat had no authorization at all, which is not
-- a risk worth taking to re-apply a policy that is already correct.
do $$
begin
  if not exists (
    select 1 from pg_policies
     where schemaname = 'realtime' and tablename = 'messages'
       and policyname = 'live_chat_read'
  ) then
    -- Read covers both topics: the chat itself and the read-only system topic
    -- carrying server-authored announcements (tips).
    execute $p$
      create policy live_chat_read on realtime.messages
        for select to authenticated
        using (
          (realtime.topic() like 'live_chat:%' or realtime.topic() like 'live_system:%')
          and can_join_live_chat(realtime.topic())
        )
    $p$;
  end if;

  if not exists (
    select 1 from pg_policies
     where schemaname = 'realtime' and tablename = 'messages'
       and policyname = 'live_chat_write'
  ) then
    -- Write covers live_chat only. No INSERT on live_system is what stops a
    -- viewer forging a "@host tipped $200 🎉" line in the system style to a
    -- room full of people who just paid to be in it.
    execute $p$
      create policy live_chat_write on realtime.messages
        for insert to authenticated
        with check (
          realtime.topic() like 'live_chat:%'
          and can_join_live_chat(realtime.topic())
        )
    $p$;
  end if;
end $$;
