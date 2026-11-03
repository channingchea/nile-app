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
- [x] Migration: `event_guests` (event_id, user_id, invited_by, status invited/green_room/on_stage/removed, title, joined_at, stage_seconds) with RLS; `events.guest_invite_code`
- [x] livekit fn actions: `invite-guest` (by user, push notification), `guest-link` (create/rotate code), `guest-token` (new role `guest`), `move-guest` (green_room ↔ on_stage ↔ removed; 409 `stage_full` past 6), `remove-guest` (also RemoveParticipant)
- [x] Green-room privacy enforced by the SFU: guest tracks use publisher subscription permissions limited to host/Studio/crew until on stage
- [x] Backstage talk: Studio publishes a second mic track only green-room identities may subscribe to
- [x] Backstage chat topic (host, crew, guests only)
- [x] Deep link that opens the app into the green room for that event
- [x] In-room phones join via the existing crew camera flow, appear in the green room, mic off by default; one in-room device carries room audio (master-audio rule)

## Phase 3: Interview — guest green room screen
- [x] `GuestGreenRoomScreen`: camera/mic preview + meters, name + title (prefilled from profile), connection/device health, "Waiting for host", small stage preview, backstage chat, host's backstage voice
- [x] "You're on in 5" countdown on the shared server clock when brought on
- [x] On-stage view with Live badge; screen share on devices that support it today (iPad, Mac)

## Phase 4: Interview — host Studio
- [x] Green room column replaces the camera column: tile with video, name/title, meter, health, status; actions Bring on / Send back / Remove / Mute / Talk privately (push to talk)
- [x] Stage monitor: layout picker (Solo, Side by side, Grid, Spotlight), active-speaker highlight, per-person on-stage timer
- [x] Automatic name lower third on bring-on from name/title (auto-hide 8 s default)
- [x] Host-only notes panel per event
- [x] Chat questions on screen: Questions filter + "Show on screen" targeted at the stage
- [x] "Add content angle": one extra angle holding a screen share, graphics or elements
- [x] Four interview templates in Layouts; saved layouts include the stage arrangement

## Phase 5: Interview — viewers, replay, rehearsal
- [x] Viewer screen routes by mode; Multicam unchanged (moved here from Phase 1)
- [x] Viewer stage composed on device from individual feeds, following metadata layout, with speaker highlight and graphics overlay
- [x] Angle picker: Stage + content angle when present
- [x] On-stage avatar strip; tap opens profile sheet without leaving the show
- [x] Audio: all on-stage audio mixed; in-room phones follow the room-audio rule
- [x] Grid replay recorder renders the stage layout from logged stage marks
- [x] Studio Setup rehearsal: animated demo guests, bring on/send back, layouts, countdown

