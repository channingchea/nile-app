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
- [ ] Migration: `studio_graphics` (id, owner_id → profiles, kind enum `lower_third|logo|banner|slate`, name, payload jsonb, sort, created_at, updated_at); RLS owner-only
- [ ] Storage bucket `studio-graphics`: public read, owner write under `<uid>/`; PNG/JPG/WebP ≤2 MB
- [ ] Presets: lower third (title + subtitle), logo (4 corners), banner (static or scrolling), slates (Starting soon, Be right back, Thank you, Countdown)
- [ ] `GraphicsService` CRUD + upload
- [ ] Library editor (create/edit/reorder/delete) reachable from the Studio and from Studio Preview
- [ ] Tests: payload validation, RLS

## Phase 5: Push graphics live
- [ ] `set-graphics` action (Studio only): writes room metadata `graphics: { all: [...], bySlot: { <slotId>: [...] } }` merged with existing keys (showStartedAt); snapshots payloads so viewers never read the host's table
- [ ] Caps per target: 1 lower third, 1 logo per corner, 1 banner, 1 slate
- [ ] `NileGraphicsLayer` widget (fade in/out): used by viewer screen, Studio monitor, operator phone preview, Studio Preview demo
- [ ] Combine rule: All + per-slot; same kind → per-slot wins; slate covers video, audio continues
- [ ] Viewer listens to RoomMetadataChanged; late joiners read current state on connect
- [ ] Toolbar "Graphics" button: library with on/off per item for current target + "Clear all"
- [ ] Tests: combine rule, metadata merge keeps showStartedAt

## Phase 6: Resync
- [ ] `resync` action (Studio only, or host phone when no Studio): stamps `resyncAt` into room metadata; rate-limited to once per 10 s
- [ ] Viewers: on a new `resyncAt`, unsubscribe/resubscribe the watched camera + master audio together, show a "Syncing…" chip, recompute offsets; ignore stamps older than their join
- [ ] Studio monitor does the same
- [ ] Toolbar "Resync" button with confirm: "Resync all cameras and audio? Viewers will see a brief pause."
- [ ] Studio hint chip when a camera reconnects mid-show: "Camera 2 reconnected · Resync?"
- [ ] Replays unaffected; old builds ignore the signal

## Phase 7: RealSync
### 7a. Feasibility spike (go/no-go gate)
- [ ] Vendor flutter_webrtc 1.4.0 into `packages/flutter_webrtc` (dependency_override); add `setMinimumPlayoutDelay(ms)` on remote receivers
- [ ] iOS/macOS: call native `SetJitterBufferMinimumDelay` via RTCRtpReceiver's `_nativeRtpReceiver` (not in the public ObjC header); Android: same via JNI
- [ ] Confirm `estimatedPlayoutTimestamp` is present in inbound-rtp stats on iOS, Android, macOS
- [ ] Rig: two phones (one cellular) + separate master-audio device on a metronome; pass = stable measured offset and applied delay visibly moves the picture
- [ ] No-go → decide between a custom WebRTC-SDK build or an upstream LiveKit request; stop Phase 7 until decided
### 7b. Clock alignment
- [ ] `clock` action returning server time
- [ ] Every publisher pings 5×, keeps the min-RTT sample, writes `clockOffsetMs` to metadata; re-measures every 60 s and on reconnect
### 7c. Measurement
- [ ] `SyncEngine`: every 2 s read stats for the watched camera + master audio; drift = (videoPlayout − camClockOffset) − (audioPlayout − audioClockOffset), median of last 5
- [ ] Ignore readings during angle switches until stats settle
### 7d. Correction
- [ ] Delay whichever stream is ahead, cap 1.5 s, ramp in ≤50 ms steps
- [ ] Dead-band: drift <40 ms → no change
- [ ] Angle switch converges within ~2 s
- [ ] Retire the joinedAt subscribe delay; keep it as fallback where RealSync is unavailable
### 7e. Studio visibility + Resync tie-in
- [ ] Source tiles show measured offset ("+120 ms"), amber above 150 ms
- [ ] Resync also forces publisher clock re-measure and immediate viewer recompute
### 7f. Safety
- [ ] Launch self-test of the native delay hook; on failure RealSync disables itself silently
- [ ] Pin WebRTC-SDK version; re-run the self-test before any upgrade

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
