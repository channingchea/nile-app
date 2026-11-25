-- 0159 Apple IAP Phase 4 — cancelled shows (docs/plans/apple-iap-tickets.md).
--
-- 1. Ticket holders hear when a show is cancelled (new `event_cancelled`
--    notification → push). App store buyers then find a "Request refund"
--    button on the ticket in My Tickets; card buyers keep today's flow.
-- 2. An event with app store sales can't be deleted: the cascade would erase
--    the tickets that Apple's refunds and the host's month-end payout are
--    matched against. Hosts cancel it instead.

alter type public.notification_type add value if not exists 'event_cancelled';

create or replace function public.notify_event_status_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'live' and old.status is distinct from 'live' then
    perform fanout_event_notification(new.id, 'event_live', 'followers_and_tickets');
  elsif new.status = 'ended' and old.status is distinct from 'ended' then
    -- started_at is only ever stamped by go-live, so a null here means the show
    -- never happened. Telling a ticket holder it "ended" is both wrong and the
    -- opposite of the signal they need (their money is still with the host).
    perform fanout_event_notification(
      new.id,
      case when new.started_at is null then 'event_no_show'::notification_type
           else 'event_ended'::notification_type end,
      'tickets'
    );
  elsif new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    perform fanout_event_notification(new.id, 'event_cancelled'::notification_type, 'tickets');
  end if;
  return new;
end;
$$;

create or replace function public.protect_store_sales_on_event_delete()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Host-initiated deletes only (they come through RLS with a user id). The
  -- service role — account deletion, admin cleanup — still goes through.
  if (select auth.uid()) is not null and exists (select 1 from tickets
              where event_id = old.id and payment_provider = 'apple'
                and status in ('paid', 'refunded')) then
    raise exception 'event_has_store_sales'
      using errcode = 'check_violation',
            hint = 'This event has app store sales. Cancel it instead of deleting it.';
  end if;
  return old;
end;
$$;

create trigger trg_protect_store_sales_on_event_delete
  before delete on public.events
  for each row execute function public.protect_store_sales_on_event_delete();
