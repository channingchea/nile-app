# Event Sponsorship + Pre-Show Lobby — Implementation Plan

_Drafted 2026-08-06_

## Overview

Turn the bare sound-check lobby into a "Pre-Show" screen that plays sponsor ad creatives, sold through the existing ad portal as a new "Sponsor an event" product. One sponsor per event, host opt-in, flat config-driven pricing, 70/30 host revenue split via Stripe Connect destination charges. Non-sponsored events get an upgraded lobby too: cover image, countdown, and chat.

**Key design decision:** sponsorships are `ad_campaigns` rows with a new `placement = 'lobby'` value — not a new table. This inherits the review queue, admin audit, Klaviyo notifications, creative storage/validation, and reporting for free.

## Decisions made (interview 2026-08-06)

- One sponsor per event (exclusive); multi-sponsor deferred
- Flat config-driven pricing: free vs ticketed event tiers in `app_config`, retunable without deploys
- Host opt-in per event via a toggle in the Create an Event flow
- Chat enabled pre-show in the lobby
- Host-uploaded promos deferred to v2
- Sponsor reach: lobby loop + "Sponsored by X" tag on event detail (no live-stream badge)
- Auto-refund if no lobby happens (event deleted / never starts / ad not approved in time)
- 24h minimum lead time on purchases (review window)
- Video ads autoplay muted, tap-to-unmute

## Non-goals / out of scope (v1)

- Host-uploaded promos for non-sponsored lobbies (v2)
- Multiple sponsors per event; "Presented by" badge during the live stream
- Tips and reactions pre-show (stay live-only)
- Attendance guarantees or partial refunds

## Phase 1: Backend foundation (migration 0079)

- [ ] `ad_campaigns`: add `placement text not null default 'feed'` (`'feed' | 'currents' | 'lobby'`); backfill existing rows by creative kind
- [ ] `ad_campaigns`: add `application_fee_cents int` + `split_status` (freeze the split per purchase, same pattern as `tickets`)
- [ ] Partial unique index: one campaign per event where `placement='lobby'` and status in (`pending_payment`, `pending_review`, `active`) — first purchase locks the event
- [ ] `events`: add `sponsorship_open boolean not null default false`
- [ ] `app_config` rows: `sponsorship_price_free_cents` (2500), `sponsorship_price_ticketed_cents` (5000), `sponsorship_host_share` (0.70) — launch values are placeholders
- [ ] RPC `get_sponsorable_events(search)`: opted-in, `status='scheduled'`, `scheduled_at >= now()+24h`, not already locked, host has active Stripe Connect account
- [ ] RPC `get_lobby_sponsorship(event_id)`: SECURITY DEFINER, returns active lobby campaign + creative for the viewer screen
- [ ] Lobby impressions/clicks reuse `ad_events` as-is

## Phase 2: Payment, review, refunds (edge functions)

- [ ] `create-ad-payment`: sponsorship branch — validate event eligibility + price server-side from config; manual-capture Checkout Session with `transfer_data.destination` (host Connect account) + `application_fee_amount` (30%), modeled on `create-tip-payment`; require host Connect account (no platform-fallback — don't sell what you can't split)
- [ ] `stripe-webhook`: sponsorship flips to `pending_review` on payment (same as standalone ads)
- [ ] `review-ad-campaign`: approve → capture (money splits at capture); reject → cancel auth; skip the flight-clock reset for lobby placements (the event's schedule is the flight)
- [ ] Auto-cancel sweep (`tally-ad-spend` nightly + a check when host enters sound check): sponsorship still `pending_review` at sound check → cancel + notify advertiser
- [ ] Event-death refunds: event deleted, or `scheduled_at` long past with no sound check → refund captured payments with `reverse_transfer` + `refund_application_fee` (reuse `refund-ticket` pattern); campaign → `rejected` with note
- [ ] Sponsorship completes when the event goes `live` (campaign → `completed`)
- [ ] Run `deno check` on every touched edge function before deploying

## Phase 3: Ad portal — "Sponsor an event" (AdvertiserPortal.vue)

- [ ] New product choice in the `build` flow: Feed ad / Currents ad / **Sponsor an event**
- [ ] Event picker: searchable list from `get_sponsorable_events` — cover, title, host, date, free/ticketed, price from config
- [ ] Creative upload: reuse existing image/video upload (image 4:3 ≤5MB; video ≤60s ≤100MB) + https click URL
- [ ] Checkout → existing Stripe redirect; dashboard shows sponsorship rows with event name, status, lobby impressions/clicks
- [ ] Admin review queue: show placement + target event + event date so time-sensitive reviews sort first

## Phase 4: Flutter — the Pre-Show lobby (viewer_screen.dart)

- [ ] Extend `fetchEventState` select: `scheduled_at`, `cover_image_url`, `description`, host username/avatar (join `profiles`)
- [ ] Rebuild `_buildLobby()`: full-bleed sponsor creative (via `get_lobby_sponsorship`) or cover image if unsponsored; overlay with countdown to `scheduled_at` ("Starting soon" once passed), event title, host row, SOUND CHECK badge — all via NileColors/NileTextStyles, body in NileMaxWidth
- [ ] Ad behavior: video via `video_player` — autoplay muted on loop, tap-to-unmute speaker icon; image static (exclusive single creative, no rotation in v1); persistent "Sponsored" disclosure; tap → `logClick()` + open click URL
- [ ] Impressions: one `logImpression()` per lobby entry (ad is the whole screen — no VisibilityDetector needed)
- [ ] Enable chat pre-show: remove the soundcheck guard on the chat toggle and render chat overlay in the lobby; tips + reactions stay live-gated
- [ ] Transition unchanged: realtime flip to `live` disposes the ad video controller and drops everyone into the stream

## Phase 5: Host side + event detail

- [ ] Create an Event flow: "Open to sponsorship" toggle (also in event edit for existing scheduled events); only enabled when host has an active Connect account — reuse `payout_gate.dart`
- [ ] Event detail screen: "Sponsored by {advertiser}" line when a sponsorship is active
- [ ] Payouts screen: sponsorship earnings row (extend `host_ticket_earnings` RPC or sibling)
- [ ] Notify host when their event's sponsorship is approved (Klaviyo, same pipeline as ad-approved emails)

## Open questions / risks

- **Cold start**: needs both opted-in hosts and advertisers; consider seeding by sponsoring a few launch events in-house
- **Stripe auth window**: manual auths expire ~7 days, so capture happens at approval (not at the event) — which is why event-death refunds matter
- **Review latency**: 24h lead time only works if reviews happen same-day; consider upgrading the 3-day "awaiting review" digest to a same-day ping for lobby placements
- **Disclosure/compliance**: lobby ads show in the iOS app but are purchased on web — same posture as existing ads; keep the "Sponsored" label always visible
