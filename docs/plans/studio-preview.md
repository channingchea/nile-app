# Studio Preview — Implementation Plan

## Overview
A private rehearsal of the host Studio, opened from the desktop nav rail. It runs your real camera, mic and screen share on-device, and fills the rest with lightly animated demo chat, crew and stats so the whole layout can be explored. Nothing touches LiveKit, the event row, chat or recording. Choices made here are saved on the device so the real Sound Check starts with them. Notifications leaves the rail and becomes a bell beside the avatar in the top bar.

## Non-goals (v1)
- Layout editing (moving/resizing panels) — later, with the editor features.
- Event-specific preview (real crew, real chat settings) or an event-page entry point.
- Hearing what viewers hear — that's the View-as-Viewer plan.
- Phone layout. The rail item is desktop-only; below desktop width the screen asks you to widen the window.
- Screen sharing on iPad (the broadcast extension needs a live room).
- Mic monitoring through speakers (feedback).

## Phase 1: Navigation — bell to top bar, rail item, route
- [x] Extract the rail's unread badge into a shared `NileCountBadge` so rail and top bar draw it identically.
- [x] `nile_top_bar.dart`: add `_NotificationsButton` just left of `_AccountButton` — bell icon + badge from `NileBadges.notifications` (`listen()`/`release()`), tap pushes `/notifications` and clears the badge, semantics "Notifications, N unread".
- [x] Add `kStudioPreviewDestination` ("Studio Preview", videocam icons) and swap it into the Notifications slot of `kNileRailEntries` as `NileRailEntry.route(…, '/studio-preview')`.
- [x] `NileRoutes.studioPreview` route; add `/studio-preview` to `NileAppShell.isBare` so it fills the window.
- [x] Notifications keeps a keyboard path: ⌘⇧N shortcut + a Go-menu item (the rail slot's ⌘ number now opens Studio Preview).
- [x] `StudioPreviewScreen` start screen (in `NileMaxWidth`): title, "Your camera and mic stay on this device — nothing is broadcast or recorded", Start preview button; denied camera/mic permission explains and links to System Settings; below desktop width shows a "widen the window" note.
- [x] Tests: update `app_shell_test`, `desktop_layouts_test` (rail labels), `mac_phase6_test`; new top-bar bell test (badge, tap, label).

## Phase 2: Saved Studio settings (used by the real Studio too)
- [x] `lib/services/studio_prefs.dart` — SharedPreferences-backed: `cameraDeviceId`, `externalMicProcessing`, `chatVisible`, `videoStartsOff`.
- [x] `CameraScreen` loads them: saved camera if still attached (else default), initial `_disableAgc` and `_chatVisible`, turn video off right after connect when `videoStartsOff`.
- [x] Save on every change in both screens (camera pick, external-mic switch, chat toggle, new "Start with camera off" switch).
- [x] Extract the audio-settings sheet to `lib/widgets/studio_settings_sheet.dart` (values + callbacks) so both screens share it; add the camera-off switch there.
- [x] Unit tests for `StudioPrefs` (defaults, round-trip, unplugged camera); phone layout behaviour unchanged.

## Phase 3: The preview Studio, device-only
- [x] Local mic level without a room (livekit_client 2.7 `createVisualizer`/`AudioVisualizer`, fallback otherwise); `AudioMeter` takes a level source instead of a `Participant`; `CameraScreen` keeps passing participant `audioLevel`.
- [x] Local tracks with no `Room`: `LocalVideoTrack.createCameraTrack` (saved device), `LocalAudioTrack.create` with processing matching the external-mic switch.
- [x] Extract the control bar to a presentation-only `NileStudioControlBar` in `nile_studio.dart` (flags + callbacks) used by both screens.
- [x] Build the preview on `NileStudio` with your camera as the monitored source plus the local meter.
- [x] Real controls: camera picker (recreates the track), video on/off, chat show/hide, settings sheet, screen share on macOS only, matching the real Studio (existing permission step → `screen_share_picker` → `createScreenShareTrack`, appears as a source tile).
- [x] "Exit preview" in the leading slot stops every track and pops (falls back to Home); tracks also released on dispose and app quit.

## Phase 4: Demo content + Sound Check / Live toggle
- [x] `lib/widgets/studio_preview_demo.dart` — a `ChangeNotifier` on a timer: ~20 sample chat lines from made-up names every 3–6 s (keep last 50); viewer count drifts 40–120 in Live.
- [x] Two placeholder crew tiles (`crew:demo-2` "Camera 2", `crew:demo-3` "Camera 3"), one ready → "1 of 2 ready".
- [x] Sound Check / Live switch in the Studio banner ("Preview — not live"): Live sets `isLive`, starts the timer, demo show begins with 11 min left so the countdown chip appears quickly; control bar swaps button sets.
- [x] Show-affecting buttons (Start Show, End Stream, Set as Master Audio, View as Viewer) render normally but only show "Preview only — nothing is broadcast". Chat Hide works locally; Block/Report/Remove/Ban show the same message.

## Phase 5: Safety + verification
- [x] Source-scan test: `studio_preview_screen.dart` / `studio_preview_demo.dart` must not import `livekit_service`, `event_service`, `chat_service`, `crew_service`, or construct `Room(`.
- [x] Widget tests at 740 / 1180 / full width: start screen, third column at 1180, no overflow as chat grows, Live toggle swaps controls, Exit disposes tracks.
- [x] PostHog events `studio_preview_opened` / `studio_preview_started`.
- [x] `flutter analyze` + `flutter test` clean.
- [ ] On-device pass (Mac): camera light off after Exit; screen-share permission granted in preview carries to the real Studio; saved camera + external-mic setting appear in a real Sound Check.

## Implementation notes (2026-10-16)
- Local mic level: `createVisualizer` on the local track + `NativeAudioManagement.startLocalRecording()` (the native audio device doesn't capture without a peer connection; LiveKit's pre-connect buffer starts it the same way). Stopped on exit.
- Saved Studio settings load and save only in Studio mode (desktop/iPad width); the phone layout keeps its shipped defaults.
- `NileStudioControlBar` shows Video On whenever video is off, even on a camera without master audio, so "Start with camera off" can't strand a camera.
- The preview's Leave button reads "Exit" — "Exit preview" overflowed the second control row at the 740 pt minimum window (caught by the layout test).
- Safety test bans `Room(`, the event/chat/crew/LiveKit services, `supabase` and `publish*Track` in the preview files.

## Open questions / risks
- Local mic level without a room — verify first in Phase 3; fallback is a loopback connection reading `getStats` audioLevel.
- Mac camera device IDs are usually stable across launches; unknown IDs fall back to default silently.
- The rail slot's ⌘ shortcut now opens Studio Preview instead of Notifications.
- Builds on the unmerged `macos-phase5-router` branch; Phase 2 touches the real `CameraScreen`, so the phone layout must stay byte-for-byte unchanged.
