# Studio Element HUD — Implementation Plan

## Overview
A persistent strip of compact cards, docked between the monitor and the control bar, giving the host quick controls for every element that is on air, on its own angle, or cued — without opening the Elements panel. Each kind describes its card as data (buttons, toggles, timers, readouts, inputs) instead of a custom widget, so the same HUD will later draw third-party plugin elements, which can only ship data, not code.

Wireframe: claude.ai artifact "Studio Element HUD wireframe" (2026-10-26).

## Decisions (2026-10-26)
- Placement: strip above the control bar; never covers video. Desktop Studio + Studio Preview only.
- Host only.
- Two dismiss actions per card: ✕ hides the card only; "Off air" takes the element off every camera and its own angle (votes kept).
- Quick controls only. Poll card: Open/Close, Timer, Reveal, vote count. Reset, Edit, Undo and per-answer totals stay in the panel, reached by "Open in panel".
- Cued elements get a dimmed card with Take (takes only that element).
- Shortcuts stay panel-only; HUD buttons show no key hints.
- Building-block vocabulary for every kind: buttons & toggles, timers, readouts, text/number inputs.

## Non-goals / Out of scope
- Phone host screen (later phase).
- Co-host / crew access.
- The plugin system itself: upload, review, manifest format, server rules for plugin kinds.
- Reset, editing and per-answer breakdowns in the HUD.
- Dragging or reordering cards.

## Phase 1: The HUD vocabulary
- [x] `lib/services/element_hud.dart` — sealed `HudItem` with plain, JSON-ready data:
  - `HudButton` — id, label, optional icon name, style (primary/danger/neutral), `active` (toggles), `enabled`, optional `confirm` text
  - `HudTimer` — running, seconds left, preset durations, start/stop action ids
  - `HudReadout` — label/value, tone (normal/accent/dim)
  - `HudInput` — id, label, text|number, value, min/max or max length
- [x] `toJson`/`fromJson` on each + round-trip test (keeps it plugin-ready).
- [x] `ElementKindUi` gains `hud` (element + tally + now → items) and `hudAct` (action id + optional value → `ElementChange`).
- [x] Poll: `hud` builds Open/Close, Timer, Reveal (fixed when results are live), vote-count readout, "Hidden from viewers" readout until revealed. `hudAct` reuses `pollToggleOpen`, `pollStartTimer`, `_cancelTimer`, `pollReveal`.
- [x] Counter (debug test kind): −1/+1 buttons, value readout, "Set to" number input, its clock as a timer.
- [x] `controls` becomes optional; a kind without custom panel controls gets its HUD items drawn in the panel.
- [x] Unit tests: poll HUD items per state (closed, open+timer, revealed, live mode) and `hudAct` matching the panel's changes.

## Phase 2: The HUD strip in Studio Preview
- [x] `lib/widgets/studio_element_hud.dart`: `ElementHudStrip` (fixed-height horizontal scroller, animates in/out), `HudCard` (header with ON AIR / ANGLE / CUED chip + name; items; Open in panel, Off air, ✕), `HudItemsView` (draws the blocks; also used for the panel fallback).
- [x] `NileStudio` gets an optional `hud` slot between `_StudioMonitor` and `_StudioControlBar`.
- [x] Hidden cards: per-session set on `StudioElementsController`; "N hidden" chip at the end of the strip restores them; a card un-hides when its element leaves air and comes back.
- [x] Off air: targets none + angle off in one push, then a "… taken off air · Undo" snackbar that restores both.
- [x] Open in panel: `showElementsPanel` takes `initialSelected`.
- [x] Inputs submit on Enter / focus loss and don't keep Studio keyboard focus.
- [x] Wire into `studio_preview_screen.dart` (simulated votes move the readouts).
- [x] Widget tests: cards follow on/off air, hide/restore, Off air + Undo, scrolling with 5+ cards.

## Phase 3: Cued cards and the live Studio
- [x] Cued card: dimmed, camera summary, Take, Remove from cue.
- [x] `takeElement(id)` on both host screens — takes only that element; the rest of the cue stays.
- [x] Wire the strip into `camera_screen.dart` (desktop Studio only, not `isCompact`).
- [x] PostHog: `element_hud_action` (kind, action id, `preview`) and `element_hud_hidden`; kinds and counts only.
- [x] `flutter analyze` + full test suite; add HUD items to the on-device checklist in `studio-live-elements-foundation.md`.

## Implementation notes (2026-10-26)
- Data: `lib/services/element_hud.dart` (sealed `HudItem`; `HudItem.fromJson` drops unknown types). Icons are a fixed name set in `HudItemsView._icons` (check, visibility, timer, add, remove, play, pause, stop, next, refresh, star).
- Layout rule: buttons/timers/inputs in one row, readouts joined with " · " on the line below. Cards size to their content (280–520 px wide, 120 px tall) inside a horizontal `ListView`.
- Poll: `pollHud` / `pollHudAct` in poll.dart; actions `open`, `timer` (value = seconds), `stopTimer`, `reveal`. Readouts: votes, rating average, Closed, and "Hidden from viewers" / "Shown after voting" / "Viewers always see totals".
- Counter: actions `down`, `up`, `set` (number), `clock`, `taps`.
- Controller: `liveElements` (library order), `hudHidden`/`setHudHidden`/`showAllHud` (cleared when an element's on-air state changes), `takeOffAir`, `putBack`.
- `ElementHudControls` = items + Ticking + action→change; used by the cards and as the panel fallback when a kind has no `controls`.
- Screens: Studio Preview always; live Studio only on the control-room device (`_isStudio`). Take one: `_takeOne` / `_takeOneElement`.
- Analytics: `element_hud_action` {kind, action, preview}, `element_hud_hidden` {kind, preview}.
- Tests: test/studio_element_hud_test.dart (12). 430 Flutter tests, analyze clean.
- [ ] On-device pass (in the foundation plan's checklist).

## Designed for plugins (no plugin work here)
- A card is a list of building blocks → a future plugin manifest describes its HUD in JSON and Nile draws it with `HudItemsView`.
- Actions are addressed by id → a plugin action becomes a declared state change the server validates, like element pushes today. No downloaded code (App Store rules).
- A kind without custom panel controls gets a working panel from its HUD items automatically.

## Open questions / risks
- On short desktop windows the strip (~140 px) takes height from the monitor; check at the smallest Studio window.
- Undo after Off air restores placement, not a timer that ran out meanwhile.
- No server change expected (Off air and Take reuse existing pushes), so no migration and no min_build bump for this feature.
