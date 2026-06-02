-- ── Direct Messages ──────────────────────────────────────────────────────────
-- conversations: one row per unique pair of participants.
-- messages: individual messages belonging to a conversation.

-- conversations ---------------------------------------------------------------
create table if not exists public.conversations (
  id            uuid primary key default gen_random_uuid(),
  participant_a uuid not null references public.profiles(id) on delete cascade,
  participant_b uuid not null references public.profiles(id) on delete cascade,
  last_message_at timestamptz,
  created_at    timestamptz not null default now(),
  -- Ensure the pair is unique regardless of order (a < b always).
  constraint conversations_ordered check (participant_a < participant_b),
  constraint conversations_unique_pair unique (participant_a, participant_b)
);

create index if not exists conversations_participant_a_idx on public.conversations(participant_a);
create index if not exists conversations_participant_b_idx on public.conversations(participant_b);
create index if not exists conversations_last_message_idx  on public.conversations(last_message_at desc nulls last);

-- messages --------------------------------------------------------------------
create table if not exists public.messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id       uuid not null references public.profiles(id) on delete cascade,
  content         text not null check (char_length(content) between 1 and 1000),
  read_at         timestamptz,
  created_at      timestamptz not null default now()
);

create index if not exists messages_conversation_idx on public.messages(conversation_id, created_at desc);
create index if not exists messages_sender_idx        on public.messages(sender_id);

-- Trigger: keep last_message_at current on conversations ---------------------
create or replace function public.update_conversation_last_message()
returns trigger language plpgsql as $$
begin
  update public.conversations
  set last_message_at = new.created_at
  where id = new.conversation_id;
  return new;
end;
$$;

drop trigger if exists trg_update_last_message on public.messages;
create trigger trg_update_last_message
  after insert on public.messages
  for each row execute procedure public.update_conversation_last_message();

-- RLS -------------------------------------------------------------------------
alter table public.conversations enable row level security;
alter table public.messages       enable row level security;

-- A user can see only conversations they are part of.
create policy "conversations_select" on public.conversations
  for select using (
    auth.uid() = participant_a or auth.uid() = participant_b
  );

-- A user can insert a conversation only if they are one of the participants.
create policy "conversations_insert" on public.conversations
  for insert with check (
    auth.uid() = participant_a or auth.uid() = participant_b
  );

-- A user can see messages only in conversations they belong to.
create policy "messages_select" on public.messages
  for select using (
    exists (
      select 1 from public.conversations c
      where c.id = conversation_id
        and (c.participant_a = auth.uid() or c.participant_b = auth.uid())
    )
  );

-- A user can only send messages as themselves.
create policy "messages_insert" on public.messages
  for insert with check (
    sender_id = auth.uid()
    and exists (
      select 1 from public.conversations c
      where c.id = conversation_id
        and (c.participant_a = auth.uid() or c.participant_b = auth.uid())
    )
  );

-- Only the recipient can mark a message read (sender_id != auth.uid()).
create policy "messages_update_read_at" on public.messages
  for update using (sender_id != auth.uid())
  with check (sender_id != auth.uid());

-- Realtime --------------------------------------------------------------------
alter publication supabase_realtime add table public.messages;
