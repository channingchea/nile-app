# Studio Live Elements — Foundation Implementation Plan

## Overview
A shared system for interactive on-screen "live elements" (scoreboard, polls, and more — each planned separately later). Every element is saved in the account library, styled from the brand kit, placed on any camera or shown as its own angle, and appears in replays. The same work gives existing graphics a position/layer control and gets them into replays for the first time.

Findings that shaped this plan:
- Replays today are one LiveKit Room Composite recording with the default "speaker" layout. Graphics are drawn on viewers' phones, so **no graphics appear in replays today**.
- Graphics travel in LiveKit room metadata. LiveKit allows 512 KiB; our own cap (`MAX_GRAPHICS_JSON` = 8000) keeps broadcasts light. Elements fit; high-volume data (vote totals) takes its own path (Phase 5).

## Decisions (2026-10-23)
- Launch audiences: sports, musicians, filmmakers, creators.
- Viewers vote by tapping the overlay (no chat voting). Can change their vote until the element closes. One vote per signed-in account.
- Scorekeeping is Studio-only for now.
- Placement: snap to a 3×3 grid of spots plus "full screen". Simple layer list per camera (top = front), drag to reorder, eye to hide, "Copy to all". One control manages graphics AND elements.
- Shortcut keys for elements only while the Elements panel is open.
- Element as its own angle: element full-screen on a brand-kit background.
- Audio always stays with master audio; an element angle never changes audio unless the host chooses otherwise.
- Element/graphic updates are held back on each viewer to match their video delay (no score spoilers).
- If the Studio disconnects, elements stay up as they are (clock keeps running, poll stays open); Studio resumes on reconnect.
- Hosts see vote totals only, never who voted what.
- Replays: show a grid of on-air cameras + element angles, each tile with its own graphics/elements. Results show; nothing is tappable. QR codes display but are not clickable.
- All drawing is Flutter. Nothing goes on the website — including the replay. The replay is built entirely in the Nile app (approach decided at Phase 6).
- Sponsor "presented by": build the hook now, no UI yet.

## Non-goals / Out of scope
- The individual element types (scoreboard, poll, Now Playing, etc.) — each gets its own plan.
- Scorekeeping from a phone.
- Chat-based voting.
- Any website UI or website-hosted page (replay included).
- Free-drag positioning.
- Sponsor "presented by" UI.

## Phase 1: Element data model + server state
- [x] Migration: `studio_elements` library table (id, account_id, kind, name, config jsonb, style jsonb, created_at, updated_at) with owner-only RLS matching `studio_graphics`.
- [x] Migration: `live_element_state` (event_id, element_id, kind, state jsonb, version int, updated_at) — the source of truth, so a Studio reload/crash loses nothing.
- [x] `supabase/functions/_shared/elements.ts`: pure validator for element payloads (kind registry, size caps, brand style via `cleanBrand`, optional sponsor `campaignId` validated like the sponsor graphic).
- [x] livekit fn `set-element` action: host/Studio only; validate → upsert `live_element_state` (reject stale `version`) → mirror a compact snapshot into room metadata `elements`.
- [x] Clocks stored as `runningSince` / `pausedAt` / `elapsedMs`, computed on each phone against the server clock offset (reuse the existing `clock` action).
- [x] Studio disconnect: elements stay as they are; Studio reloads state from `live_element_state` on rejoin.
- [x] Dart: `lib/services/live_elements.dart` (`ElementKind`, `StudioElement`, `LiveElement`, parse/serialize, unknown kinds dropped safely).
- [x] Hidden test-only "counter" element kind to exercise the full path end-to-end.
- [x] Tests: Deno for `_shared/elements.ts` + `set-element`; Flutter for parsing, versioning, clock math.

## Phase 2: Unified layout — spots + layers (graphics and elements)
- [x] `LayoutSpot` enum: tl, tc, tr, ml, mc, mr, bl, bc, br, full.
- [x] Default spot per existing graphic kind (lower third → bl, logo/QR/sponsor → their corner, banner → bc, slate → full) so current shows look unchanged.
- [x] Per-camera layout in room metadata `layout`: ordered layer list of graphic/element ids + spot + hidden flag; "Copy to all".
- [x] Positions measured against the video frame (16:9) with safe margins and scale by frame size — same result upright, sideways, and in replay grid tiles.
- [x] Studio warns when one item covers another (no blocking).
- [x] Rebuild `NileGraphicsLayer` into one overlay that draws graphics + elements by spot and layer order.
- [x] Viewer-side hold-back: apply overlay updates (graphics + elements) when this viewer's video catches up to the update time (use stream delay / RealSync content age where available).
- [x] Studio UI: "Layout" sheet per camera tile — mini 3×3 screen preview, layer list (drag reorder, eye toggle), Copy to all.
- [x] Tests: spot/scale math, layer ordering, default-spot migration, hold-back timing.

