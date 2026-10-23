# Studio Edits: Sources, Chat, Graphics — Implementation Plan (rev 2)

## Overview
A production-tools pass on the Studio and Studio Preview. Graphics can be aimed at any mix of cameras, with auto-hide timers, hotkeys, fades and flexible countdowns. Source tiles show each camera's graphics, audio level, phone health and viewer count, with off-air, default-angle, reorder, operator nudges and remote camera controls. Chat gets tighter and color-coded, with a host message box, host/crew links, pins, quick messages, filters, blocked words, and "show on screen". Everything is rehearsable in Studio Preview with demo content.

## Decisions (Channing, 2026-10-23)
- Graphic targets: any combination of cameras; removing an all-cameras graphic from one tile removes it from that camera only; tile icon click opens a menu.
- Auto-hide: saved default per graphic, overridable at push. Hotkeys 1–9 = first nine library items, toggled on their last-used cameras.
- Chat on screen: all cameras, hides after 10 s.
- Countdowns: any duration, to a clock time, or to the show's scheduled start.
- Per-camera audio: visual meter only.
- Phone health: shown as values + alerts at battery <15%, serious heat, or poor signal >10 s.
- Off-air: viewers on that angle auto-move to the default angle; the angle leaves their picker.
- Default angle: applies to new viewers + a "Send everyone" button.
- Reorder applies everywhere (Studio, viewer picker, phones).
- Viewers per angle: Studio only.
- Nudges: presets + custom text, operator acknowledges with 👍. "Charge soon" is a preset.
- Remote controls: flip, flashlight, zoom, focus/exposure lock — work automatically, operator is told.
- Chat names: stable color per person (Studio + viewer); host stays coral. Links tappable only in host/crew messages.
- Pin any message, one at a time, until unpinned. Quick messages saved to the account. Questions = contains "?". Blocked words: hidden from everyone but the sender.
- Every feature works in Studio Preview with demo content.

## Non-goals (deferred)
- Graphics "bigger" items: brand kit, QR codes, live data graphics, cue-before-air (next round).
- Listening to individual cameras; per-camera gain/mute.
- Moving/resizing graphics from the tile.
- Emotes / rich text in chat.
- Excluding off-air cameras from replays.

## Phase 1: Chat polish (Studio + viewer)
- [x] Spacing: constrain the row "…" PopupMenuButton to ~20 pt (default 48 pt hit box inflates rows); row padding `s4` → `s2`.
- [x] `NileColors.chatNames` (7 colors, ≥3:1 contrast on light + dark `bgSurface`) + `nileChatNameColor(senderId)` (stable hash). Use in `NileStudioChat` and viewer chat; host stays coral.
- [x] `NileLinkText`: detects http(s) + bare-domain URLs, opens via url_launcher (http/https only); linkifies only when sender is host or crew.
- [x] Host composer at the bottom of `NileStudioChat` (`onSend`; null = hidden): Enter sends via `ChatService.send`; errors inline. Confirm `live-chat` exempts the host from slow mode / followers-only.
- [x] Preview: typed messages appear locally in demo chat.

## Phase 2: Chat tools
- [x] Pin: `events.chat_pinned jsonb` (messageId, senderId, username, body, pinnedAt); `live-chat` actions `pin` / `unpin` (host, or crew when crew moderation is on); broadcast on the system topic; late joiners read the column. Studio: "Pin message" in every row's "…" menu + pinned bar with Unpin. Viewer: collapsible pinned bar.
- [x] Quick messages: table `chat_quick_messages` (id, owner_id, body ≤500, sort, created_at; owner-only RLS). ⚡ button in the composer lists them; click fills the field, Enter sends. Editor to add/edit/delete/reorder.
- [x] Paused scrolling: when scrolled up, new messages don't move the list; "↓ N new messages" chip jumps back.
- [x] Filter chips: All · Questions (contains "?") · Tips · First-time. `live-chat` stamps `firstTime: true` when the sender has never chatted in any of this host's shows.
- [x] Blocked words: table `chat_blocked_terms` (owner_id, term; owner-only) + editor in Chat settings. `live-chat` send matches case-insensitive whole words → insert with new `filtered_at` column, no broadcast, return `{filtered:true}`; sender's client shows its own copy. Studio subscribes to `live_chat_messages` inserts for the event (verify host select RLS) and shows filtered lines greyed with "Filtered" + "Show anyway" (new `release` action broadcasts it).
- [x] Preview: demo pin, questions, tips, and a filtered example.

