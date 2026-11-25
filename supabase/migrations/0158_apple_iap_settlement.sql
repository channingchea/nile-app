-- 0158 Apple IAP settlement fixes (follows 0157).
--
-- One entitlement row per (event, buyer) means a buyer can open a card
-- checkout and an Apple purchase for the same show. Whichever is PAID first
-- decides what the row says; the other one is a duplicate (Apple: the app
-- points the buyer at Apple's refund form; card: refundable as today).
--
-- 1. settle_apple_ticket claims the row for Apple even if a later card
--    checkout re-touched the pending row, and freezes the host's share at the
--    moment of purchase from the current revenue split.
-- 2. settle_ticket_checkout (card) resets the Apple-only columns, so a row
--    that was pending as Apple and then paid by card reads as a card sale.

create or replace function public.settle_apple_ticket(
  p_ticket_id uuid,
  p_transaction_id text,
  p_original_transaction_id text,
  p_store_price_cents integer,
  p_environment text
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  t       public.tickets%rowtype;
  v_share numeric;
  v_host  integer;
begin
  if exists (select 1 from tickets where apple_transaction_id = p_transaction_id) then
    return 'already';
  end if;

  select * into t from tickets where id = p_ticket_id for update;
  if not found then
    return 'not_found';
  end if;
  if t.status = 'paid' then
    return 'duplicate';
  end if;

  select creator_revenue_share into v_share from app_config where id = 1;
  v_host := floor(t.amount_cents * coalesce(v_share, 0.5))::int;

  update tickets
     set status = 'paid',
         payment_provider = 'apple',
         split_status = 'apple',
         apple_transaction_id = p_transaction_id,
         apple_original_transaction_id = p_original_transaction_id,
         apple_environment = p_environment,
         store_price_cents = p_store_price_cents,
         host_share_cents = v_host,
         application_fee_cents = t.amount_cents - v_host,
         stripe_payment_intent_id = 'apple:' || p_transaction_id,
         paid_at = now(),
         refunded_at = null
   where id = t.id;
  return 'paid';
end;
$$;

revoke execute on function public.settle_apple_ticket(uuid, text, text, integer, text) from public, anon, authenticated;

create or replace function public.settle_ticket_checkout(p_session_id text, p_payment_intent_id text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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

  select ticket_limit into v_limit from events where id = c.event_id for update;

  -- Already bought through Apple while this card checkout was open: refund the
  -- card (the webhook refunds on 'oversold') rather than overwrite the Apple sale.
  if exists (select 1 from tickets
              where event_id = c.event_id and buyer_id = c.buyer_id
                and status = 'paid' and payment_provider = 'apple') then
    update ticket_checkouts
       set status = 'oversold',
           payment_intent_id = coalesce(p_payment_intent_id, payment_intent_id),
           settled_at = now(),
           note = 'already bought through the app store — refunded'
     where id = c.id;
    return 'oversold';
  end if;

  if c.kind = 'live' and v_limit is not null then
    select count(*) into v_taken
      from tickets
     where event_id = c.event_id and status = 'paid' and kind = 'live'
       and buyer_id <> c.buyer_id;
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

  insert into tickets (event_id, buyer_id, stripe_payment_intent_id, amount_cents,
                       status, kind, split_status, application_fee_cents,
                       payment_provider, paid_at)
  values (c.event_id, c.buyer_id, coalesce(p_payment_intent_id, c.session_id),
          c.amount_cents, 'paid', c.kind, c.split_status, c.application_fee_cents,
          'stripe', now())
  on conflict (event_id, buyer_id) do update
     set stripe_payment_intent_id = excluded.stripe_payment_intent_id,
         amount_cents             = excluded.amount_cents,
         status                   = 'paid',
         kind                     = excluded.kind,
         split_status             = excluded.split_status,
         application_fee_cents    = excluded.application_fee_cents,
         payment_provider         = 'stripe',
         store_price_cents        = null,
         host_share_cents         = null,
         paid_at                  = now(),
         refunded_at              = null;

  return 'paid';
end;
$$;

revoke execute on function public.settle_ticket_checkout(text, text) from public, anon, authenticated;
