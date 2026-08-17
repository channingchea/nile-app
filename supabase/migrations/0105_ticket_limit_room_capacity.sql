-- 0105 — stop an event selling more seats than the room can hold.
--
-- P1 #10. A LiveKit room caps at 1050 participants. events.ticket_limit had no
-- upper bound at all — no CHECK here, and a client-side validator that only
-- rejected values <= 0 — so a host could put 2,000 on sale. Everything would
-- look fine right up to showtime, when viewer 1051 would receive a perfectly
-- valid token and then be refused at the door by LiveKit, with no refund path
-- and no message that made any sense to them.
--
-- 1000, not 1050: the host, every camera operator, a Stream Audio operator and
-- the egress recorder all occupy participant slots. The 50 left over is the
-- crew headroom the livekit function reserves (CREW_HEADROOM), and it is what
-- that function sizes each room's maxParticipants from.
--
-- Safe to apply as a validating constraint: checked on prod 2026-08-17, no row
-- has a non-null ticket_limit, so nothing existing can violate it.

alter table public.events
  drop constraint if exists events_ticket_limit_within_room_capacity;

alter table public.events
  add constraint events_ticket_limit_within_room_capacity
  check (ticket_limit is null or (ticket_limit > 0 and ticket_limit <= 1000));

comment on constraint events_ticket_limit_within_room_capacity on public.events is
  'A LiveKit room holds 1050; 50 slots are reserved for crew and the recorder, '
  'so 1000 is the most viewers an event can admit. Keep in step with '
  'MAX_VIEWERS in supabase/functions/livekit/index.ts and the create-event form.';
