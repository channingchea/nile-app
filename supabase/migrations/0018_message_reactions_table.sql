-- ── DM message reactions ────────────────────────────────────────────────────
-- One reaction per (message, user): tapping a new emoji replaces the old one,
-- re-tapping the same emoji toggles it off (client deletes the row). The schema
-- is future-proofed for group DMs (a row per user, not a single column on the
-- message). conversation_id is denormalized so realtime can filter by it,
-- matching the messages channel (message_reactions itself has no FK path that
-- realtime filters can traverse).
--
-- Parts 2 (enum) and 3 (pref + trigger) live in 0019 / 0020, mirroring the
-- new_message split (0013/0014): a new enum label can't be referenced in the
-- same transaction that adds it.

create table if not exists public.message_reactions (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.messages(id) on delete cascade,
  -- Denormalized from the parent message for realtime filtering (see above).
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  emoji text not null check (char_length(emoji) between 1 and 16),
  created_at timestamptz not null default now(),
  unique (message_id, user_id)            -- one reaction per user per message
);

create index if not exists message_reactions_message_id_idx
  on public.message_reactions (message_id);
create index if not exists message_reactions_conversation_id_idx
  on public.message_reactions (conversation_id);

alter table public.message_reactions enable row level security;

-- Read: any participant of the parent conversation.
drop policy if exists "reactions_select" on public.message_reactions;
create policy "reactions_select" on public.message_reactions
  for select using (
    exists (
      select 1 from public.conversations c
      where c.id = conversation_id
        and auth.uid() in (c.participant_a, c.participant_b)
    )
  );

-- Insert: only your own rows, and only in conversations you're a participant of.
-- The message_id must also belong to the same conversation (guards spoofing a
-- conversation_id you're in onto a message you can't see).
drop policy if exists "reactions_insert" on public.message_reactions;
create policy "reactions_insert" on public.message_reactions
  for insert with check (
    user_id = auth.uid()
    and exists (
      select 1 from public.messages m
      join public.conversations c on c.id = m.conversation_id
      where m.id = message_id
        and m.conversation_id = conversation_id
        and auth.uid() in (c.participant_a, c.participant_b)
    )
  );

-- Update / delete: only your own rows.
drop policy if exists "reactions_update" on public.message_reactions;
create policy "reactions_update" on public.message_reactions
  for update using (user_id = auth.uid());

drop policy if exists "reactions_delete" on public.message_reactions;
create policy "reactions_delete" on public.message_reactions
  for delete using (user_id = auth.uid());

-- Realtime: emit row changes so the conversation screen can patch chips live.
alter publication supabase_realtime add table public.message_reactions;

-- REPLICA IDENTITY FULL so DELETE payloads carry the full old row (message_id +
-- conversation_id). Without it, deletes carry only the PK, the conversation_id
-- realtime filter can't apply to deletes, and the client can't tell which
-- message to reconcile on a toggle-off.
alter table public.message_reactions replica identity full;