Implementation notes, Phases 2-5 (2026-11-01):
- Migrations 0146 (`guest_invited` notification type, own transaction), 0147 (`event_guests`, `event_host_notes` owner-only, realtime on event_guests, notif_enabled maps guest_invited to the operator_assigned preference), 0148 (share code moved to service-role-only `event_guest_links`: events rows are public, so 0147's `events.guest_invite_code` leaked; the column is emptied and held null by a check, drop it later). All on prod.
- Server rules in `_shared/interview.ts` (tests `tests/interview_test.ts`). livekit actions: invite-guest (push), guest-link, guest-join, guest-token, set-guest-title, move-guest (also crew cameras and the Studio; `stage_full` past 6; countdown 0-10 s, default 5), remove-guest, set-stage (layout/focus/content/order), mute-participant, backstage-token. set-mode to interview seeds the stage with the Studio.
- Room metadata `stage` = `{ids:[{id,at}], layout, focus, content}`; `at` = server ms they appear (the countdown). App side: `lib/services/interview.dart` (`StageState`, `stageSlots`), `interview_service.dart`, `backstage.dart`; widgets `interview_stage.dart`, `interview_green_room.dart`. The same layout maths runs in `recorder/recorder.js` (both tests assert identical numbers).
- Green-room privacy is SFU-enforced by the guest's own client (`applyGuestPrivacy`: only studio/camera/master-audio/guest roles may subscribe until on stage). The guest screen also mutes its tracks across a full reconnect until permissions are re-sent (livekit_client 2.7.0 doesn't resend them on a full restart).
- Talkback is a second, publish-only connection `backstage-<slug>` whose permissions name only the guests being talked to (limiting the Studio's own connection would cut viewers off its audio). Backstage chat = data messages with explicit recipients, not stored.
- Stage graphics = the "All cameras" graphics. "Show on screen" targets All cameras in Interview.
- Viewer audio = master audio + guests on stage; crew phones on stage are video only (this is the "mic off by default" rule for in-room phones — no phone-side change).
- Replay: in Interview the recorder page draws the stage with name tags and reports one full-frame tile, so the replay screen needed no change. Recorder republished to R2 (v1).
- Guests enter by push (`guest_invited` → `/event/:id/green-room`), the event page's "Join green room", or `links.joinnile.com/g/<code>` (`/g/:code`; AASA path added; the web page never reveals the event).
- Share-link approval (2026-11-02, Channing's call): a link is a bearer credential, so link joins now land as `requested` (migration 0149) and get no token until the host answers from an "Asking to join" section at the top of the Studio's green room (Let in / Decline, new livekit action `admit-guest`). The guest can do their camera check while waiting and is let through live (realtime on their own row, 15 s poll fallback). Requests from the last 30 min are capped at 20 per show. Independent review found no bypass; fixes from it: guest-token's status write is keyed on the status (a remove mid-join wins), the webhook kicks any guest not invited/green_room/on_stage, TRUNCATE etc. revoked on event_guests/event_host_notes. Not in Studio Setup rehearsal. Older builds treat `requested` as invited, so min_build must rise when this ships.
- Known limits: signed-out users lose a /g link at sign-in (the router has no return-to, true of all links); the guest's own stage preview skips people not in the room; content angle isn't shown to guests; Studio Setup's rehearsal notes are not saved; updating an existing layout from the current look doesn't refresh its stage arrangement; the guest's lower third replaces the host's on All cameras.
- Not tested on hardware: everything here. On-device checklist: invite by username and link; guest pre-join and green room; host talkback both ways; bring on with countdown; viewer sees/hears only on-stage guests (try a viewer during green room); layouts and Spotlight focus; content angle; remove a guest; replay of an Interview show; echo with the Mac's speakers (external-mic mode).

## Phase 6: Premiere — film upload
- [x] Cloudflare Stream setup (2026-11-02): Starter Bundle ($5/mo); Stream-only account token; Supabase secrets CF_ACCOUNT_ID, CF_STREAM_API_TOKEN, CF_STREAM_SIGNING_KEY_ID, CF_STREAM_SIGNING_JWK (base64 JWK), CF_STREAM_WEBHOOK_SECRET; webhook registered to `functions/v1/premiere-webhook` (build it with --no-verify-jwt, check the Webhook-Signature header)
- [x] Migration: `event_films` (0151; film + trailer uid/status/duration, captions, poster, rating, content_warning, replay_policy, chat_policy, rights_confirmed_at, delete_after, reminder_sent_at)
- [x] `premiere` edge fn: create-upload (resumable tus, 8 h cap, signed URLs required), add-captions (.srt/.vtt), set poster/trailer, delete, playback-token (short-lived, ticket holders + host), trailer-token (public, no ticket needed; separate from the film so the film stays locked), Cloudflare webhook (ready/error)
- [x] Premiere section (own screen `/event/:id/film`, linked from edit event and the event page; create-event explains it comes after creating): file picker with progress and resume (computer recommended for large files), processing status, poster, trailer, captions, rating card + content warning, replay choice (none / 24h / 48h / 7 days / until deleted), chat choice (open / reactions only / slow mode), "I own the rights" checkbox. Studio Setup's film rehearsal moved to Phase 8 (demo film).
- [x] Host "Ready" checklist on the event page
- [x] Cleanup job deletes films after the replay window (never sooner than 7 days), in-app + push reminder 2 days before (`film_expiring`, 0150); reminder email still to add to the Klaviyo backlog

Implementation notes, Phase 6 (2026-11-02):
- Server: migrations 0150 (`film_expiring` notification type) and 0151 (`event_films`, host-only read, realtime, hourly `premiere-sweep` cron). Rules in `_shared/premiere.ts` (tests `tests/premiere_test.ts`), Stream client `_shared/cloudflare_stream.ts`. Functions `premiere` (JWT) and `premiere-webhook` (no JWT: Cloudflare HMAC signature, or x-cron-secret for the sweep). send-push has the reminder copy.
- Uploads: the device sends bytes straight to Stream over tus (`lib/services/tus_upload.dart`, 16 MiB chunks, resumes from the server's offset). `PremiereUploads` (app-wide) keeps going when the screen closes and saves the URL + file so a relaunch can resume within the 6 h upload window. Stream reserves the film's reported length (or 4 h) while an upload is open: that counts against the plan's 1,000 stored minutes.
- Playback tokens are RS256 JWTs signed in the function with the Stream signing key. A token is a shareable link, so viewers get 1 h, never past the replay window's end (the Phase 7 player must renew it); the host's own preview lasts the film + 2 h (1-12 h). The trailer token is for anyone signed in. Host preview plays the real signed HLS stream.
- Review fixes (independent review, no auth bypass found): 0152 adds `stream_deletions` (a trigger queues every Stream uid that leaves event_films, including event deletes; the sweep drains it) and `event_films.over_at` (the deletion anchor the sweep records, since `events.ended_at` is host-editable); shows count as over when ended, cancelled, removed, or a week past start without going live. Viewers get no film during sound check; a priced replay of a free show needs a ticket; per-host quota 3 open uploads and 24 h stored; no film upload/delete while live or in sound check; posters must be our `events` bucket URLs; the sweep isolates per-row errors; any ready video missing requireSignedURLs is locked.
- Still to verify on a real upload: webhook → ready → preview, and that Stream reports requireSignedURLs true.
- Films are deleted at max(replay window, 7 days) after the show; "until I delete it" keeps them.
- App: `lib/services/premiere.dart` (model, checklist, .srt→.vtt), `premiere_service.dart`, `screens/premiere_film_screen.dart`, `widgets/premiere_checklist.dart`; new dependency `file_selector`.

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
