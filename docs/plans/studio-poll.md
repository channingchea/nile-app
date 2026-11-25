# Studio Poll — Implementation Plan

## Overview
The first real live element, built on the live elements foundation (docs/plans/studio-live-elements-foundation.md). Hosts can run four poll types: multiple choice, yes/no, rating 1–5, and pick several. A poll can sit on any camera or be shown as its own angle. Viewers vote by tapping and can change their vote until it closes. Results follow a visibility setting the host picks for each poll, and they appear in replays and on the host's results page.

## Decisions (2026-10-23)
- Types at launch: multiple choice, yes/no, rating 1–5, pick several.
- Multiple choice: 2–6 answers, text only. Pick several: the host sets a limit (default: any number).
- Results visibility is set per poll: live, after you vote, or only when revealed.
- Ending: the host taps Close, or an optional timer with an on-screen countdown. No winner highlight.
- After close: Reopen (votes kept), Reset and run again (votes cleared), Reveal (reveal mode).
- Rating results: average plus a bar per star.
- Phones: tapping the poll opens a vote sheet with big buttons. Larger screens: answers can be tapped on the card itself.
- Default spot: middle right. Totals read as percent plus total votes.
- Live edits: wording fixes only; answers can't be added, removed or reordered once votes exist.
- Nudge: a "Poll is live" pill for viewers on an angle where the poll isn't showing. No chat line.

## Non-goals / Out of scope
- Images or emoji in answers. Answers are text only.
- Chat-based voting and a "poll is live" line in chat.
- Highlighting the winner when a poll closes.
- Showing who voted for what. Hosts see totals only.
- Sponsor "presented by" UI. The server hook stays.

## Phase 1: Server rules and votes
- [x] Add a `poll` kind in `_shared/elements.ts`. Its settings:
  - `type`: choice, yesno, rating or several
  - `question`: up to 120 characters
  - `answers`: 2–6 items, each with a stable id and text up to 40 characters. Yes/no and rating fill these in automatically.
  - `maxPicks`: pick several only, 1 up to the number of answers; blank means any number
  - `results`: live, voted or reveal
  - `timerSec`: optional, 10 s to 30 min
- [x] Poll state: `open`, `revealed`, `closesAt` (stamped by the server), and `round` (goes up on each reset).
- [x] Wording-only edits: while a poll is open or has votes, the push may change text but not answer ids, their order or their number. Otherwise it's refused with "Close and reset the poll to change its answers".
- [x] Migration 0141, pick several:
  - add `element_responses.picks text[]`, filled from today's `choice`
  - `element_respond` takes a list of picks
  - `element_tally` counts across picks and also returns how many people voted, so "212 votes" is right when people pick several
  - votes carry the poll's `round`
- [x] `respond` accepts `picks: []`. It checks each pick against the answers, against `maxPicks`, and that there are no duplicates. After `closesAt` it refuses with "Voting has closed", whether or not the Studio is still connected.
- [x] Timer: a new `timer` op on set-element (start or cancel) sets `closesAt` from the server's clock. Viewers and the Studio count down to it.
- [x] Reveal mode: while a poll isn't revealed, totals aren't broadcast to viewers or returned to them. The host always gets them. Revealing sends the current totals at once. Timeline marks keep recording, so the replay shows totals after the reveal.
- [x] Reset: a set-element op clears the poll's votes, bumps `round` and broadcasts zero totals. Reopen just sets `open` again.
- [x] Tally payload gains a `voters` count. Older builds ignore it.
- [x] Deno tests: settings validation, wording-only edits, picks rules, timer close, reveal withholding, reset.

## Phase 2: App model
- [x] Add `PollConfig` and `PollState` to `live_elements.dart`, plus the `poll` kind spec:
  - choices = answer ids
  - each kind gets a way to supply labels for its choices, so the results page shows answer text and not raw ids (the counter keeps its ids)
- [x] Results maths:
  - percentage per answer, out of people who voted for pick several and out of votes for the others
  - rating average to one decimal, with the 1–5 breakdown
  - an empty state when nobody has voted
- [x] Visibility rule `resultsVisibleTo(viewer)`:
  - live = always
  - voted = after this viewer votes
  - reveal = once revealed
  - Studio, host and replays = always
- [x] Default spot middle right; full-screen look when shown as its own angle.
- [x] Unit tests for parsing, percentages, average and visibility.

## Phase 3: Poll look
- [x] Renderer in `element_kinds.dart`, styled from the brand kit with the "Use Nile style" option:
  - card on a camera: question, answers with % bars, "212 votes", countdown, "Closed"
  - larger layout when shown as its own angle
