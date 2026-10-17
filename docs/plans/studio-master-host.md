# Studio Master Host & Show Controls — Implementation Plan

## Overview
The host's desktop Studio (Mac, or iPad wide enough for the Studio layout) becomes the control room for a show. It takes over host duties from phones, lets the host's own account run any camera slot, and adds a bottom toolbar to rename cameras, pick master audio, push graphics to one or all cameras, and resync feeds. Viewers still choose their own angle; graphics are drawn on each viewer's screen so they follow whichever camera the viewer is watching. RealSync keeps every camera aligned with master audio for the whole show.

Decisions (Channing, 2026-10-16): Studio = master host when present; host account may operate any/each camera; Mac webcam off by default; host phones regain Start/End after the Studio is gone 30s; graphics = lower thirds, logo/image bug, banner/ticker, full-screen slates; source = Nile presets + host image uploads; toolbar targets the selected camera with an "All cameras" chip; operator phones show pushed graphics on their preview; master audio switchable anytime (confirm when live); graphics library saved per account; viewers cannot hide graphics; resync requires confirmation; RealSync in this pass.

## Non-goals / Out of scope
- A composed program feed; overlays baked into replays (replays stay as-is)
- Multistreaming, free-form layout/scene designer, video or animated graphics, sound effects/music, saved scenes
- Viewer hide-graphics toggle

## Phase 1: Studio as master host
- [x] `livekit` fn: new `studio-token` action (host only) — identity `studio-<eventId>`, metadata `role: "studio"`, `canSubscribe: true`, not counted toward `camera_count`; fixed identity means a second Studio evicts the first
- [x] `studio-camera` action: checks the camera limit before the Studio publishes its own webcam; sets `hasCamera` in Studio metadata
- [x] App: Studio layout joins with `studio-token` instead of `camera-token`; "Use this Mac's camera" toggle (off by default)
- [x] Phones detect a `role: studio` participant; while present, host phones run operator mode (Ready to Stream shown, Start/End Show hidden)
- [x] Studio absent >30s → host phones get Start/End Show back; no Studio at all → host phone behaves as today
- [x] Server: `start-show` / `stop-egress` refused from a non-Studio host device while a Studio is connected
- [x] Update `_isPublisher` / source filters to include `role: studio`
- [x] Tests: role detection, 30s handover timer, Studio eviction

## Phase 2: Slots, "Which camera is this?", rename
- [x] `camera-token` takes `slotId` (event_cameras.id), stores it in metadata; 409 if another device holds that slot; same device reconnecting keeps it
- [x] Host phone entry: "Which camera is this?" sheet listing event slots + Stream Audio, taken slots greyed out (replaces free-text camera name for the host)
- [x] Invited crew auto-land on their assigned slot (existing event_operators flow)
- [x] Studio source list + crew panel organised by slot: "Camera 1 — @user (iPhone) · Ready" / "Camera 3 — open"
- [x] Bottom toolbar shell (extend NileStudioControlBar): target chip = selected source, "All cameras" chip
- [x] `rename-camera` action (Studio only): updates `event_cameras.label` + live participant name/metadata `cameraName`
- [x] Operator phone listens to its own metadata updates and shows the new name
- [x] Tests: slot conflict, reconnect keeps slot, rename propagation

## Phase 3: Master audio control
- [x] One rule: exactly one publisher carries `isMasterAudio: true` (camera, Studio, or Stream Audio); viewer resolver reads only the flag
- [x] Extend `set-master-audio` to any publisher identity incl. Studio and `master-audio-*`; clears the flag on all others
- [x] Studio audio input picker (USB mixer / interface) when the Studio is master audio
- [x] Toolbar "Master audio" menu listing Studio, cameras, Stream Audio with current marked; free in Sound Check, confirm dialog when live
- [x] Old-build fallback: if no flagged publisher is recognisable, old viewers treat the first camera as master
- [x] Tests: flag exclusivity, switch during live

