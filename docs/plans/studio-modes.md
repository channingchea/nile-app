# Studio Modes (Multicam · Interview · Premiere) — Implementation Plan

## Overview
The Studio gets three modes. **Multicam** is today's layout. **Interview** adds a green room, a stage of up to 6 people, and remote guests mixed with in-room phones. **Premiere** plays an uploaded film in sync for every viewer, with a host camera angle and a post-show Q&A in the green room. Hosts pick the mode at event create/edit and can change it with a center switch in the Studio top bar until they go Live. Studio Preview is renamed **Studio Setup**.

## Decisions (Channing, 2026-11-01)
- Mode switch: Sound Check/Live-style button group centered in the Studio and Studio Setup top bars; locked once Live.
- Mode + film upload also set at event create/edit.
- Interview: green room replaces the camera column; toolbar unchanged. Viewers see the main stage only, plus an optional host-created content angle. Guests need a Nile account; on-stage avatars link to profiles. Mixed: in-room phones allowed. Stage max 6 including the host. Invites by username search and by share link. Extras: chat questions on screen, host-only notes, on-stage timer, guest screen share, "you're on in 5" countdown.
- Premiere: film uploaded ahead of time and played via Cloudflare Stream, synced to a shared show clock (chosen over LiveKit URL ingress: cheaper per viewer, real pause, native captions). Replay choice and chat-during-film choice belong to the filmmaker per event. The trailer shows in the countdown lobby and on the event page (to everyone, ticket or not). Post-show Q&A uses the interview green room. Watermark deferred; screen-recording blackout kept.
- Films deleted after the replay window (7 days if no replay). Ticket price floor updated for both new modes.
- Build order: Interview first, then Premiere.

## Pricing checked (2026-11-01)
- Cloudflare Stream: $1 per 1,000 minutes delivered (~$0.06 per viewer-hour), $5/month per 1,000 minutes stored (prepaid blocks), encoding free.
- LiveKit URL ingress (not chosen): $0.02/min video transcode after the 600 shared minutes on Ship, plus ~$0.13/viewer-hour delivery; URL ingress starts on create and cannot pause or seek.
- Example, 2-hour film, 50 viewers: Stream ≈ $6 delivery + storage share; LiveKit ≈ $2.40 transcode + ≈ $13 delivery.

## Non-goals (v1)
- Browser-link guests (Nile account + app required)
- Audience call-ins
- Username watermark over the film; DRM
- Separate per-guest high-quality (ISO) recordings
- Multiple films per show; auto-start the film with no host present

## Phase 1: Mode foundation, switcher, rename
- [x] Migration 0145: `events.studio_mode` text check (`multicam`, `interview`, `premiere`), default `multicam`
- [x] `lib/services/studio_mode.dart`: `StudioMode` enum, labels, `canSwitch(isLive)`
- [x] `NileStudioModeSwitch` widget (styled like the Sound Check/Live control) centered in the Studio Setup top bar and the real Studio top bar; disabled with a tooltip while Live
- [x] livekit fn `set-mode` action: host/Studio only, refused while live, writes `events.studio_mode` + room metadata `mode`
- [x] Mode picker in create-event and edit-event; Premiere reveals the film section (Phase 6)
- [ ] Viewer screen routes by mode; Multicam unchanged (moved to Phase 5, when there is an Interview stage to route to)
- [x] Rename Studio Preview → Studio Setup (UI text only: nav rail, View menu, ⌘6, page titles, tests; file and class names stay)

