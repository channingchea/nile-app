-- 0110 — chat word filter + the host's chat controls (#16 phases 4 and 5).
--
-- Phase 4 is the wordlist. Phase 5 is the three knobs a host turns on their own
-- show: let the crew moderate, slow the room down, or restrict who may speak.
--
-- ⚠️ DELIBERATE DEVIATION from the plan, which said to keep the wordlist in
-- `app_config`. app_config carries `create policy app_config_read ... using
-- (true)` and an explicit `grant select ... to anon` (0041, 0078) — it is
-- world-readable by design, because the force-update gate has to work before
-- anyone signs in. Putting a harassment wordlist there publishes it to every
-- anonymous client, which is a map around itself. It gets its own table with
-- no client access instead. The plan's actual requirement — tune it without a
-- deploy — is met either way.

-- ── The wordlist ────────────────────────────────────────────────────────────
-- Tuned from the Supabase dashboard; no deploy, no app release.
create table if not exists public.chat_blocked_words (
  word       text primary key,
  note       text,
  created_at timestamptz not null default now()
);

alter table public.chat_blocked_words enable row level security;
-- No policies: service role only. Admins read it in the dashboard, which
-- bypasses RLS; nothing in the app or the portal ever needs it.

-- Does [p_text] hit the list? Returns the matched entry, or null.
--
-- Runs in the database so the list never crosses the wire — the edge function
-- asks "did this hit?" and is told a word, not the whole blocklist.
--
-- Single words match on token boundaries, not substrings: the substring test is
-- what gives you the Scunthorpe problem, where an innocent word containing a
-- banned one is refused and the sender has no idea why. Entries containing a
-- space are treated as phrases and matched as plain substrings — `position`,
-- not `like`, so an entry with a % or _ in it can't behave as a wildcard.
create or replace function public.live_chat_filter_hit(p_text text)
returns text
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  with tokens as (
    select unnest(regexp_split_to_array(lower(p_text), '[^[:alnum:]'']+')) as t
  )
  select w.word
    from public.chat_blocked_words w
   where (position(' ' in w.word) = 0 and lower(w.word) in (select t from tokens))
      or (position(' ' in w.word) > 0
          and position(lower(w.word) in lower(p_text)) > 0)
   -- Longest match first, so the log records the specific phrase rather than
   -- whichever single word inside it happened to sort first.
   order by length(w.word) desc
   limit 1;
$function$;

revoke all on function public.live_chat_filter_hit(text) from public, anon, authenticated;
grant execute on function public.live_chat_filter_hit(text) to service_role;

-- ── Filter hits, for tuning ─────────────────────────────────────────────────
-- The word that matched and who tripped it — NOT the message. A wordlist is
-- only as good as the tuning data, and the tuning question is "which entries
-- fire, and do they fire on real abuse or on ordinary sentences?". Keeping the
-- rejected text to answer that would mean storing the messages we refused to
-- store, which is the opposite of the point.
create table if not exists public.live_chat_filter_hits (
  id         bigint generated always as identity primary key,
  event_id   uuid not null references public.events(id)   on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  matched    text not null,
  created_at timestamptz not null default now()
);

create index if not exists live_chat_filter_hits_matched_idx
  on public.live_chat_filter_hits (matched, created_at desc);

alter table public.live_chat_filter_hits enable row level security;

drop policy if exists "live_chat_filter_hits: admin read" on public.live_chat_filter_hits;
create policy "live_chat_filter_hits: admin read"
  on public.live_chat_filter_hits for select to authenticated
  using ((select is_admin()));

-- ── Host chat controls ──────────────────────────────────────────────────────
alter table public.events
  -- Phase 5. Off by default, which keeps the v1 decision ("host only") intact:
  -- a host opts their crew in per show rather than the platform deciding for
  -- everyone. The gate widens from host to `event_operators` when this is true.
  add column if not exists chat_crew_moderation boolean not null default false,
  -- Seconds each viewer must wait between messages. 0 = off. Capped at 5
  -- minutes: past that it isn't slow mode, it's a closed chat, and there are
  -- two better ways to say that below.
  add column if not exists chat_slow_mode_seconds integer not null default 0
    check (chat_slow_mode_seconds >= 0 and chat_slow_mode_seconds <= 300),
  -- Who may SPEAK. Reading is unchanged and stays governed by
  -- can_join_live_chat + the realtime.messages policies (0104) — a follower
  -- gate that also hid the conversation would make a quiet room look broken.
  add column if not exists chat_access text not null default 'everyone'
    check (chat_access in ('everyone', 'followers', 'ticket_holders'));

-- 'ticket_holders' on a free event would mean nobody but crew can chat, because
-- free events create no ticket rows at all (the same fact that made
-- events.ticket_limit a no-op until #10). Refuse the combination rather than
-- ship a setting that silently mutes the whole room.
alter table public.events drop constraint if exists events_chat_access_needs_price;
alter table public.events add constraint events_chat_access_needs_price
  check (chat_access <> 'ticket_holders' or coalesce(price, 0) > 0);

-- ── Retention ───────────────────────────────────────────────────────────────
-- Fold the filter-hit log into the nightly purge on the same 30-day clock.
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

  delete from public.live_chat_filter_hits
   where created_at < now() - make_interval(days => p_retention_days);

  -- A bucket untouched for a day is long since refilled and cannot be holding
  -- anyone back; keeping it only costs pages to scan.
  delete from public.live_chat_rate_limit
   where updated_at < now() - interval '1 day';

  return v_count;
end;
$function$;

revoke all on function public.purge_expired_live_chat(integer) from public, anon, authenticated;
grant execute on function public.purge_expired_live_chat(integer) to service_role;