## Phase 3: Graphics data model (server + viewer)
- [x] `LiveGraphic` adds `except` (slot ids, for all-camera graphics), `hideAt` (epoch ms from the graphic's auto-hide seconds at push), and a `chat` kind (username, avatar, message).
- [x] `forSlot()` skips excluded slots and anything past `hideAt`.
- [x] Countdown payload `countdown: {mode: duration|clock|showStart, seconds|at}` → absolute `endsAt` at push; clock times display in each viewer's time zone.
- [x] Studio removes expired graphics from room metadata at `hideAt`.
- [x] `NileGraphicsLayer` fades graphics in/out (250 ms, keyed by id).
- [x] Server: `_shared/graphics.ts` accepts `except`, `hideAt`, `chat`; migration 0132 widens the `studio_graphics` payload check (autoHideSeconds, countdown modes); redeploy `livekit`.
- [x] `GraphicsState` helpers: `targetsOf`, `withTargets`, `withoutOnSlot`, `withoutEverywhere`, `lastTargets` (for hotkeys).
- [x] Deno + Flutter tests.

## Phase 4: Graphics panel + library
- [x] Each row's switch → "Cameras" button with a summary (Off / All cameras / All but Cam 2 / Cam 1, Cam 3). Opens a checklist: All cameras, each slot (connected or not), auto-hide override (Off/5/8/10/15/30 s/custom), "Remove from all".
- [x] Panel no longer depends on the toolbar's selected camera; remove `NileStudioTargetChips` if graphics was their only use.
- [x] Hotkeys 1–9 toggle library items 1–9 on their last targets (all cameras first time); number badge on each row; ignored while a text field has focus.
- [x] Library editor: Duplicate, drag to reorder (writes `sort`), per-graphic auto-hide default (new lower thirds 8 s; others Off), countdown editor (duration / clock time picker / until show start).
- [x] Fix library subtitles (show corner + size, auto-hide).
- [x] Clear all clears every target; confirm when live.
- [x] Chat → screen: "Show on screen" in each chat row's menu (all cameras, 10 s) with "Change cameras/timer…" beside it.
- [x] Preview: demo cameras as targets; hotkeys and fades work.

## Phase 5: Source tiles — graphics + show control
- [x] Draw `NileGraphicsLayer` on each tile, scaled to the tile (add a scale input if needed).
- [x] Graphic icon row under the name (≤6, then "+N"; tooltip = name). Click → menu: name, Remove from this camera, Remove from all cameras. Screen shares: Remove from all only.
- [x] `livekit` action `set-show` writes room metadata `offAir: [slotIds]`, `defaultSlot`, `sendAll: {slot, nonce}` (host/Studio only).
- [x] Off-air toggle (tile menu): tile dims + OFF AIR badge; viewers unsubscribe, drop it from the picker, and anyone watching moves to the default angle with a toast; the operator's phone shows "Off air".
- [x] "Set as default angle" (★ badge): new viewers start there (fallback: first on-air slot). "Send everyone here" (confirm when live) moves all viewers once.
- [x] Drag to reorder tiles: `livekit` action `reorder-cameras` rewrites `event_cameras.slot_index` in two passes (avoid a unique clash); renumbers default "Camera N" labels only; viewer pickers and phone labels follow.
- [x] Viewers per angle: table `angle_watchers` (event_id, user_id, slot_id, seen_at; PK event_id+user_id; viewer writes own row). Viewers upsert on angle change + every 60 s. RPC `angle_counts(event_id)` (host/crew/admin) counts seen in the last 90 s; Studio polls every 15 s → 👁 N on each tile. Nightly purge.
- [x] Preview: demo off-air, default, send-all, reorder, counts.

## Phase 6: Camera status channel — meters, health, master audio
- [~] 6a spike: can a phone read its mic level while its broadcast track is muted? Fallback: local-recording path used by Studio Preview's meter.
- [x] Phones send lossy data messages only to Studio participants: mic level ~8×/s; every 5 s battery % + charging, thermal state, send resolution/fps; plus capabilities (torch, zoom range, focus/exposure lock). Stops when no Studio is present.
- [x] Thermal via a small iOS/Android method channel; battery via `battery_plus`.
- [x] Studio tiles: slim audio meter (greys with "No signal" after 2 s), health icons (battery, heat, signal from LiveKit connection quality).
- [x] Alerts: Studio toast at battery <15%, serious heat, or poor signal >10 s (once until cleared); low-battery toast has "Send 'Charge soon'".
- [x] "Make master audio" in the tile "…" menu (hidden on current master, screen shares, open slots); reuses the existing switch + confirm-when-live.
- [x] Older phone builds: tile shows "Update app for status".
- [x] Preview: demo levels, health, a low-battery alert, local master-audio switch.

## Phase 7: Operator link — nudges + remote controls
- [x] Studio → phone commands as reliable data messages to one camera; phones obey only a sender whose server-issued role is `studio`.
- [x] Nudges: presets (Go wide · Tighter · Check focus · Stand by · Charge soon) + custom text (≤80) from the tile menu. Phone shows a top banner + vibration + 👍; ack returns and the tile shows "👍 Read" for 10 s.
- [x] Remote controls popover on the tile: flip (reuses `_switchCamera`), flashlight, zoom (1×/2×/3× + slider, capped to the phone's range), focus/exposure lock; greyed where unsupported. Phone shows "Studio turned on your flashlight" and the operator can undo.
- [~] 7a spike: confirm flutter_webrtc 1.4.0 torch/zoom/focus/exposure calls on iOS + Android; if focus/exposure lock is missing, ship the other three and flag it.
- [x] Preview: nudge + controls UI with simulated 👍.

## Phase 8: Verify and ship
- [x] Tests for each phase (metadata parsing, `angle_counts` access, blocked-word matching, widgets). Full suite + `flutter analyze` clean; Deno tests.
- [ ] Bump `min_build` (old viewers ignore `except`, `hideAt`, off-air, default angle).
- [x] Commit on `macos-phase5-router`.
- [ ] On-device checklist: meters + health on 2 phones; nudge + 👍; torch/zoom; tile graphics match a viewer; excluded camera stays clean; auto-hide + fades; hotkeys; off-air moves viewers; Send everyone; reorder on a viewer; angle counts; pin; blocked word; quick messages; links from host vs viewer.

## Open questions / risks
- 6a (muted-mic metering) and 7a (focus/exposure lock) are unproven; each has a fallback or ship-without path.
- Off-air cameras still appear in replays if replays record every camera (deferred).
- Viewer counts only include signed-in viewers; the 60 s heartbeat costs ~1 write per viewer per minute.
- Old viewer builds ignore the new fields until they update (min_build bump).

## Implementation notes (2026-10-23)
Built in one pass on `macos-phase5-router`. Server half live on prod: migrations 0132 (graphics payload: autoHideSeconds, countdown modes), 0133 (chat_pinned, filtered_at, chat_quick_messages, chat_blocked_terms, `live_mod:<slug>` moderator topic, first-time lookup), 0134 (angle_watchers + angle_heartbeat/angle_counts + nightly purge); `live-chat` and `livekit` redeployed.

Deviations from the plan:
- Filtered lines reach the Studio over a moderators-only Realtime topic (`live_mod:<slug>`, policy `live_mod_read`) instead of a postgres_changes subscription on `live_chat_messages` — no table in the realtime publication, and crew moderators are covered by the same rule as `requireModerator`.
- Battery and heat come from a small native channel (`nile/device_status` in ios/Runner/AppDelegate.swift and android MainActivity.kt) instead of `battery_plus` — no new dependency or pod.
- Hotkeys 1–9 map to the first nine items of YOUR library (not the presets); they pause while a text field has focus, while ⌘/Ctrl/Alt is held, and while a dialog is open.
- Reorder writes `slotOrder` into room metadata so viewer pickers follow without refetching slots.
- `NileStudioTargetChips` removed.
- The fade already existed (280 ms); now 250 ms and the last graphic fades out instead of vanishing.

Spikes, both code-complete but unproven on hardware:
- 6a: livekit_client 2.7 `mute()` stops the published mic track, so a muted camera meters from a second, never-published local mic track with a visualizer. If it reports nothing, the tile shows "No signal". Keeps the phone's mic indicator on.
- 7a: flutter_webrtc 1.4.0 has torch (`setTorch`/`hasTorch`), zoom (`Helper.setZoom`, iOS clamps to the device max) and focus/exposure lock (`Helper.setFocusMode/setExposureMode`, iOS+Android only). Offered only on phones with the built-in camera.

Still owed: min_build bump when the build ships; the on-device checklist above.