## Phase 3: Elements panel in the Studio
- [x] "Elements" toolbar icon next to Graphics; panel = library list, "New element" by kind, editor, live controls.
- [x] Kind registry: each kind supplies editor widget, live-controls widget, viewer renderer, shortcut map. Adding a kind = adding those four.
- [x] Reuse the Cameras checklist dialog for targets; integrate with `CueSet` so elements cue/Take alongside graphics.
- [x] Shortcut keys active only while the Elements panel has focus; graphics keys (1–9/Enter) unaffected otherwise.
- [x] Brand kit: element style = kit + "Use Nile style" opt-out + per-element overrides (e.g., team colors); contrast warn-only.
- [x] Undo: last 10 changes per element.
- [x] Sponsor hook: optional `presentedBy` campaign field accepted + validated server-side; no UI.
- [x] Save/load elements to the account library.

## Phase 4: Element as its own angle
- [ ] "Show as its own angle" toggle → virtual angle in room metadata `show` (id, label, elementId).
- [ ] Viewer angle picker lists it; renders the element full-screen on a brand-kit background.
- [ ] Works with off-air, default angle, Send everyone, reorder, viewers-per-angle counts.
- [ ] Audio stays on master audio; picking an element angle never changes audio unless the host chooses otherwise.
- [ ] Studio source tile for the virtual angle.

## Phase 5: Viewer taps (shared plumbing for polls and later elements)
- [ ] Migration: `element_responses` (event_id, element_id, user_id, choice, updated_at; unique per user per element). RLS: viewers write their own; nobody (host included) reads individual rows.
- [ ] `respond` action: signed in, has access to the show (ticket gate), element open, per-user rate limit; upsert so votes can change until close.
- [ ] Tallies counted in the database; totals pushed to viewers at most once per second outside room metadata (Supabase Realtime broadcast).
- [ ] Hosts see totals only, live and after the show.
- [ ] Overlay tappable regions for elements; taps off under a full-screen slate and in replays.
- [ ] Tests: one-vote-per-account, change-until-close, access gate, throttle.
- [ ] Separate to-do (website copy, not part of this build): privacy-policy line about storing votes.

## Phase 6: Replays with graphics + elements (entirely in the Nile app)
- [ ] Decide the approach later (all in-app, nothing on the website). Candidate: record each camera separately plus a timeline of overlay/element changes, and have the app's replay screen draw the grid and overlays itself.
- [ ] Replay shows a grid of on-air cameras + element angles, each tile with its own graphics/elements in layer order.
- [ ] Results show (scores, poll results); nothing is tappable; QR codes display but aren't clickable.
- [ ] Check grid sync between cameras in replay and fix if it drifts.

## Phase 7: Studio Preview, compatibility, verification
- [ ] Studio Preview supports elements, layouts, virtual angles, and simulated votes.
- [ ] Confirm older builds ignore unknown element kinds / layout fields without crashing; bump `min_build` at ship.
- [ ] Post-show element results available to the host; PostHog events for element use.
- [ ] Full test pass (Flutter + Deno), analyze clean, iOS/Android/macOS builds.
- [ ] On-device checklist: layout on phones upright/sideways, hold-back timing vs video, Studio drop/reconnect, element angle + master audio.

## Implementation notes — phases 1-3 (2026-10-23)
- Migration 0138 (applied to prod): `studio_elements` uses `owner_id` (matches `studio_graphics`), kind checked by shape only so new kinds need no migration; `live_element_state` adds a `spec` column (name/config/style/targets/presentedBy) and `content_at` (hold-back stamp). No RLS policies on live state — the Studio reads it via the new `list-elements` action, which also re-mirrors on-air elements into a room that came back without them.
- livekit fn (deployed): `set-element` (version must be newer — conditional update, 409 `stale` + current element otherwise; clocks stamped server-side from `clockOps`), `list-elements`, `set-layout`; `set-graphics` now stamps `graphics.at`. Pure rules in `_shared/elements.ts`.
- Flutter: `live_elements.dart` (model, clocks, kinds, ElementCue), `overlay_layout.dart` (spots, layers, placement, warnings, 16:9 frame, hold-back), `server_clock.dart`, `studio_elements_controller.dart` (optimistic, per-element push queue, undo ×10), `elements_service.dart`, widgets `elements/element_kinds.dart` (UI registry; counter), `studio_elements_panel.dart`, `studio_layout_sheet.dart`. `NileGraphicsLayer` now draws graphics + elements by spot and layer order inside the 16:9 picture.
- Layer lists key graphics by id (a swapped-in lower third starts at its default spot). Unlisted items go in front in the default order. Slate = full only; banner = top/middle/bottom row.
- Hold-back only runs when the viewer knows both the server clock and its picture age (RealSync measuring); otherwise overlays apply at once — never a guess.
- Counter kind is offered only in debug builds.
- Studio Preview support stays in Phase 7.

## Open questions / risks
- Replay approach (Phase 6) still to be designed, constrained to the app only.
- Hold-back accuracy depends on knowing each viewer's video delay; RealSync content-age is the best source but its flag is off by default.
- Privacy-policy wording for stored votes (website copy, outside this build).
