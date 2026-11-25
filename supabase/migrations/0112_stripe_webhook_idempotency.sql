-- 0112 — P2 #19 from the 2026-08-16 platform review: Stripe webhook idempotency.
--
-- Stripe guarantees at-LEAST-once delivery. The webhook had no event dedupe of
-- any kind, so every handler was relying on its own status guard to survive a
-- replay. Most do. One does not, and it moves money:
--
--   onSponsorshipPaymentRecovered guards on status='payment_pending'. When the
--   guard matches nothing it concludes the lobby slot is gone and issues
--   refunds.create({ reverse_transfer: true }). On a redelivery, delivery #1
--   sets the campaign 'active' and delivery #2 finds no payment_pending row —
--   so it refunds a LIVE sponsorship and claws back the host's transfer while
--   the sponsor keeps serving in the lobby. Nothing surfaces it.
--
-- Dedupe on Stripe's event.id, which is stable across every redelivery of the
-- same event. Claim before doing any work, mark processed after.
--
-- Why a claim/complete pair rather than a plain "insert and skip if present":
-- the ticket branch deliberately returns 500 so Stripe retries when settlement
-- fails (the buyer has paid and holds no ticket until it succeeds). A one-shot
-- dedupe would swallow that retry and strand the buyer. So an unfinished claim
-- is retryable, and only a COMPLETED event is treated as a duplicate.

create table if not exists public.stripe_webhook_events (
  event_id     text primary key,
  type         text not null,
  claimed_at   timestamptz not null default now(),
  processed_at timestamptz,
  attempts     integer not null default 1
);

create index if not exists stripe_webhook_events_unfinished_idx
  on public.stripe_webhook_events (claimed_at) where processed_at is null;

-- Written only by the service role, from the webhook. No policies at all, which
-- with RLS on means no client can read it either.
alter table public.stripe_webhook_events enable row level security;

-- Claim an event for processing. Returns one of:
--   'claimed'   — go ahead and handle it (first delivery, or a dead claim)
--   'duplicate' — already handled to completion; ack with 200 and do nothing
--   'in_flight' — another delivery of this same event is being processed right
--                 now; return 5xx so Stripe redelivers instead of dropping it
--
-- The 5-minute reclaim window is the crash story: an instance that dies
-- mid-handler leaves a claim with processed_at null forever, and without a
-- reclaim that event could never be processed by anyone. Five minutes is well
-- past the 150s edge-function wall clock, so a claim that old is dead, not slow.
create or replace function public.claim_stripe_webhook_event(
  p_event_id text,
  p_type     text
)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v public.stripe_webhook_events%rowtype;
begin
  insert into stripe_webhook_events (event_id, type)
  values (p_event_id, p_type)
  on conflict (event_id) do nothing;

  if found then
    return 'claimed';
  end if;

  -- Someone got there first. Lock the row so two concurrent deliveries can't
  -- both decide the claim is stale and both run the handler.
  select * into v from stripe_webhook_events
   where event_id = p_event_id for update;

  update stripe_webhook_events
     set attempts = attempts + 1,
         claimed_at = case when v.processed_at is null
                            and v.claimed_at < now() - interval '5 minutes'
                           then now() else claimed_at end
   where event_id = p_event_id;

  if v.processed_at is not null then
    return 'duplicate';
  elsif v.claimed_at < now() - interval '5 minutes' then
    return 'claimed';
  else
    return 'in_flight';
  end if;
end;
$function$;

create or replace function public.complete_stripe_webhook_event(p_event_id text)
returns void
language sql
security definer
set search_path to 'public', 'pg_temp'
as $function$
  update stripe_webhook_events
     set processed_at = now()
   where event_id = p_event_id;
$function$;

-- REVOKE FROM public, NOT just anon/authenticated. Postgres grants EXECUTE to
-- PUBLIC on CREATE FUNCTION, so `revoke ... from anon, authenticated` is a
-- no-op — that mistake in 0093/0094 is what left settle_ticket_checkout
-- anon-executable (review finding #1).
revoke execute on function public.claim_stripe_webhook_event(text, text)
  from public, anon, authenticated;
revoke execute on function public.complete_stripe_webhook_event(text)
  from public, anon, authenticated;

-- Keep the ledger bounded. Stripe stops retrying a failed delivery after ~3
-- days, so anything a month old can never be redelivered and has no dedupe
-- value left. Plain SQL — no edge function, so no shared secret needed.
select cron.schedule(
  'purge-stripe-webhook-events',
  '50 4 * * *',
  $job$
  delete from public.stripe_webhook_events
   where claimed_at < now() - interval '30 days';
  $job$
);
