# External Feed (WHIP/OBS) Ingest — Implementation Plan

## Overview
Let a host add one production-quality external feed (OBS, ATEM/switcher, console via capture card) to their event as an additional camera angle, via LiveKit WHIP ingress with transcoding bypassed. Latency stays sub-second, ingest cost is $0, and the feed behaves like any other Nile camera: switchable angle, sound-check participant, eligible to be master audio. Implementation starts after the queued external-camera/screen-share hardware tests are done.

## Non-goals / Out of scope
- Multiple external feeds per event (v1 = one)
- RTMP fallback (WHIP only; OBS 30+ required)
- Server-side transcoding / simulcast on the external feed (revisit if viewer buffering shows up)
- Windows/Linux Nile app, game catalog or gaming category features
- Enforcing bitrate server-side (guidance-only in v1)

## Phase 1: Backend — ingress lifecycle
- [ ] Migration `00xx_event_ingress.sql`: `event_ingress` table — `event_id` (PK, FK events), `ingress_id`, `label` (default "Program"), `created_at`; RLS host-only
- [ ] `livekit` edge fn: add `IngressClient` + three host actions:
  - [ ] `create-ingress` → WHIP ingress, `enableTranscoding: false`, identity `external-{eventId}`, metadata `{role:'camera', cameraId:'external', cameraName:label, isMasterAudio:false, isExternal:true}` — so every existing surface (viewer tiles, angle list, replay) treats it as a camera with zero changes
  - [ ] `get-ingress` → `{url, streamKey, status, label}`
  - [ ] `reset-ingress` → delete + recreate (new key, old one dead instantly)
- [ ] Ingress is created once and persists for the event, so OBS can disconnect/reconnect on the same key
- [ ] Delete ingress in the room-cleanup path when the event ends
- [ ] Extend `livekit-webhook` to consume `ingress_started`/`ingress_ended` → live status without polling
- [ ] Verify `set-master-audio` and `set-ready` work against the ingress participant identity (host acts on its behalf)
- [ ] `deno check` every touched fn before deploy (per the July lesson)

## Phase 2: Host UX — crew setup
- [ ] "External feed" card on `crew_setup_screen`: generate button → shows server URL + stream key with copy buttons, editable label, reset-key with confirm, status chip (Waiting / Connected)
- [ ] Compact recommended-settings blurb (WHIP · H.264 · 1080p30 · 4–5 Mbps) + link to website guide
- [ ] Sound check: feed tile appears on connect; host previews and marks it ready themselves
- [ ] Master audio picker includes the external feed (board-mix-as-master is the headline use case)

## Phase 3: Viewer + resilience
- [ ] `viewer_screen`: confirm external tile flows through the existing `role == 'camera'` path, participates in audio-sync like a camera (not the screen-share skip path)
- [ ] Drop handling: on disconnect of the external identity, keep the tile with a "Reconnecting…" state for a grace window (~60s); viewers watching that angle auto-switch to another live camera; tile restores on reconnect, removes after the window
- [ ] Verify replay egress composite includes the ingress participant
- [ ] End-to-end test: OBS 30+ WHIP on Mac → two phone cameras + external feed, angle switching, master audio on the board mix, mid-show OBS kill/reconnect

## Phase 4: Guidance + hardware validation
- [ ] `nile-website` `/resources/obs-setup` page (compatible-devices pattern): OBS WHIP walkthrough, recommended settings, keyframe-interval note, console section (capture card; PS5 needs HDCP off; Xbox fine), latency/quality expectations
- [ ] Real-hardware pass: ATEM/capture-card → OBS → Nile, console gameplay end-to-end, replay framing of the external tile
- [ ] Beta-test with one or two real hosts before announcing

## Open questions / risks
- **Codec constraints on bypass**: no transcode means viewers must decode what OBS sends — guide must pin H.264 (not AV1/HEVC); verify Safari/iOS playback of OBS's H.264 profile
- **Sync when external is master audio**: existing sync anchors to master audio metadata; should work unchanged but needs explicit testing with the ingress as anchor
- **Ingress status fidelity**: webhook delivery lag could briefly show "Waiting" while connected — acceptable for v1
- **Bandwidth cost**: external feed at 5 Mbps ≈ $0.27/viewer-hour vs ~$0.14 blended today; fine at beta scale, revisit transcoding if events grow

## Sequencing note
This work starts after the queued external-camera/screen-share hardware tests (see `external-cameras-screen-sharing.md`) are complete, so only one unproven ingest path is being debugged at a time.
