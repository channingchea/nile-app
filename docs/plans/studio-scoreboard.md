# Studio Scoreboard — Implementation Plan

## Overview
The second real live element, built on the live elements foundation (docs/plans/studio-live-elements-foundation.md). The host picks a sport for each game: basketball, soccer, football, baseball/softball, or a generic two-team board. Teams have names, short codes, colours and logos, and can be saved for reuse. The board can be a corner score bug, a bottom bar, or its own full-screen angle. Score is kept from the Studio, a crew Scorekeeper phone, or both at once. Every viewer's scoreboard updates at the same moment, and the final score shows on the event page and in feeds.

## Decisions (2026-10-26)
- Sports: basketball, soccer, football, baseball/softball, plus a simple generic board.
- Audience: youth/school/rec and semi-pro/leagues equally.
- Teams: name + short code, team colour, logo image, saved teams for reuse.
- Look: the host picks per game, either a compact corner bug or a full-width bottom bar; full-screen board as its own angle.
- Extra clocks: basketball shot clock, football play clock, soccer stoppage time.
- Details on screen: timeouts left, fouls/bonus, down & distance + possession, count/outs/bases.
- Scorekeeping: the host chooses the Studio, a crew Scorekeeper phone, or both. This replaces the foundation's "Studio-only" decision. Both stay live at once; score changes are actions, so two at once both count.
- Scorekeeper phone = a crew member with a Scorekeeper role (no camera).
- Final score: on the ended event page and on replay/event cards in feeds.
- Sync: every viewer's scoreboard updates at the same moment (synced with each other, not with each viewer's video). The existing hold-back only kicks in on its own when RealSync is on; no scoreboard-specific hold-back work.

## Non-goals / Out of scope
- Player stats, rosters, play-by-play and an automatic shot-clock reset on a score. Every reset is a button.
- Data feeds from league or scoring hardware.
- Sports beyond the four plus the generic board.
- Holding each viewer's score back to match their video (spoiler protection), beyond what RealSync already gives when it's on.
- Viewer interaction. The scoreboard isn't tappable.
- Sponsor "presented by" UI. The server hook stays.

## Phase 1: Server rules, teams and roles
- [ ] Add a `scoreboard` kind in `_shared/elements.ts`. Its settings:
  - `sport`: basketball, soccer, football, baseball or generic
  - `style`: bug or bar
  - `home` and `away`: name up to 24 characters, code up to 4, colour, optional `teamId` and `logoPath`
  - period settings per sport, with editable defaults: basketball 4 × 12 min (or 2 halves), soccer 2 × 45 min counting up, football 4 × 15 min, baseball 9 innings (7 for softball), generic with an optional label and clock
  - shot clock length (24, 30 or 35 s) and play clock length (40 or 25 s)
- [ ] State per sport:
  - all sports: scores, period
  - basketball: team fouls, bonus, timeouts left
  - soccer: stoppage minutes
  - football: down, distance, ball-on, possession, timeouts left
  - baseball: inning half, balls, strikes, outs, runners on 1st/2nd/3rd
  - generic: period label
- [ ] Clocks via the existing clock system: `game`, which counts down or up by sport, plus `shot` and `play`. A "set" op handles corrections.
- [ ] Changes as actions, so the Studio and the phone never overwrite each other. A new `ops` list on set-element is applied by the server in order against the latest state:
  - `add` (field, by)
  - `set` (field, value)
  - `toggle`
  - `nextPeriod`
  - `resetCount`, which clears balls and strikes

  Each field is checked against limits for its sport (scores 0–999, outs 0–3, and so on). The rising-version check is skipped for ops-only pushes, but edits to the settings still use it.
- [ ] Migration 0142:
  - `studio_teams` table (owner_id, name, code, colour, logo_path, sport, timestamps) with owner-only access rules, matching `studio_graphics`
  - team logos in the existing graphics storage bucket, under the owner's folder
  - `event_operators.is_scorekeeper boolean`
  - `events.final_score jsonb`
- [ ] Scorekeeper access: a crew member flagged `is_scorekeeper` may push ops and clock changes to scoreboard elements only. No settings, other kinds, graphics or show control. The host and the Studio can do everything.
- [ ] Final score: at end of show (stop-egress, sweep and room_finished), write the on-air scoreboard's teams, codes, colours, scores and sport into `events.final_score`. If several are up, take the most recently changed one.
- [ ] Deno tests: settings validation per sport, field limits, two keepers adding at once both count, scorekeeper limits, final score snapshot.

