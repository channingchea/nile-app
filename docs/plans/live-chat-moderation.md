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
- [x] `camera_screen` keeps the local `_blockedSenders` set but stops it
      pretending: hide and block are labelled **"for me"** in the menu, and sit
      below a divider from the room-wide actions. They were never moderation and
      the old labels let them read as if they were.
- [x] Studio chat column: per-message overflow menu → Remove this message, Ban
      from this show, then the for-me actions, then Report.
- [x] Confirm dialog on ban, in the pattern of `camera_screen._removeSource`.
      Remove has none, deliberately — it is one line, an admin can restore it,
      and a modal between seeing something and taking it down is a modal the
      audience reads over the host's shoulder.
- [x] Phone layout parity: long-press a line in the overlay for the same
      actions. **Two bugs found doing this** — the phone overlay applied neither
      the hidden nor the blocked filter, so hiding someone on a phone did
      nothing at all, and it had no moderation gesture whatsoever. Both surfaces
      now derive their list from one `_visibleChatMessages` getter so they
      cannot disagree again.
- [x] Remove is hidden (not disabled) on a message with no id — a line from a
      pre-#16 client has nothing to soft-delete. Ban still reaches it, because
      it clears by sender.

## Phase 3: Viewer report/block — ✅ SHIPPED 2026-08-17
- [x] Long-press a chat row on either viewer surface → block, or the existing
      `Moderation.showReportSheet` with the new
      `ReportTargetType.liveChatMessage`. One gesture rather than a hover menu:
      the row is the same widget on phone and desktop, and an overflow icon on
      every line costs more than it is worth in a column that narrow.
- [x] `report_target_type` gains `live_chat_message` (0108, alone in its own
      migration — an enum value added and used in the same transaction fails),
      wired into `get_report_queue` and `moderate-report` (0109). The queue
      preview carries the event title: a chat line without the show it came
      from is close to unreviewable.
- [x] Viewer block reuses `BlockService` and filters chat client-side. It has to
      be client-side — chat is a broadcast, so RLS never sees it, which meant a
      viewer who had blocked someone everywhere else still read them in chat.
- [x] Reported chat messages appear in the portal queue with Remove/Restore.
- [x] Falls back to reporting the account when the message has no id.

**Two live bugs fixed in passing, both found by reading rather than reported:**
- `moderation_audit`'s CHECK still listed `rapid`/`rapid_comment`. 0071 renamed
  the enum, the tables and the functions and never touched it, so since that
  rename **every moderation action on a Current has failed its audit insert** —
  silently, because `moderate-report`'s `logAudit` only console.errors. The
  moderation happened; the audit trail didn't. Nothing to backfill.
- The portal's `ReportRow` union, `TYPE_LABELS` and `reportPreview()` never
  learned about `current`/`current_comment` either, so a reported Current hit
  `default: // user`, rendered as a blank card with no Remove button, and could
  only be dismissed. That `default` is now a named `case "user"` plus a loud
  fallback, so the next new type is visibly wrong instead of quietly wrong.

## Phase 4: Content filtering — ✅ SHIPPED 2026-08-17
- [x] Wordlist filter in the `send` path, tunable from the dashboard with no
      deploy. **Not in `app_config`, deliberately** — that table is
      world-readable by design (`using (true)` plus an explicit grant to `anon`,
      because the force-update gate has to work before sign-in), so putting a
      harassment wordlist there publishes a map around itself. It gets its own
      RLS-locked `chat_blocked_words` table, and the match runs in Postgres
      (`live_chat_filter_hit`) so the list never crosses the wire.
- [x] Single entries match on token boundaries, not substrings — substring
      matching is what gives you the Scunthorpe problem. Entries with a space
      are phrases, matched with `position` rather than `like` so a `%` in an
      entry can't act as a wildcard.
- [x] Rejected out loud (422 with wording the composer shows), not
      shadow-dropped.
