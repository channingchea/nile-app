# External Cameras + Screen Sharing (iPad & macOS) — Implementation Plan

## Overview
Let broadcasters on iPad and macOS pick an external camera (USB webcam, capture card) instead of being locked to front/back, and let the host or any crew operator share their screen into the stream as its own tile alongside the cameras. Built on the existing LiveKit room/participant architecture.

## Non-goals / Out of scope
- Screen share on iPhone or Android
- Sharing system/app audio (screen share is video-only; master-audio logic untouched)
- In-app-only capture on iPad (whole-device via broadcast extension instead)
- Forced "presentation mode" that auto-focuses the share for all viewers

## Phase 1: External camera picker (iPad + macOS)
- Enumerate video inputs via `Hardware.instance.enumerateDevices('videoinput')` and extend the existing `onDeviceChange` listener (currently mic-only) to refresh the camera list
- Add a camera-select menu to the camera screen (sound check + live), gated to macOS and iPad; phones keep the current flip toggle
- Publish with `CameraCaptureOptions(deviceId: ...)` when a device is selected; wire it through the existing enable/toggle/switch paths in `camera_screen.dart`
- Handle unplug mid-stream: fall back to the default camera and show a notice
- Verify on hardware: USB-C webcam on iPad (iPadOS 17+), webcam + HDMI capture card on macOS

## Phase 2: Screen sharing on macOS
- Add a "Share Screen" button (host + operators, macOS only for now) that publishes a screen-share track via `setScreenShareEnabled`
- Build a source-picker dialog (screens + windows with thumbnails) using LiveKit's desktop capturer, styled with `NileColors`/`NileTextStyles`
- Handle the macOS screen-recording permission: first share triggers the system prompt; on denial, show guidance to System Settings
- Viewer screen: re-key camera tiles by track (identity + source) instead of participant identity, so camera and screen show as separate tiles; label the share tile "«Camera name» — Screen"
- Verify the delayed video/audio-sync subscribe path handles a second video publication from one participant
- Verify replay: confirm the room-composite egress ("speaker" layout) picks up the screen track — LiveKit's default layouts focus screen shares automatically, but test end-to-end

## Phase 3: Screen sharing on iPad (Broadcast Upload Extension)
- Add a Broadcast Upload Extension target in Xcode with a shared App Group, bundle ID, and provisioning
- Configure LiveKit's iOS broadcast path (`ScreenShareCaptureOptions` with the broadcast extension) so the extension feeds frames into the room
- Add the share button on iPad using the system broadcast picker; handle stop/interruption and the extension's memory limit
- No viewer changes needed — the tile model from Phase 2 covers it
- Test on a physical iPad (extensions don't run in the simulator)

## Open questions / risks
- iPad detection: need a reliable "is this an iPad" check for gating the picker/share UI (screen size heuristic vs `device_info_plus`)
- Broadcast extension adds real Xcode/provisioning complexity — biggest schedule risk in the plan
- If the replay composite doesn't frame the screen share well, we may want a custom egress layout (follow-up, not v1)
