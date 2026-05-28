-- Phase 4: Events table
-- Run this in the Supabase SQL Editor

create table if not exists events (
  id               uuid        primary key default gen_random_uuid(),
  host_id          uuid        not null references profiles(id) on delete cascade,
  title            text        not null,
  description      text,
  livekit_event_id text        not null unique,
  status           text        not null default 'scheduled'
                               check (status in ('scheduled', 'live', 'ended')),
  viewer_count     int         not null default 0,
  started_at       timestamptz,
  ended_at         timestamptz,
  created_at       timestamptz not null default now()
);

alter table events enable row level security;

create policy "events_select_all" on events
  for select using (true);

create policy "events_insert_own" on events
  for insert with check (host_id = auth.uid());

create policy "events_update_own" on events
  for update using (host_id = auth.uid());

create policy "events_delete_own" on events
  for delete using (host_id = auth.uid());

-- Index for feed query performance
create index if not exists events_host_status_idx
  on events (host_id, status, created_at desc);
