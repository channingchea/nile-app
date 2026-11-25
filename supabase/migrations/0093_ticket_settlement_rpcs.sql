-- 0093 — the RPCs the webhook uses to settle a checkout (B6, B7, B8), plus
-- capacity accounting that only counts the tickets that actually take a seat.

-- tickets_remaining counted every paid row, including replay purchases, which
-- do not occupy a seat at the live show.
create or replace function public.tickets_remaining(p_event_id uuid)
returns integer
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select
    case
      when e.ticket_limit is null then null          -- unlimited
      else greatest(0, e.ticket_limit - (
        select count(*)::int from tickets t
         where t.event_id = e.id and t.status = 'paid' and t.kind = 'live'
      ))
    end
  from events e
  where e.id = p_event_id;
$function$;

-- Settle one checkout. Returns the outcome so the webhook can act on it:
--   'paid'      — entitlement granted
--   'already'   — replay of a Stripe event we already settled
--   'oversold'  — capacity was gone by the time the money landed; REFUND IT
--   'not_found' — no ledger row for this session
--
-- The capacity re-check is the point: it takes a row lock on the event, so two
-- buyers racing for the last seat serialize here instead of both winning.
create or replace function public.settle_ticket_checkout(
  p_session_id text,
  p_payment_intent_id text
)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  c          public.ticket_checkouts%rowtype;
  v_limit    integer;
  v_taken    integer;
begin
  select * into c from ticket_checkouts where session_id = p_session_id for update;
  if not found then
    return 'not_found';
  end if;
  if c.status = 'paid' then
    return 'already';
  end if;

  -- Lock the event so concurrent settlements can't both read the same count.
  select ticket_limit into v_limit from events where id = c.event_id for update;

  -- Only a live ticket takes a seat; a replay purchase never does.
  if c.kind = 'live' and v_limit is not null then
    select count(*) into v_taken
      from tickets
     where event_id = c.event_id and status = 'paid' and kind = 'live'
       and buyer_id <> c.buyer_id;   -- this buyer re-buying isn't a new seat
    if v_taken >= v_limit then
      update ticket_checkouts
         set status = 'oversold',
             payment_intent_id = coalesce(p_payment_intent_id, payment_intent_id),
             settled_at = now(),
             note = 'sold out before the payment landed — refunded'
       where id = c.id;
      return 'oversold';
    end if;
  end if;

  update ticket_checkouts
     set status = 'paid',
         payment_intent_id = coalesce(p_payment_intent_id, payment_intent_id),
         settled_at = now()
   where id = c.id;

  -- The entitlement row. Upserting on (event_id, buyer_id) is still right —
  -- it IS one entitlement per buyer per event — now that the money history
  -- lives in the ledger instead of being overwritten here.
  insert into tickets (event_id, buyer_id, stripe_payment_intent_id, amount_cents,
                       status, kind, split_status, application_fee_cents)
  values (c.event_id, c.buyer_id, coalesce(p_payment_intent_id, c.session_id),
          c.amount_cents, 'paid', c.kind, c.split_status, c.application_fee_cents)
  on conflict (event_id, buyer_id) do update
     set stripe_payment_intent_id = excluded.stripe_payment_intent_id,
         amount_cents             = excluded.amount_cents,
         status                   = 'paid',
         kind                     = excluded.kind,
         split_status             = excluded.split_status,
         application_fee_cents    = excluded.application_fee_cents;

  return 'paid';
end;
$function$;

-- Mark a refund in both places. Called only for FULL refunds (the webhook keeps
-- the partial-refund guard from B5).
create or replace function public.refund_ticket_checkout(p_payment_intent_id text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  update ticket_checkouts
     set status = 'refunded', settled_at = now()
   where payment_intent_id = p_payment_intent_id
     and status = 'paid';

  update tickets
     set status = 'refunded'
   where stripe_payment_intent_id = p_payment_intent_id;
end;
$function$;

revoke execute on function public.settle_ticket_checkout(text, text) from anon, authenticated;
revoke execute on function public.refund_ticket_checkout(text) from anon, authenticated;
