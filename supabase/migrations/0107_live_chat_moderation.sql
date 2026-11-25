-- 0107 — live chat moderation, phase 1: the server-side record.
--
-- P1 #16. Live chat today is a raw Realtime broadcast: nothing is stored,
-- nothing is rate limited, and the host's only lever (camera_screen's
-- `_blockedSenders` set) hides the troll from the host alone while every other
-- viewer keeps seeing them — arguably worse than doing nothing, because the
-- host believes they acted.
--
-- Nothing else in the moderation plan is possible while messages exist only in
-- flight, so this is the foundation: a message record that can be deleted or
-- attached to a report, a ban list, and a rate limiter that lives in Postgres
-- rather than in the memory of an edge function that scales horizontally.
--
-- Product decisions this encodes (agreed 2026-08-17):
--   Retention   30 days, then the nightly purge at the bottom of this file.
--   Ban scope   per-event, issued by the host, permanent for that event.
--   Moderators  host only — the edge function gates on the host check.
--   Removal     silent. No tombstone: a "message removed" placeholder is a
--               trophy. `removed_at` keeps the evidence for a report while the
--               audience simply stops seeing the line.
--
-- Authorization for *joining* a chat is untouched here — that is
-- `can_join_live_chat` plus the realtime.messages policies, committed as 0104.
--
-- PREREQUISITE: supabase functions deploy live-chat   (verify-jwt ON)

-- ── Messages ────────────────────────────────────────────────────────────────
-- A moderation record, not a transcript feature. Viewers still receive chat
-- over broadcast and someone arriving late still sees nothing that came before
-- them; this table exists so a message can be removed after the fact, reported
-- with its actual text as evidence, and used to ban its author.
create table if not exists public.live_chat_messages (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.events(id)   on delete cascade,
  sender_id   uuid not null references public.profiles(id) on delete cascade,
  body        text not null,
  created_at  timestamptz not null default now(),
  removed_at  timestamptz,
  removed_by  uuid references public.profiles(id) on delete set null
);

-- The host's moderation view reads one event, newest first.
create index if not exists live_chat_messages_event_created_idx
  on public.live_chat_messages (event_id, created_at desc);

-- A ban sweeps every message that sender still has standing in the room.
create index if not exists live_chat_messages_event_sender_idx
  on public.live_chat_messages (event_id, sender_id)
  where removed_at is null;

alter table public.live_chat_messages enable row level security;

-- Writes are service-role only (the `live-chat` function), so there is no
-- insert or update policy at all. Reads are for the people who moderate: the
-- event's host and platform admins. Viewers never read this table.
--
-- auth.uid() and is_admin() are wrapped in scalar subqueries so the planner
-- evaluates them once per statement instead of once per row (0054's lesson).
drop policy if exists "live_chat_messages: host or admin read" on public.live_chat_messages;
create policy "live_chat_messages: host or admin read"
  on public.live_chat_messages for select to authenticated
  using (
    (select is_admin())
    or exists (
      select 1 from public.events e
       where e.id = live_chat_messages.event_id
         and e.host_id = (select auth.uid())
    )
  );

-- ── Bans ────────────────────────────────────────────────────────────────────
-- Per-event and permanent for that event. Account-wide banning is a platform
-- decision that belongs with the admin console, not in a host's hands, and a
-- timed ban is complexity nobody will use on a show that runs a few hours.
create table if not exists public.live_chat_bans (
  event_id   uuid not null references public.events(id)   on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  banned_by  uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

alter table public.live_chat_bans enable row level security;

drop policy if exists "live_chat_bans: host or admin read" on public.live_chat_bans;
create policy "live_chat_bans: host or admin read"
  on public.live_chat_bans for select to authenticated
  using (
    (select is_admin())
    or exists (
      select 1 from public.events e
       where e.id = live_chat_bans.event_id
         and e.host_id = (select auth.uid())
    )
  );

-- ── Rate limit ──────────────────────────────────────────────────────────────
-- Token bucket, one row per (event, sender). Deliberately in Postgres and not
-- in the edge function: Deno isolates scale horizontally and are recycled, so
-- an in-memory limiter would reset itself under exactly the load it exists for.
--
-- No foreign keys on purpose — this is per-show scratch bookkeeping, not a
-- record, and the nightly purge below is what cleans it up.
create table if not exists public.live_chat_rate_limit (
  event_id   uuid not null,
  user_id    uuid not null,
  tokens     double precision not null,
  updated_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

alter table public.live_chat_rate_limit enable row level security;
-- No policies at all: service role only.

-- Spend one token, refilling lazily for the time since the last message.
-- 5 messages per 10 seconds sustained (0.5/s), burst 10 — enough for someone
-- typing fast in a good moment, not enough to paper the room.
--
-- The ON CONFLICT DO UPDATE takes a row lock, so two concurrent sends from the
-- same person serialize here rather than both reading a stale balance.
create or replace function public.consume_live_chat_token(
  p_event_id          uuid,
  p_user_id           uuid,
  p_capacity          double precision default 10,
  p_refill_per_second double precision default 0.5
)
returns boolean
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tokens double precision;
begin
  insert into public.live_chat_rate_limit (event_id, user_id, tokens, updated_at)
  values (p_event_id, p_user_id, p_capacity - 1, now())
  on conflict (event_id, user_id) do update
     set tokens = least(
           p_capacity,
           live_chat_rate_limit.tokens
             + extract(epoch from (now() - live_chat_rate_limit.updated_at))
               * p_refill_per_second
         ) - 1,
         updated_at = now()
  returning tokens into v_tokens;

  -- Empty bucket. Refuse, and hand the token back so a refused message does
  -- not dig the hole deeper — otherwise someone hammering send extends their
  -- own timeout every time they try.
  if v_tokens < 0 then
    update public.live_chat_rate_limit
       set tokens = 0
     where event_id = p_event_id and user_id = p_user_id;
    return false;
  end if;

  return true;
end;
$function$;

-- ── Retention ───────────────────────────────────────────────────────────────
-- 30 days: long enough to investigate a report filed days after a show, short
-- enough that Nile is not quietly accumulating a permanent chat archive.
create or replace function public.purge_expired_live_chat(p_retention_days integer default 30)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_count integer;
begin
  with purged as (
    delete from public.live_chat_messages
     where created_at < now() - make_interval(days => p_retention_days)
    returning id
  )
  select count(*) into v_count from purged;

  -- A bucket untouched for a day is long since refilled and cannot be holding
  -- anyone back; keeping it only costs pages to scan.
  delete from public.live_chat_rate_limit
   where updated_at < now() - interval '1 day';

  return v_count;
end;
$function$;

-- 0100's rule: revoking from anon and authenticated alone is a no-op while
-- PUBLIC still carries the grant.
revoke all on function public.consume_live_chat_token(uuid, uuid, double precision, double precision)
  from public, anon, authenticated;
grant execute on function public.consume_live_chat_token(uuid, uuid, double precision, double precision)
  to service_role;

revoke all on function public.purge_expired_live_chat(integer) from public, anon, authenticated;
grant execute on function public.purge_expired_live_chat(integer) to service_role;

-- ── Purge cron ──────────────────────────────────────────────────────────────
-- Same shape as purge-expired-currents (0071), fifteen minutes after it so the
-- two nightly deletes are not competing for the same window.
-- cron.schedule() on an existing jobname updates it in place.
select cron.schedule(
  'purge-expired-live-chat',
  '35 4 * * *',
  $cron$ select public.purge_expired_live_chat(30); $cron$
);
