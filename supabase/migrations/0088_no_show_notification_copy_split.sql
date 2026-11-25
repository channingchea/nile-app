-- 0088 — B3 part 2 from the 2026-08-11 event lifecycle review.
--
-- notify_event_status_change had no started_at condition, so an event that was
-- auto-ended without ever going live pushed "the event has ended" to everyone
-- holding a ticket. One of those is already in production: a $15 ticket on
-- "Warehouse Session 12", whose owner was told it ended while started_at is null.
-- Migration 0084 made that transition routine, so this would have become the
-- common case rather than the rare one.
--
-- Split on started_at: a show that actually ran gets 'event_ended', one that
-- never started gets 'event_no_show'. Copy lives in send-push (push) and
-- notification_service.dart / notifications_screen.dart (in-app row); both ship
-- alongside this.

create or replace function public.notify_event_status_change()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
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
  end if;
  return new;
end;
$function$;
