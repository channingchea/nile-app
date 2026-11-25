-- 0133: Studio chat tools (studio-edits plan, phase 2).
--
--   events.chat_pinned          the one pinned message, a snapshot
--   live_chat_messages.filtered_at  set when the host's blocked words held a
--                               line back; it was never broadcast
--   chat_quick_messages         the host's canned lines (owner-only)
--   chat_blocked_terms          the host's own blocked words (owner-only),
--                               on top of the platform list from 0110
--   live_mod:<slug>             Realtime topic for moderators only — the
--                               filtered lines, as they arrive

alter table public.events add column if not exists chat_pinned jsonb;

alter table public.live_chat_messages add column if not exists filtered_at timestamptz;

-- "First-time chatter": has this person ever chatted in any of this host's
-- shows? Asked once per message, by sender.
create index if not exists live_chat_messages_sender_idx
  on public.live_chat_messages (sender_id, event_id);

-- ── Quick messages ──────────────────────────────────────────────────────────
create table if not exists public.chat_quick_messages (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references public.profiles(id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 500),
  sort       int not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists chat_quick_messages_owner_sort
  on public.chat_quick_messages (owner_id, sort, created_at);

alter table public.chat_quick_messages enable row level security;

drop policy if exists chat_quick_messages_owner_all on public.chat_quick_messages;
create policy chat_quick_messages_owner_all on public.chat_quick_messages
  for all to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

create or replace function public.chat_quick_messages_cap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select count(*) from public.chat_quick_messages where owner_id = new.owner_id) >= 100 then
    raise exception 'Quick messages are full (100)' using errcode = 'P0001';
  end if;
  return new;
end
$$;

drop trigger if exists chat_quick_messages_cap on public.chat_quick_messages;
create trigger chat_quick_messages_cap
  before insert on public.chat_quick_messages
  for each row execute function public.chat_quick_messages_cap();

-- ── Blocked words (per host) ────────────────────────────────────────────────
create table if not exists public.chat_blocked_terms (
  owner_id   uuid not null references public.profiles(id) on delete cascade,
  term       text not null check (char_length(term) between 1 and 60 and term = lower(term)),
  created_at timestamptz not null default now(),
  primary key (owner_id, term)
);

alter table public.chat_blocked_terms enable row level security;

drop policy if exists chat_blocked_terms_owner_all on public.chat_blocked_terms;
create policy chat_blocked_terms_owner_all on public.chat_blocked_terms
  for all to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

create or replace function public.chat_blocked_terms_cap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (select count(*) from public.chat_blocked_terms where owner_id = new.owner_id) >= 500 then
    raise exception 'Blocked words are full (500)' using errcode = 'P0001';
  end if;
  return new;
end
$$;

drop trigger if exists chat_blocked_terms_cap on public.chat_blocked_terms;
create trigger chat_blocked_terms_cap
  before insert on public.chat_blocked_terms
  for each row execute function public.chat_blocked_terms_cap();

-- Does [p_text] hit one of [p_host]'s blocked words? Same matching as the
-- platform list (0110): single words on whole-word boundaries, case-
-- insensitive; entries with a space match as phrases.
create or replace function public.host_blocked_term_hit(p_host uuid, p_text text)
returns text
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  with tokens as (
    select unnest(regexp_split_to_array(lower(p_text), '[^[:alnum:]'']+')) as t
  )
  select w.term
    from public.chat_blocked_terms w
   where w.owner_id = p_host
     and ((position(' ' in w.term) = 0 and w.term in (select t from tokens))
       or (position(' ' in w.term) > 0 and position(w.term in lower(p_text)) > 0))
   order by length(w.term) desc
   limit 1;
$function$;

revoke all on function public.host_blocked_term_hit(uuid, text) from public, anon, authenticated;
grant execute on function public.host_blocked_term_hit(uuid, text) to service_role;

-- ── Moderator topic ─────────────────────────────────────────────────────────
-- The host, or assigned crew when the host turned crew moderation on — the
-- same rule live-chat's requireModerator applies.
create or replace function public.can_moderate_live_chat(p_topic text)
returns boolean
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_uid  uuid := auth.uid();
  v_slug text := split_part(p_topic, ':', 2);
  v_event record;
begin
  if v_uid is null or v_slug is null or v_slug = '' then
    return false;
  end if;
  select id, host_id, chat_crew_moderation into v_event
    from events where livekit_room = v_slug;
  if not found then
    return false;
  end if;
  if v_event.host_id = v_uid then
    return true;
  end if;
  return v_event.chat_crew_moderation and exists (
    select 1 from event_operators o
     where o.event_id = v_event.id and o.operator_id = v_uid
  );
end;
$function$;

revoke all on function public.can_moderate_live_chat(text) from public, anon;
grant execute on function public.can_moderate_live_chat(text) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_policies
     where schemaname = 'realtime' and tablename = 'messages'
       and policyname = 'live_mod_read'
  ) then
    execute $p$
      create policy live_mod_read on realtime.messages
        for select to authenticated
        using (
          realtime.topic() like 'live_mod:%'
          and can_moderate_live_chat(realtime.topic())
        )
    $p$;
  end if;
end $$;

-- Has [p_user] ever chatted in any of [p_host]'s shows? (Messages are kept 30
-- days, so "ever" means "lately" — good enough to say hello to a new face.)
create or replace function public.live_chat_has_chatted(p_host uuid, p_user uuid)
returns boolean
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select exists (
    select 1
      from public.live_chat_messages m
      join public.events e on e.id = m.event_id
     where m.sender_id = p_user and e.host_id = p_host
  );
$function$;

revoke all on function public.live_chat_has_chatted(uuid, uuid) from public, anon, authenticated;
grant execute on function public.live_chat_has_chatted(uuid, uuid) to service_role;