### Implementation notes (Phases 1-3, 2026-10-16)
- Server decisions live in `supabase/functions/_shared/studio.ts` (slot resolution, camera count, who takes the master-audio flag) with Deno tests in `supabase/functions/tests/studio_test.ts`; new actions `studio-token`, `studio-camera`, `list-slots`, `rename-camera` in the `livekit` fn (deployed 2026-10-16).
- App: `lib/services/studio_roles.dart` (roles, `resolveMasterAudio`, `StudioHandover`), `lib/widgets/camera_slot_sheet.dart` ("Which camera is this?" + rename dialog), toolbar widgets in `nile_studio.dart`; tests in `test/studio_master_host_test.dart`.
- The Studio's own webcam takes a camera slot when turned on, so it lists and renames like any camera.
- Slots for crew/older builds: explicit pick → 409 on conflict; assignment / label match / first open slot otherwise (implicit routes never lock a crew phone out).
- Master audio: the host's choice is saved in room metadata (`masterAudio`) so a dropped source reclaims audio on rejoin; Stream Audio still takes it by default when no live choice exists.
- If a show goes live from an old host-phone build while the Studio is connected, the Studio calls start-show itself (idempotent) so the sync anchor and replay recording still happen.
- Old-build fallback is in the NEW viewer (flag → Stream Audio → earliest camera); shipped viewers keep their own rule (see risks).

## Phase 4: Graphics library
- [x] Migration: `studio_graphics` (id, owner_id → profiles, kind enum `lower_third|logo|banner|slate`, name, payload jsonb, sort, created_at, updated_at); RLS owner-only
- [x] Storage bucket `studio-graphics`: public read, owner write under `<uid>/`; PNG/JPG/WebP ≤2 MB
- [x] Presets: lower third (title + subtitle), logo (4 corners), banner (static or scrolling), slates (Starting soon, Be right back, Thank you, Countdown)
- [x] `GraphicsService` CRUD + upload
- [x] Library editor (create/edit/reorder/delete) reachable from the Studio and from Studio Preview
- [x] Tests: payload validation, RLS

## Phase 5: Push graphics live
- [x] `set-graphics` action (Studio only): writes room metadata `graphics: { all: [...], bySlot: { <slotId>: [...] } }` merged with existing keys (showStartedAt); snapshots payloads so viewers never read the host's table
- [x] Caps per target: 1 lower third, 1 logo per corner, 1 banner, 1 slate
- [x] `NileGraphicsLayer` widget (fade in/out): used by viewer screen, Studio monitor, operator phone preview, Studio Preview demo
- [x] Combine rule: All + per-slot; same kind → per-slot wins; slate covers video, audio continues
- [x] Viewer listens to RoomMetadataChanged; late joiners read current state on connect
- [x] Toolbar "Graphics" button: library with on/off per item for current target + "Clear all"
- [x] Tests: combine rule, metadata merge keeps showStartedAt

## Phase 6: Resync
- [x] `resync` action (Studio only, or host phone when no Studio): stamps `resyncAt` into room metadata; rate-limited to once per 10 s
- [x] Viewers: on a new `resyncAt`, unsubscribe/resubscribe the watched camera + master audio together, show a "Syncing…" chip, recompute offsets; ignore stamps older than their join
- [x] Studio monitor does the same
- [x] Toolbar "Resync" button with confirm: "Resync all cameras and audio? Viewers will see a brief pause."
- [x] Studio hint chip when a camera reconnects mid-show: "Camera 2 reconnected · Resync?"
- [x] Replays unaffected; old builds ignore the signal

### Implementation notes (Phases 4-6, 2026-10-16)
- Library: `studio_graphics` (0130 + 0130a — the payload CHECK returned NULL, i.e. pass, on missing fields until 0130a) and the `studio-graphics` bucket. Four Nile preset slates live in code (`StudioGraphicPresets`), not the table.
- On air: `set-graphics` sends the WHOLE state (all + bySlot); server validates shapes, caps (last of a cap key wins), images only from the bucket, real slots only, ≤8 KB. Viewers combine per watched slot (per-slot replaces same cap key). Studio Preview rehearses graphics locally.
- Resync compares the stamp by value (not clocks) so a wrong phone clock still behaves; Studio shows "<camera> reconnected · Resync" for a feed returning mid-show.

