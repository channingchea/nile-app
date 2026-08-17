# Live Chat Moderation — Implementation Plan

## Overview
Live chat today is a raw Supabase Realtime broadcast. Nothing is stored, nothing
is rate limited, nothing is checked, and the host's only moderation lever is
client-local. This is the last open item from the P1 streaming review (#16), and
the only one large enough to need its own plan.

What exists now, precisely:

- `chat_service.dart:155` broadcasts straight to the channel. No length cap, no
  rate limit, no filter, no server-side record.
- Host blocking (`camera_screen.dart:499`) adds a sender to a local `Set`. The
  troll disappears for the host and stays fully visible to every other viewer —
  arguably worse than doing nothing, because the host believes they acted.
- Nothing is persisted, so nothing can be deleted after the fact, reported with
  evidence, or used to ban anyone.
- Viewer chat has no report/block gesture at all. Every other user-content
  surface in the app — profiles, posts, events, Currents — has one via
  `Moderation.showReportSheet`.
- A viewer kicked from a **free** event with `remove-participant` (P1 #11) can
  rejoin immediately, because there is no ban to check at token mint.

Authorization is *not* part of this: who may be in a chat is already enforced by
`can_join_live_chat` and the `realtime.messages` policies, now committed as
migration 0104.

## Non-goals / Out of scope
- Chat history for viewers who arrive late (messages stay ephemeral to the
  audience; storage here is a moderation record, not a transcript feature)
- Automated ML toxicity classification (a wordlist and rate limits first; revisit
  with real abuse data)
- DM moderation (separate surface, separate rules)
- Appeals workflow for bans
- Moderator roles below the host (crew-as-moderator is a possible Phase 5)

## Decisions needed before Phase 1
These change the schema, so they are worth settling first. My recommendation is
in brackets — say the word and I will build to it.

1. **Retention.** How long is a stored message kept? [30 days, purged by the
   existing nightly cron pattern — long enough to investigate a report, short
   enough that we are not quietly building a chat archive.]
2. **Ban scope.** Is a ban per-event or account-wide? [Per-event, issued by the
   host. Account-wide is a platform decision and belongs with the admin console,
   not in a host's hands.]
3. **Ban duration.** Permanent for that event, or timed? [Permanent for that
   event — a show is a few hours; a timer is complexity nobody will use.]
4. **Who moderates.** Host only, or assigned crew too? [Host only in v1.
   `requireHost` already exists and crew-as-moderator can be added later without
   reshaping anything.]
5. **What viewers see when a message is removed.** Silent disappearance, or a
   "message removed" tombstone? [Silent. A tombstone is a trophy.]
6. **Does storage change the product promise?** Chat is currently described to
   users as ephemeral. Storing it for moderation is defensible but it should be
   reflected in the privacy policy before it ships.

## Phase 1: Server-side record + limits
The foundation. Nothing else in this plan is possible while messages exist only
in flight.

- [ ] Migration `01xx_live_chat_messages.sql`: `live_chat_messages` — `id`,
      `event_id` (FK events), `sender_id` (FK profiles), `body`, `created_at`,
      `removed_at`, `removed_by`. Index on `(event_id, created_at desc)`.
- [ ] RLS: insert via the edge function only (service role); select restricted to
      the event host and admins. Viewers never read this table — they still get
      messages over broadcast.
- [ ] Migration `01xx_live_chat_bans.sql`: `live_chat_bans` — `event_id`,
      `user_id`, `banned_by`, `created_at`, PK `(event_id, user_id)`.
- [ ] New edge function `live-chat` (verify-jwt ON), action-routed like `livekit`:
  - [ ] `send` — the only path that may write to the channel from here on.
        Validates: length cap (500 chars), rate limit (see below), ban check,
        and the same `can_join_live_chat` entitlement. Persists, then broadcasts.
  - [ ] `remove` — host-only; sets `removed_at` and broadcasts a delete event.
  - [ ] `ban` — host-only; inserts a ban, removes the user's messages, and calls
        the existing `remove-participant` so they are ejected immediately.
- [ ] Rate limit: token bucket in Postgres keyed on `(event_id, user_id)` —
      5 messages per 10 seconds, burst 10. Cheaper and more honest than an
      in-memory limiter on an edge function that scales horizontally.
- [ ] Wire the ban check into `viewer-token` in `livekit/index.ts`, so a banned
      viewer cannot rejoin a free event. This is the piece P1 #11 left open.
- [ ] Nightly purge job for messages past retention, following the
      `purge-expired-currents` cron pattern.
- [ ] `deno check` before every deploy.

**Client-version note:** shipped builds broadcast directly and will keep doing so
until they update. Sending through the function has to be additive, and the
Realtime write policy can only be tightened to service-role once the
force-update floor passes the build that adopts it. Track that alongside the
`lobbySafe` flag from P1 #7 — same shape of problem.

## Phase 2: Host moderation that actually works
- [ ] `camera_screen`: replace the local `_blockedSenders` set with real calls to
      `remove` and `ban`. Keep local hiding as a separate, clearly-labelled
      "hide for me" — it is genuinely useful and should not masquerade as
      moderation.
- [ ] Studio chat column: per-message overflow menu → Remove message, Ban from
      this show, Report to Nile.
- [ ] Confirm dialogs on ban, in the pattern of the Remove-from-stream dialog
      added in P1 #11 (`camera_screen._removeSource`).
- [ ] Phone layout parity — most hosts run the show from a phone.

## Phase 3: Viewer report/block
- [ ] Long-press (phone) / hover menu (desktop) on a chat row → the existing
      `Moderation.showReportSheet` with a new `ReportTargetType.chatMessage`.
- [ ] Extend `report_service` + the reports table for the new target type,
      carrying the stored `live_chat_messages.id` so the moderation queue has
      the actual text as evidence rather than a screenshot.
- [ ] Viewer-side block reuses `BlockService`, and — unlike the host's — genuinely
      only affects that viewer's own view, which is the correct behaviour there.
- [ ] Surface reported chat messages in the advertiser-portal moderation queue
      alongside the other reported-content types.

## Phase 4: Content filtering
- [ ] Wordlist filter in the `send` path, stored in `app_config` so it can be
      tuned without a deploy.
- [ ] Behaviour on a hit: reject with a quiet client-side message rather than
      shadow-dropping. Shadow-dropping teaches nothing and generates support
      tickets.
- [ ] Log hits for tuning, without storing the rejected text beyond retention.

## Phase 5 (optional, later)
- [ ] Crew as moderators — widen the `remove`/`ban` gate from `requireHost` to
      `requireOperator`.
- [ ] Slow mode: host-set minimum seconds between messages for everyone.
- [ ] Followers-only or ticket-holders-only chat for a paid show.

## Verification
- [ ] Unit tests for the rate limiter and the length cap.
- [ ] Widget tests for the host menu, in the pattern of the P1 #11 tests in
      `test/studio_test.dart`: who sees which action, and what it hands back.
- [ ] Two-device manual pass: ban from one, confirm ejection and refused rejoin
      on the other, on both a free and a paid event.
- [ ] Confirm an old build (pre-`send`) still chats normally against the new
      server, since that is the state of every device in the field on day one.