- [x] Hits logged to `live_chat_filter_hits` as **the matched word and who
      tripped it, never the message** — storing the rejected text to tune the
      list would mean storing exactly what we refused to store. Same 30-day
      purge.
- [x] Ordered after the rate limit on purpose: before it, the filter would be a
      free oracle for probing the blocklist.
- [x] Host and crew skip the filter — being filtered on your own show is the
      worst version of a false positive.

## Phase 5 — ✅ SHIPPED 2026-08-17
- [x] Crew as moderators, **opt-in per event** (`events.chat_crew_moderation`,
      default false). The plan said to widen the gate outright; that would have
      quietly overwritten the settled "host only in v1" decision for every show
      on the platform. As a per-show switch the default behaviour is unchanged
      and the capability still exists.
- [x] Slow mode (0–300s), implemented by handing the existing token bucket a
      capacity of 1 and a refill of 1/N rather than adding a second limiter.
      `least(capacity, …)` clamps a bucket filled under the old settings, so
      turning it on mid-show binds immediately.
- [x] Followers-only / ticket-holders-only chat. Restricts **speaking only** —
      reading stays governed by `can_join_live_chat`, because a gate that also
      hid the conversation would make a restricted room look broken, which is
      the exact failure #15 spent a fix on.
- [x] `ticket_holders` is refused on a free event by a table CHECK *and* by a
      readable error, and isn't offered in the UI: free events create no ticket
      rows, so the setting would mute the entire room.
- [x] Host-only `settings` action + a chat-settings sheet in the Studio header.
      Settings stay the host's even when crew can moderate — deciding how the
      room behaves is not the same job as policing it.
- [x] A narrowed room says so in the chat header. Slow mode and follower-only
      chat both look exactly like a quiet room otherwise.

## Verification
- [x] Rate limiter exercised directly against prod — burst, refill and cap all
      behave. It is a Postgres function, so this is the real test; a Dart mock
      of it would only prove the mock.
      **Migration 0111 came out of writing that probe.** 0107 used `now()`,
      which is the *transaction* timestamp and therefore frozen for the whole
      call — meaning the refill path could only be "tested" by backdating
      `updated_at` by hand, which tests the backdating as much as the code.
      Switched to `clock_timestamp()`; the probe now sleeps 2.2s and watches
      exactly one token come back. Production behaviour is unchanged (every
      edge-function call was already its own transaction), but the limiter no
      longer silently degrades to one-message-per-transaction if these calls are
      ever batched.
- [x] Word filter probed on prod: single word hits, `Scunthorpe` does **not**,
      case and trailing punctuation still hit, a phrase hits, a partial phrase
      does not, ordinary text is clean.
- [x] Slow mode probed on prod: one through, second refused, still refused after
      1.2s of a 10s setting.
- [x] `test/live_chat_test.dart` locks the payload contract the three coexisting
      client versions depend on: a message with a server id, one without (every
      device in the field on day one), a forged system line on the chat topic,
      and a garbled payload. Plus the composer's 250 cap sitting inside the
      server's 500.
- [x] Full suite green (177 tests), `flutter analyze` clean, `deno check` clean
      on both edge functions.
- [x] Widget tests for the host menu in `test/studio_test.dart`: which actions
      a non-moderator sees, which a moderator sees, that a message with no id
      offers Ban but not Remove, that you cannot moderate yourself, that the
      settings icon is host-only, and that a narrowed room says so. The three
      pre-existing moderation tests were updated — they asserted the old menu
      labels, which is exactly what a label change should break.
- [ ] Two-device manual pass: ban from one, confirm ejection and refused rejoin
      on the other, on both a free and a paid event.
- [ ] Confirm an old build (pre-`send`) still chats normally against the new
      server, since that is the state of every device in the field on day one.
      Nothing was tightened, so this should hold — but it is the assumption the
      whole additive design rests on, and it is worth proving rather than
      believing.
