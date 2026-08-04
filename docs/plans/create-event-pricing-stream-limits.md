# Create Event Pricing & Stream Limits — Implementation Plan

*Planned 2026-08-04. Status: approved, not yet implemented.*

## Overview
Free events stay available for single-camera streams only. Multicam (2+ cameras) requires a ticket price at or above a computed break-even floor, with a $1 absolute minimum for any paid event. A payout preview card educates hosts at the point of pricing. Separately: an 8-hour hard cap on stream duration, a crew-only countdown timer for the final 10 minutes with a clean auto-end at zero, and a verification pass guaranteeing free streams get replays exactly like paid ones (existing 30-day retention unchanged).

**Floor formula** (all constants server-side in `app_config`):
`floor = ceil₅₀¢( (stripe_fixed + egress/hr × hours + ingest/cam-hr × cams × hours ÷ assumed_tickets) ÷ (platform_share − stripe_pct) )`, clamped to ≥ $1.

With the live 50/50 split and calculator rates (egress ~$0.27/viewer-hr, ingest $0.40/cam-hr, Stripe 2.9% + 30¢, assumed 10 tickets, everyone watches fully): a 2h 3-cam event floors at **$2.50**, 2h 5-cam at **$3.00**, 8h 5-cam at **$9.00**. Computed per event rather than flat — fair for short streams, protective for long ones.

Design decisions locked with Channing:
- Hard floor (server-enforced), not advisory. No expected-attendance input in the floor — worst case (full watch, 10 tickets) is baked in.
- Payout preview card inline in the create flow (not a standalone calculator page); never expose raw platform costs.
- Camera-count stepper moves to page 1 of the create flow (crew page keeps operator assignment only); rule enforced when page 1 completes.
- Countdown timer visible to all broadcasting crew (host + operators), never viewers.
- At 0:00 the host's device auto-runs the existing End Stream path; server cron stays as backstop.
- Free replays: backend already records/auto-publishes free — treat as guarantee + verify, not new plumbing.

## Non-goals / out of scope
- No change to the 50/50 revenue share, replay pricing, tips, or refund logic
- No change to the 30-day replay retention window
- No per-event actual-cost tracking or exposing platform cost internals to hosts
- Existing published events are grandfathered (rules apply on new inserts and edits only)

## Phase 1 — Server: pricing config, floor, and enforcement (migration 0078)
- Add to `app_config`: `min_ticket_cents` (100), `egress_cents_per_viewer_hour` (27), `ingest_cents_per_cam_hour` (40), `stripe_pct` (0.029), `stripe_fixed_cents` (30), `floor_assumed_tickets` (10), `max_stream_minutes` (480)
- `compute_min_ticket_cents(p_duration_minutes int, p_camera_count int) returns int` — SQL function implementing the formula above, rounding up to the nearest 50¢, never below `min_ticket_cents`
- Trigger on `events` insert/update (firing only when price, camera_count, or end_at change): reject `camera_count > 1` with null/zero price; reject paid price below the computed floor; reject duration (`end_at − scheduled_at`) over `max_stream_minutes`. Clear error messages (`multicam_requires_ticket`, `price_below_minimum`, `duration_exceeds_max`) the app can map to friendly copy
- Update `auto_end_expired_events`: add an absolute backstop ending any live event whose `started_at` is more than 8h + grace ago, covering rows with null `end_at`
- Grant clients read access to the new config columns (or a small `get_pricing_config()` RPC) so the app mirrors the floor locally

## Phase 2 — Create flow UI (page 1) + edit screen
- Move the camera-count stepper from the crew page into page 1 of `create_event_flow.dart` (below Duration); `CrewState.cameraCount` seeds from the draft, and the crew page keeps only operator assignment
- Persist `camera_count` in the page-1 `EventService.create` call
- Price field behavior: single-cam keeps hint "Free"; at 2+ cameras the hint becomes the computed floor, with a one-line explainer ("Multi-camera streams cost more to run — tickets start at $2.50"), and the validator enforces floor/minimum before Next
- Payout preview card under the price field (uses `creator_revenue_share` + pricing config): "Minimum for this event: $X" and a live "You earn ~$Y per ticket" (50% of price), plus an optional tickets-sold estimate showing the total — motivational, not part of the floor
- Duration field: cap at 8h in the validator with a friendly message; same in `duration_field` hint
- `edit_event_screen.dart`: apply identical rules (it edits price, duration, and camera count today); map the new trigger errors to inline messages
- Theme compliance: new widgets use `NileColors`/`NileTextStyles`/`NileRadius`; screens stay wrapped in `NileMaxWidth`

## Phase 3 — Streamer countdown + auto-end
- `camera_screen.dart`: on entering the live state, fetch the event's timing anchor (extend `fetchEventState` to return `scheduled_at`, `end_at`, `started_at`); effective end = `started_at + (end_at − scheduled_at)`, matching migration 0056
- A 1-second ticker starts when ≤10 min remain: small countdown pill overlay (top of screen, coral under 2 min) visible to everyone on the camera screen — host and operators — never to viewers
- At 0:00 the **host's** device automatically runs the existing `_endStream()` path (DB status → ended, egress stopped, room torn down) after a brief "Ending stream…" beat; operator devices just see the room close. Server cron remains the backstop if the host app is dead

## Phase 4 — Free-replay parity verification
- Code audit: confirm no paid-only assumption in `start-show` egress, `livekit-webhook` finalize, host price-prompt notification, `auto_publish_replays` (free → publishes free), event-detail replay CTA, and `replay-url` gating for free events
- End-to-end test on hardware: free single-cam stream → end → replay ready → host prompt → publish free (and the 48h auto-publish path via manual SQL nudge) → playback as a non-follower — confirm 30-day purge untouched
- Add the free-stream replay path to the beta readiness / regression checklist

## Phase 5 — Verify & ship
- `deno check` on any touched edge functions before deploy (per the 2026-07-31 lesson)
- `flutter analyze` via Desktop Commander; manual pass through create → publish → edit for: free single-cam, blocked free multicam, floor-priced multicam, 8h+ duration rejection
- Apply migration 0078 to prod; deploy any touched functions; update memory with the milestone

## Open questions / risks
- Existing drafts created before this ships could hold free multicam state; the trigger catches them at publish — the crew/publish page should surface that error gracefully rather than assume it can't happen
- Rate constants are estimates from the margin calculator (Nile_Event_Margin_Calculator_v3.html); calibrate against a real LiveKit invoice after a few multicam events and retune `app_config` (data change, no deploy)
