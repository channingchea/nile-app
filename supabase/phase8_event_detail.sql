-- Phase 8: Event Detail & Scheduled Stream Experience
-- Run this in the Supabase SQL Editor

-- Optional scheduled-at time for events that haven't gone live yet.
alter table events
  add column if not exists scheduled_at timestamptz;

-- Helpful index for "upcoming events" queries down the line.
create index if not exists events_scheduled_idx
  on events (status, scheduled_at)
  where status = 'scheduled';