## Phase 7: RealSync
### 7a. Feasibility spike (go/no-go gate) — RESULT 2026-10-16: hook GO, measurement NO-GO (decision needed)
- [x] ~~Vendor flutter_webrtc~~ → instead a small local plugin `packages/nile_realsync` reaches flutter_webrtc's receivers through its public singleton (no fork to maintain); `flutter_webrtc` pinned to 1.4.0
- [x] iOS/macOS: native `SetJitterBufferMinimumDelay` via RTCRtpReceiver `_nativeRtpReceiver` + vtable slot 13, proven against the binary (exported base vtable + default-method symbols match api/rtp_receiver_interface.h M144 slot for slot). Android: same slot via JNI (`nativeRtpReceiver`), compiled for arm64/armv7/x86_64 — not run on a device
- [ ] ~~Confirm `estimatedPlayoutTimestamp`~~ — NOT reported for video on a receive-only stream (a LiveKit viewer's subscriber PC) in this WebRTC build: libwebrtc only computes it once the receive stream knows its RTT, which receive-only streams can't learn. Still missing two-way and with RRTR advertised (macOS loopback). Audio is very likely the same.
- [x] Probe (`packages/nile_realsync/tool/run_probe.sh`, macOS): self-test passes every layout check; real loopback video, 600 ms minimum → jitter-buffer target 11 → 589 → 11 ms. The hook works.
- [ ] Rig: two phones (one cellular) + separate master-audio device on a metronome — still owed (Channing)
- [ ] **DECISION NEEDED** (plan's no-go branch) — how to measure each feed's content time at the viewer: (a) in-band capture stamp via a frame transformer (publisher appends server-time to each encoded frame; receiver reads it), (b) custom WebRTC-SDK build exposing SR-based playout NTP without RTT, (c) LiveKit request for RTCP XR (DLRR) on downtracks. Correction stays OFF until decided.
### 7b–7f — built behind the switch, inactive
- [x] 7b `clock` (NTP-style 4-timestamp ping) + `report-clock` actions; every publisher (camera, Studio, Stream Audio) reports `clockOffsetMs` on connect, every 60 s and on Resync
- [x] 7c/7d `SyncEngine` (median of 5 / 3 after a switch, 40 ms dead-band, 1.5 s cap, 50 ms ramp steps, feedback through applied delays) + `RealSyncDriver` in the viewer; joinedAt delay remains the fallback whenever RealSync is off. Reads `estimatedPlayoutTimestamp`, so it does nothing until 7a's measurement question is settled
- [x] 7e Studio tiles show "+N ms" behind the most current camera (amber >150 ms) — same stat, so also blank for now
- [x] 7f launch self-test (iOS/macOS prove the slot; Android checks each receiver's slots resolve into libwebrtc and differ); remote switch `app_config.realsync_enabled` (migration 0131) ships OFF; pin + probe documented in pubspec
- Note: Android builds on Channing's Mac currently fail for an unrelated reason — the only JDK is Android Studio's JDK 25, which Gradle 8.14 can't run on (needs Gradle 9.1+ or a JDK 17/21)

## Phase 8: Polish + on-device pass
- [ ] Toolbar folds to two rows at the 740 pt minimum window
- [ ] Studio Preview demo updated (slots, toolbar, graphics, offsets)
- [ ] Hardware pass: Mac Studio + two phones on one account + an invited crew phone; master-audio switch live; graphics per camera and all; device drop + Resync; RealSync on Wi-Fi vs cellular

## Open questions / risks
- Older app builds: no graphics, host phones won't enter operator mode, Studio-as-master-audio unrecognised (fallback: first camera)
- Mid-show master-audio switch may cause a brief audio jump while the sync reference resets
- RealSync's native call bypasses the SDK's public API — WebRTC upgrades can break it (self-test guards it)
- RealSync adds up to the inter-device gap of latency for viewers
- Room metadata size — keep graphics payloads small (snapshots only, no images inline)
- Work lands on `macos-phase5-router` (still unmerged)