Implementation notes (2026-11-01):
- 0145 also adds trigger `events_lock_studio_mode`: the mode can't change on a `live` row, even from a direct client update. Applied to prod and tested in a rolled-back block.
- Pure rules in `_shared/studio_mode.ts` (`checkModeChange`), tests in `tests/studio_modes_test.ts`. `set-mode` is `requireHost`; while the Studio is in the room only the Studio may call it (`studio: true`). It also refuses once room metadata has `showStartedAt`, or the event has ended. Room metadata is written only if the room exists.
- The Studio reads the mode from `fetchEventState` (`studio_mode` added to its select), then from room metadata `mode`. The field in camera_screen is `_showMode` because `_studioMode` already means "desktop Studio layout".
- `NileStudio.center`: a third slot in the stats row. `_CenteredBarLayout` lays the center out first (max 60% of the row, scaled down past that) and gives each side half of what's left; both sides scroll instead of overflowing. Switch only shows for the host's Studio.
- Selected segment = solid pill in `txtPrimary` (white in dark mode), per the approved wireframes, so it never reads as the coral Sound Check/Live state.
- Create/edit: "Studio Mode" section above Cameras (`StudioModeField`), locked in edit when the event is live. The Premiere film section comes with Phase 6.
- Studio Setup: the switch is a local rehearsal value (nothing saved). Rehearsal strings now say "Rehearsal" instead of "Preview".
- Tests: `test/studio_modes_test.dart` (value, Event parsing, switch, centered without overflow at 740/1024/1440). Studio Setup's full-chat overflow test now includes the switch.

## Phase 2: Interview — guests and server
- [ ] Migration: `event_guests` (event_id, user_id, invited_by, status invited/green_room/on_stage/removed, title, joined_at, stage_seconds) with RLS; `events.guest_invite_code`
- [ ] livekit fn actions: `invite-guest` (by user, push notification), `guest-link` (create/rotate code), `guest-token` (new role `guest`), `move-guest` (green_room ↔ on_stage ↔ removed; 409 `stage_full` past 6), `remove-guest` (also RemoveParticipant)
- [ ] Green-room privacy enforced by the SFU: guest tracks use publisher subscription permissions limited to host/Studio/crew until on stage
- [ ] Backstage talk: Studio publishes a second mic track only green-room identities may subscribe to
- [ ] Backstage chat topic (host, crew, guests only)
- [ ] Deep link that opens the app into the green room for that event
- [ ] In-room phones join via the existing crew camera flow, appear in the green room, mic off by default; one in-room device carries room audio (master-audio rule)

## Phase 3: Interview — guest green room screen
- [ ] `GuestGreenRoomScreen`: camera/mic preview + meters, name + title (prefilled from profile), connection/device health, "Waiting for host", small stage preview, backstage chat, host's backstage voice
- [ ] "You're on in 5" countdown on the shared server clock when brought on
- [ ] On-stage view with Live badge; screen share on devices that support it today (iPad, Mac)

## Phase 4: Interview — host Studio
- [ ] Green room column replaces the camera column: tile with video, name/title, meter, health, status; actions Bring on / Send back / Remove / Mute / Talk privately (push to talk)
- [ ] Stage monitor: layout picker (Solo, Side by side, Grid, Spotlight), active-speaker highlight, per-person on-stage timer
- [ ] Automatic name lower third on bring-on from name/title (auto-hide 8 s default)
- [ ] Host-only notes panel per event
- [ ] Chat questions on screen: Questions filter + "Show on screen" targeted at the stage
- [ ] "Add content angle": one extra angle holding a screen share, graphics or elements
- [ ] Four interview templates in Layouts; saved layouts include the stage arrangement

## Phase 5: Interview — viewers, replay, rehearsal
- [ ] Viewer stage composed on device from individual feeds, following metadata layout, with speaker highlight and graphics overlay
- [ ] Angle picker: Stage + content angle when present
- [ ] On-stage avatar strip; tap opens profile sheet without leaving the show
- [ ] Audio: all on-stage audio mixed; in-room phones follow the room-audio rule
- [ ] Grid replay recorder renders the stage layout from logged stage marks
- [ ] Studio Setup rehearsal: animated demo guests, bring on/send back, layouts, countdown

