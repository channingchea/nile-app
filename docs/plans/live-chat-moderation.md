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

## Decisions — settled 2026-08-17
All five schema-shaping questions went to the recommendation. #6 is a writing
task, not a build decision, and is still open.

1. **Retention.** 30 days, purged by the nightly cron.
2. **Ban scope.** Per-event, issued by the host.
3. **Ban duration.** Permanent for that event.
4. **Who moderates.** Host only in v1.
5. **Removal.** Silent — no tombstone.
6. **⚠️ OPEN — the product promise.** Chat is described to users as ephemeral,
   and phase 1 makes that only half true: the audience experience is still
   ephemeral, but there is now a 30-day moderation record. The privacy policy
   has to say so before this ships in a build. Nothing in the code blocks on it;
   the copy does.

## Phase 1: Server-side record + limits — ✅ SHIPPED 2026-08-17
Server halves are deployed and verified on prod; the client half ships with the
next app build.

- [x] Migration `0107_live_chat_moderation.sql`: `live_chat_messages` — `id`,
      `event_id` (FK events), `sender_id` (FK profiles), `body`, `created_at`,
      `removed_at`, `removed_by`. Index on `(event_id, created_at desc)`, plus a
      partial `(event_id, sender_id) where removed_at is null` for the ban sweep.
- [x] RLS: no insert/update policy at all, so writes are service-role only;
      select restricted to the event host and admins. Viewers never read this
      table — they still get messages over broadcast.
- [x] `live_chat_bans` — `event_id`, `user_id`, `banned_by`, `created_at`,
      PK `(event_id, user_id)`. Same migration rather than its own.
- [x] New edge function `live-chat` (verify-jwt ON), action-routed like `livekit`:
  - [x] `send` — length cap (500), rate limit, ban check, and the same
        `can_join_live_chat` entitlement, *called as the user* so the rule is
        stated once and cannot drift from the Realtime policy. Persists, then
        broadcasts. Also stamps the username from `profiles` instead of trusting
        the body — the old client-side path let anyone chat under any name.
  - [x] `remove` — host-only; sets `removed_at` and broadcasts `rm`.
  - [x] `ban` — host-only; inserts a ban, sweeps that sender's messages,
        broadcasts one `rm_user` rather than an `rm` per message, and ejects them
        from the LiveKit room by token metadata (refund-ticket's approach).
- [x] Rate limit: token bucket in Postgres keyed on `(event_id, user_id)` —
      5 messages per 10 seconds, burst 10. Verified against prod: 10 through then
      refused, 4s idle earns exactly 2 back, 60s idle refills to the cap and no
      further. A refusal costs no extra token, so hammering send does not extend
      your own timeout.
- [x] Ban check wired into `viewer-token` in `livekit/index.ts` — the piece
      P1 #11 left open. Crew are exempt.
- [x] Nightly purge (`purge-expired-live-chat`, cron job 21, 04:35) following the
      `purge-expired-currents` pattern.
- [x] `deno check` clean on `live-chat` and the edited `livekit` before deploy.
- [x] Client: `ChatService.send` routes through the function and hands back the
      server's wording on a refusal (the composer restores what you typed);
      `subscribe` gained `onRemove`/`onRemoveSender`; viewer and Studio both drop
      removed messages.

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
- [x] Rate limiter exercised directly against prod — burst, refill and cap all
      behave (see Phase 1). It is a Postgres function, so this is the real test;
      a Dart mock of it would only prove the mock.
- [x] `test/live_chat_test.dart` locks the payload contract the three coexisting
      client versions depend on: a message with a server id, one without (every
      device in the field on day one), a forged system line on the chat topic,
      and a garbled payload. Plus the composer's 250 cap sitting inside the
      server's 500.
- [x] Full suite green (172 tests), `flutter analyze` clean.
- [ ] Widget tests for the host menu, in the pattern of the P1 #11 tests in
      `test/studio_test.dart`: who sees which action, and what it hands back.
      (Phase 2 — there is no menu yet.)
- [ ] Two-device manual pass: ban from one, confirm ejection and refused rejoin
      on the other, on both a free and a paid event.
- [ ] Confirm an old build (pre-`send`) still chats normally against the new
      server, since that is the state of every device in the field on day one.
      Nothing was tightened, so this should hold — but it is the assumption the
      whole additive design rests on, and it is worth proving rather than
      believing.
