-- 0149: share-link guests wait for the host (docs/plans/studio-modes.md).
--
-- A share link is a bearer credential: anyone it's forwarded to could join the
-- green room and watch a paid show free. guest-join now adds new people as
-- 'requested'; guest-token refuses them until the host lets them in from the
-- Studio's green room (admit-guest → 'invited') or declines ('removed').

alter table public.event_guests
  drop constraint event_guests_status_check,
  add constraint event_guests_status_check
    check (status in ('requested', 'invited', 'green_room', 'on_stage', 'removed'));

-- Hardening (review, 2026-11-02): RLS doesn't cover TRUNCATE, so client roles
-- keep only the grants the API actually uses.
revoke truncate, references, trigger on public.event_guests, public.event_host_notes from anon, authenticated;