## Phase 2: App model
- [ ] `ScoreboardConfig` and `ScoreboardState` in `live_elements.dart`, plus the `scoreboard` kind spec. Shared sport defaults live in one table: periods, clock direction, score buttons, details shown.
- [ ] Formatting:
  - clocks as mm:ss, tenths under a minute for basketball, soccer as `45:00 +3`
  - period labels: Q1–Q4 and OT, 1H/2H, ▲7 or ▼7, and the custom label for generic
  - football: "3rd & 7 · OPP 32"
  - baseball: count as "2-1", plus outs
- [ ] An ops builder that both the Studio and the phone use, so the same buttons send the same actions.
- [ ] `TeamsService`: list, save and delete saved teams; upload a logo (resized, size-capped).
- [ ] Unit tests for formatting, ops and sport defaults.

## Phase 3: Look
- [ ] Renderers in `element_kinds.dart`, styled from the brand kit with team colours on each side:
  - **Corner bug** (default spot: top left): codes, logos, scores, period, game clock; a shot clock or play clock chip; one detail line ("3rd & 7", "B 2-1 · 2 OUT" with a base diamond, fouls/bonus dots, timeout pips).
  - **Bottom bar** (bottom centre, full width): full team names and the same details spread out.
  - **Own angle**: a big centred board with the full detail.
- [ ] Missing logo: the team's code on its colour.
- [ ] Scales with the picture (the same `u` unit): upright and sideways phones, desktop, and grid replay tiles.
- [ ] Widget tests for each sport in both styles plus the angle look, and an overflow check at the smallest tile.

## Phase 4: Studio
- [ ] Editor:
  - sport picker with presets
  - home and away pickers: from saved teams, or a new team that can be saved
  - style; period and clock settings
  - a contrast warning when a team colour clashes with the panel
- [ ] Live controls:
  - score buttons per sport: basketball +1/+2/+3; football TD +6, PAT +1, 2-pt +2, FG +3, safety +2; soccer, baseball and generic +1
  - −1 corrections
  - game clock start/stop/set; shot clock and play clock reset buttons; soccer stoppage +/−
  - next period
  - per-sport detail controls: fouls, timeouts, down & distance, possession, ball-on, balls/strikes/outs, runners, inning half
- [ ] Shortcuts while the Elements panel is open:
  - Space = game clock start/stop
  - 1/2/3 = home points, Shift+1/2/3 = away points
  - S = shot clock reset
  - N = next period
  - The existing undo (×10) covers mistakes.
- [ ] Studio Preview: a demo game that ticks along (occasional scores, a running clock) so hosts can rehearse the controls locally.
- [ ] Widget tests for the editor rules and controls.

## Phase 5: Scorekeeper phone
- [ ] Crew setup: the host can mark a crew invite as "Scorekeeper" on the event's crew screen, next to the camera and audio roles. They're notified the same way camera crew are.
- [ ] A Scorekeeper screen (`NileMaxWidth`, phone first) with the same score buttons and clocks as the Studio, in large tap targets. The screen stays awake, and the controls are usable one-handed in portrait.
- [ ] Joining: the scorekeeper joins the room without a camera or mic (data only) and sees the live scoreboard.
- [ ] Changes from the Studio show on the phone at once, and the other way round. Changes made while offline are refused with "Reconnecting — score not sent" rather than queued.
- [ ] Multiple scoreboards on air: the phone shows a picker.
- [ ] Widget tests for the screen, plus the scorekeeper access checks (Deno).

## Phase 6: Final score, replay and verify
- [ ] Ended event page: "Final · WIL 54 – 48 HAW", with logos and colours, for everyone.
- [ ] Event cards in feeds and replay cards: a compact final score chip.
- [ ] The grid replay already shows the board as it was. Confirm clocks read correctly from the recording's time.
- [ ] PostHog: `sport` and `style` properties on the existing element events, plus `scorekeeper_joined`. No team names.
- [ ] Old builds: an unknown kind is dropped. Covered by the `min_build` bump at ship.
- [ ] Full Flutter and Deno test pass, analyzer clean, iOS, Android and macOS builds.
- [ ] On-device checklist:
  - Studio and phone scoring at once
  - clock accuracy over 10 minutes
  - the Studio drops out and the clock keeps running
  - several viewer devices show score changes and clocks together
  - all sports in both styles on phones, upright and sideways
  - final score on the event page and cards

## Open questions / risks
- No spoiler protection without RealSync: a viewer whose video lags several seconds (a struggling connection), or a courtside scorekeeper tapping before the video arrives, can show the score before the play. Usually small, because video reaches viewers in well under a second and the scorekeeper taps after seeing the play.
- Clock accuracy depends on each device's server clock offset. A phone with a bad offset could show the clock a second off. The existing clock-sync ping limits this.
- Last change wins for settings edits (team names, colours) made from two places at once. Score changes are safe because they're actions.
