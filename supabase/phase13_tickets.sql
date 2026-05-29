-- Phase 13: Event Ticketing
-- Run in Supabase SQL Editor

-- ── Tickets table ─────────────────────────────────────────────────────────────
-- Drop any pre-existing tickets table (different schema from a prior attempt).
drop table if exists tickets cascade;

create table tickets (
  id                       uuid        primary key default gen_random_uuid(),
  event_id                 uuid        not null references events(id) on delete cascade,
  buyer_id                 uuid        not null references profiles(id) on delete cascade,
  stripe_payment_intent_id text        not null unique,
  amount_cents             int         not null check (amount_cents > 0),
  status                   text        not null default 'pending'
                                       check (status in ('pending', 'paid', 'refunded')),
  created_at               timestamptz not null default now(),

  -- One ticket per buyer per event
  unique (event_id, buyer_id)
);

alter table tickets enable row level security;

-- Buyers can read/insert their own tickets
create policy "tickets_select_own" on tickets
  for select using (buyer_id = auth.uid());

create policy "tickets_insert_own" on tickets
  for insert with check (buyer_id = auth.uid());

-- Hosts can read tickets for their events (for attendee lists)
create policy "tickets_select_host" on tickets
  for select using (
    exists (
      select 1 from events
      where events.id = tickets.event_id
        and events.host_id = auth.uid()
    )
  );

-- Index for fast "do I have a ticket?" lookups
create index if not exists tickets_buyer_event_idx
  on tickets (buyer_id, event_id);

create index if not exists tickets_event_paid_idx
  on tickets (event_id, status)
  where status = 'paid';

-- ── Availability helper ───────────────────────────────────────────────────────

-- Returns remaining ticket capacity: null = unlimited, 0 = sold out, N = available
create or replace function tickets_remaining(p_event_id uuid)
returns int
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    case
      when e.ticket_limit is null then null          -- free/unlimited
      else greatest(0, e.ticket_limit - count(t.id)::int)
    end
  from events e
  left join tickets t
    on t.event_id = e.id and t.status = 'paid'
  where e.id = p_event_id
  group by e.ticket_limit;
$$;

-- ── Edge Function: confirm ticket after Stripe webhook ────────────────────────
-- Called by the Edge Function (service role) once Stripe confirms payment.
-- Using security definer so the edge function can update any ticket.

create or replace function confirm_ticket(
  p_payment_intent_id text,
  p_status            text  -- 'paid' or 'refunded'
)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update tickets
  set status = p_status
  where stripe_payment_intent_id = p_payment_intent_id;
$$;
