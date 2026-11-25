# Cost Controls and 60% Payout — Implementation Plan

_Planned 2026-11-23. Status: phases 1-4 built 2026-11-24 — server live on prod (migrations 0155, 0156, `livekit` v73), app code uncommitted and not yet on a device. Phase 5 not started._

## Overview
Make sure no show can lose serious money before the host payout goes from 50% to 60%. Paid shows get a simple price floor, free shows get limits, and every stream gets cheaper to run. The payout switch is the last step.

## Decisions
- **Price floor:** $3 for the first hour, +$1 per extra half hour (90 min = $4, 2 hr = $5, 8 hr = $17). Same for any camera count.
- **Apple's fee:** the iPhone in-app price will be the web price ÷ 0.70, so hosts earn 60% of the web price everywhere (Patreon's default approach).
- **Free shows:** 2-hour cap, 480p, no recording or replay.
- **Leaving the app:** video and audio pause, then resume on return.

## Non-goals / Out of scope
- Building Apple in-app purchase (separate plan; this one only stores the markup rule).
- Viewer caps, free-show allowances, sponsorship defaults and the tip fee.
- Audio that keeps playing in the background.
- A price floor for replay-only purchases.

## Phase 1: Shrink replays (server only)
- [x] Add `replay_video_kbps` (default 1500) to `app_config`.
- [x] In `supabase/functions/livekit/index.ts`, record both the main replay and the grid replay at 720p, 30 fps, using that bitrate. The grid replay drops from 1080p (`EncodingOptionsPreset.H264_1080P_30`); the main replay currently uses the 720p/3000 kbps default.
- [x] Deploy (`livekit` v73, 2026-11-24).
- [x] Record a 5-minute test show and confirm each file is about 12 MB per minute and plays in `replay_screen` (2026-11-24: 11.3 MB/min, stored on R2 — see replays-on-r2.md).

## Phase 2: New price floor
- [x] Migration 0155: add `floor_base_cents` (300), `floor_step_cents` (100), `floor_step_minutes` (30) and `apple_fee_pct` (0.30) to `app_config`.
- [x] Rewrite `compute_min_ticket_cents` (both signatures) to the new rule, keeping its name and inputs so `enforce_event_pricing_limits` still works.
- [x] Test on the database with a rolled-back block: 60 min → $3, 61 → $4, 90 → $4, 120 → $5, 480 → $17.
- [x] Mirror the rule in `PricingConfig.minTicketCentsFor` (`lib/services/pricing_service.dart`) and add a unit test with the same table.
- [x] In `create_event_flow.dart` and `edit_event_screen.dart`, prefill the price with the minimum, raise it when the duration grows, and show the rule in `PayoutPreviewCard`.

## Phase 3: Free-show limits
- [x] Migration 0156: add `free_max_stream_minutes` (120). `enforce_event_pricing_limits` rejects a longer free show with a new `free_duration_exceeds_max` error, and `auto_end_expired_events` stops free shows at 2 hours.
- [x] Map the new error in `pricing_service.dart`. Pass the 2-hour limit to `DurationField` when the price is $0, with an "add a ticket price for longer shows" hint.
- [x] In the `livekit` function's start-show step, skip both recordings when the event is free and return a "not recorded because free" flag.
- [x] In `camera_screen.dart`, replace the "not recording" warning with "Free shows aren't recorded" (it already knows `_eventIsPaid`). Hide the replay options for free shows.
- [x] Publish free shows at 854×480, about 800 kbps, in `camera_screen.dart` and `guest_green_room_screen.dart`.

## Phase 4: Pause when the viewer leaves
- [x] In `viewer_screen.dart`, on `paused` (phones) or `hidden` (Mac and web), unsubscribe from all video and audio. Ignore `inactive`, so clicking another Mac window doesn't pause.
- [x] After 2 minutes away, disconnect fully and lower the viewer count once.
- [x] On return, re-subscribe, or rejoin if disconnected, with a short "Resuming…" overlay. Check that the tip-checkout return (`_tipPending`) still works.
- [x] Apply the same pause to the second viewer room in that file and to replay and Premiere film playback.
- [ ] Test on Android, Mac and iPhone.

## Phase 5: Ship and switch to 60%
- [ ] Do an on-device pass of phases 2–4, then cut build 9 and raise `min_build` and `macos_min_build`.
- [ ] Set `creator_revenue_share` to 0.60 and confirm a test checkout gives Nile a 40% fee.
- [ ] Update any "50%" copy on nile-website.

## Build notes (2026-11-24)
- The server tells the app a show is free: `freeShow` on the camera, Studio and guest tokens, and on start-show. `lib/services/free_show.dart` holds the 480p/800 kbps settings.
- A free show's screen share keeps its resolution and is held to 800 kbps instead.
- The price field starts at the minimum on a new event (clear it for a free show) and follows the floor when the duration changes, unless the host typed a higher price.
- Replay options needed no change: a free show never gets a replay row, so the event page has nothing to offer.
- Pause-on-leave lives in `lib/services/away_pause.dart` (`AwayWatcher`, `AwayPause`). "The second viewer room" is the rejoin path, which shares `_room`, so one handler covers both.
- A paid show at 2 h 01 min is $6, not $5: every started half hour counts.

## Open questions / risks
- **Low sales:** the floor assumes 10 tickets sold. A show that sells 3 can still lose a few dollars.
- **Largest Interview shows:** 8 hours with 5 cameras plus guests needs about $19 to break even; the floor is $17. Accepted.
- **Old app versions:** the 480p cap is set by the host's app, so it only holds once old builds are blocked in Phase 5.
- **Free Premiere shows:** films are billed per minute watched, so 480p saves nothing there. The 2-hour cap and no-replay rule still apply.
- **Existing free shows:** ones already scheduled past 2 hours are left alone unless edited.
- **Branch:** `nile_app` is on `macos-phase5-router` with unpushed work; commits land there unless decided otherwise.

## Next steps
1. **Start Phase 1** (replay shrink) when Channing approves: add `replay_video_kbps`, change both egress calls in `livekit/index.ts`, deploy with `npx -y supabase@latest functions deploy livekit --project-ref jelmkkvyrliywcdkzhuu`, record a 5-minute test show.
2. **Phase 2 before any paid show goes public:** the current floor formula leaves out Apple's fee and replay costs, and would under-price shows at 60%.
3. **Decide the branch:** commit on `macos-phase5-router` (where the tree is checked out, with other unpushed work) or on `main`.
4. **Separate plan, later:** Apple in-app purchase for tickets (StoreKit products, server-side price mapping, monthly-payout ledger, US-only web checkout button, review notes). Needed before App Store submission if App Review requires IAP.
5. **Watch:** Apple v. Epic Supreme Court argument on 2027-01-11 and the district court's link-out fee ruling; either can change the iPhone economics.