## Phase 6: Premiere — film upload
- [ ] Cloudflare Stream setup (Channing): account ID, API token, signing key, webhook secret as Supabase secrets
- [ ] Migration: `event_films` (event_id, host_id, stream_uid, status uploading/processing/ready/error, duration_s, captions, poster, trailer_uid, rating, content_warning, replay_policy, replay_hours, chat_policy, rights_confirmed_at, delete_after)
- [ ] `premiere` edge fn: create-upload (resumable tus, 8 h cap, signed URLs required), add-captions (.srt/.vtt), set poster/trailer, delete, playback-token (short-lived, ticket holders + host), trailer-token (public, no ticket needed; separate from the film so the film stays locked), Cloudflare webhook (ready/error)
- [ ] Premiere section in create/edit event and in Studio Setup: file picker with progress and resume (computer recommended for large files), processing status, poster, trailer, captions, rating card + content warning, replay choice (none / 24h / 48h / 7 days / until deleted), chat choice (open / reactions only / slow mode), "I own the rights" checkbox
- [ ] Host "Ready" checklist on the event page
- [ ] Cleanup job deletes films after the replay window (7 days if none), in-app reminder 2 days before; reminder email added to the Klaviyo backlog

## Phase 7: Premiere — synced playback and run of show
- [ ] Room metadata `film`: state (pre/playing/paused/intermission/hold/ended), positionMs, at (server ms), segment (pre-show/film/post-show)
- [ ] livekit fn `film-control`: play / pause / intermission (duration) / hold (message) / resume; host/Studio only
- [ ] `FilmSyncPlayer` (video_player, HLS): target = position + elapsed; drift 0.3–1.5 s corrected by 0.95–1.05× speed, >1.5 s seeks; late joiners seek
- [ ] Run of show: pre-show = host camera stage; Play = film stage; credits end → post-show (host camera + green room Q&A) automatically; manual override
- [ ] Host camera as second angle, or picture-in-picture toggle with corner choice
- [ ] Audio: host mic auto-mutes at film start; Commentary switch = host mic on + film ducked to 30% on viewer devices
- [ ] Studio Premiere panel: transport buttons, progress + time remaining, Commentary and PiP toggles, in-sync film monitor
- [ ] Countdown lobby: poster, muted trailer (tap for sound), countdown; built into the Pre-Show lobby, sponsor slot kept
- [ ] Trailer on the event page (event_detail_screen): muted autoplay at the top, tap for sound, poster shown while it loads or if there's no trailer; plays for anyone, before or after buying a ticket
- [ ] Rating card before the film; 18+ rating runs the existing age check before a playback token is issued

## Phase 8: Premiere — protection, chat, captions, closing, replay
- [ ] Screen-recording blackout: iOS covers the film while captured; Android FLAG_SECURE on the premiere screen; macOS window sharingType none during the film; explanatory slate
- [ ] Captions toggle (WebVTT from Stream via video_player closed captions)
- [ ] Chat policy enforced in live-chat while the film plays (reactions only = emoji bar); reopens for post-show
- [ ] Post-show Q&A reuses the interview green room and stage
- [ ] "Thanks for watching" closing slate: tip button, filmmaker profile link, optional "Rate the film" poll
- [ ] Replay per filmmaker choice, as chapters: Intro (room recording) · Film (Stream) · Q&A (room recording), split at logged film start/end
- [ ] Studio Setup rehearsal with a short demo film and all transport controls

## Phase 9: Pricing, analytics, website, verification
- [ ] Mode-aware `compute_min_ticket_cents`: premiere adds film hours × $0.06/viewer + storage share; interview adds guests × hours; also include recording cost (fee-analysis guardrail 1)
- [ ] PostHog events for modes, guests, film actions (counts only, never names)
- [ ] Update /filmmakers page + FAQ: upload instead of screen share (no em dashes)
- [ ] Tests: Deno (stage limit, mode lock, film-control auth, playback tokens), Flutter (film drift math, stage layout math), extend the Studio Setup safety test
- [ ] On-device checklist; min_build bump at ship

## Open questions / risks
- Commentary audio vs the HLS picture can be up to ~0.5 s apart; verify on hardware.
- Cloudflare Stream account setup is manual.
- Screen-recording blackout cannot stop filming the screen with another device.
- Large uploads from phones are slow; resumable, but the UI recommends a computer.