- [x] States: open, closed, results hidden ("Results after you vote" / "Results soon"), revealed, and the viewer's own vote marked.
- [x] Rating look: five tappable stars while open; average plus breakdown when results show.
- [x] Scales with the picture size (the same `u` unit), so it reads on an upright phone, a sideways phone, desktop and a grid replay tile.
- [x] Widget tests for each state, plus a check that nothing overflows at the smallest tile size.

## Phase 4: Studio
- [x] Editor:
  - type picker, question, answers (add, remove and reorder only before any votes)
  - max picks, results visibility, default timer (none, 30 s, 1 min, 2 min, 5 min, custom)
  - warnings: fewer than two answers, a duplicate answer, an empty question
- [x] Live controls: Open/Close, start or cancel the timer, Reveal (reveal mode only), Reopen, Reset (with a confirm). Live totals and voter count, which the host always sees.
- [x] Shortcuts while the Elements panel is open: O = open/close, V = reveal, T = start timer.
- [x] Wording-only editing while live, with a note when answers are locked.
- [x] Studio Preview: fake votes for all four types, honouring max picks for pick several and spreading ratings around about 4. The timer and reveal work locally.
- [x] Widget tests for the editor rules and controls.

## Phase 5: Viewer voting
- [x] Phones: tapping the poll opens a bottom sheet with big answer buttons. Tablets and desktop: answers can be tapped on the card itself.
- [x] Pick several: choose answers, then Submit, which is disabled past the limit. Changing a vote replaces the whole set.
- [x] Rating: tap a star.
- [x] Not signed in: the sheet says "Sign in to vote".
- [x] "Poll is live" pill:
  - shows for viewers on an angle where an open poll isn't on screen
  - tapping it opens the vote sheet
  - it hides once they've voted or the poll closes, and can be dismissed for that poll
- [x] Taps are refused under a full-screen slate, as today. Votes land under the 1-per-second limit, with friendly errors for "closed" and "too fast".
- [x] Old builds: an unknown kind is dropped, so nothing breaks. Covered by the `min_build` bump at ship.
- [x] Widget tests for the sheet, pick several, the pill and visibility.

## Phase 6: Results, analytics, verify
- [x] Host results page: answer text in place of ids, the rating average and the voter count. Reset rounds show only the latest round.
- [x] Grid replay: totals follow the visibility rule using the recorded state (hidden until revealed in reveal mode).
- [x] PostHog: a `poll_type` property on the existing element events (no question text, no answers).
- [x] Full Flutter and Deno test pass, analyzer clean, iOS, Android and macOS builds.
- [ ] On-device checklist (needs a real show):
  - vote, change and close from two phones
  - timer closes with the Studio quit
  - reveal flow
  - pick-several limit
  - pill on another angle
  - replay shows the right totals at the right moments

## Open questions / risks
- In "after you vote" mode, totals still go out to every viewer's device and the app just hides them. Reveal mode is enforced on the server. That's fine for a fan poll, but a determined person could read the numbers early.
- Votes from before a reset are deleted, not archived, so the results page only knows the last round.

## Implementation notes (2026-10-26)
- Server: `poll` kind + `cleanPollConfig` in `_shared/elements.ts`; pushes carry `ops` (`timer` start/cancel, `reset`) applied by `pollServerState` with the server clock. `closesAt` and `round` can't be written by the Studio. Answers changing (`reshapes`) is refused with 409 while open or holding votes, unless the same push resets.
- Migration 0141 (applied to prod): `element_responses.picks text[]` + `round int`; new overloads `element_respond(…, p_picks, p_round)` and `element_tally(…, p_round)` → `{counts, voters}`. `choice` and the old overloads stay for the previously deployed function.
- Reveal mode: unrevealed totals go out on `live_mod:<slug>` (moderators, host included) instead of `live_system`; a reveal or reset sends totals at once. Replay marks always record (`{elementId, tally, voters}`). Chat moderators can read hidden totals too — they're crew.
- `respond` takes `picks: []` (older builds: `choice`) and returns `mine` + `picks`; `my-responses` returns this round's votes only. `livekit` deployed 2026-10-26.
- App: `ElementTally` is now a class (counts + voters); `ElementInteraction` carries `mine` as a list, `onTap(List<String>)`, `audience` (viewer/staff/replay) and `needsSignIn`. `ElementOps` ride on one push (`LiveElement.ops`, never stored); the controller applies them locally and clears totals on reset.
- UI in `lib/widgets/elements/poll.dart`: `PollView`, `showPollVoteSheet`/`PollVoteSheet`, `PollLivePill`, editor and live controls. Phones = short side under 600 pt (`NileBreakpoints.minHeightForRail`).
- Opening a poll with a default timer starts the countdown; Reopen keeps votes and drops a finished timer.
- Verified: analyzer clean, 415 Flutter tests (21 new in test/studio_poll_test.dart), 75 Deno (money_test failure pre-existing). SQL self-tested on prod in a rolled-back block.
