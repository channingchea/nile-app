# Studio Layouts — Implementation Plan

## Overview
Layouts are saved show setups kept in an account-wide library and opened from a new Studio toolbar icon next to Graphics and Elements. Applying a layout restores the whole show at once — graphics and elements on each camera with their spots and layer order, cameras on/off air, the default angle, element angles and camera order — while viewers stay free to pick their own angle. It's Nile's take on Evmux's Pro Scenes, without composing cameras into one picture.

## Decisions (Channing, 2026-11-01)
- Viewers always pick their own angle; Send everyone is the only way to move them.
- v1 = saved setups + templates. No combined angles.
- One account-wide library.
- Cameras are matched by position ("Camera 1, 2…"); cameras beyond a layout's count are left as they are.
- Apply replaces everything on the cameras the layout covers.
- Create by "Save current look" and by an editor.
- Elements already live keep their state (votes, timers); otherwise they start fresh.
- A layout also saves: cameras on/off air, default angle, element angles, camera order.
- Templates: Starting Soon, Be Right Back, Ending, Main show.
- Transition: the existing quick graphics fade (250 ms).
- Hotkeys: ⌥1–9 cues from anywhere in the Studio, Enter applies.
- Editing an on-air layout does not change air; re-Apply. Panel shows "Changed since applied".
- Missing library items: skip and warn.
- Camera tile "Layout…" sheet renamed "Layers…".
- "Take" renamed "Apply" across the whole Studio.

## Non-goals / Out of scope (v1)
- Combined angles (side by side, picture-in-picture, grid)
- Forcing viewers onto an angle
- Per-layout transitions or stinger videos
- Share/import codes, portrait-specific positions, free crop/rotate
- Live-updating an on-air layout

## Phase 1: Rename + data model
- [x] Rename camera tile "Layout…" sheet to "Layers…" (menu label, dialog title, tooltips, tests)
- [x] Rename "Take" → "Apply" across the Studio (Graphics panel Take / Take all, element HUD cued card, shortcut hints, Studio Preview, tests)
- [x] Migration `0144_studio_layouts.sql`: `studio_layouts` (`id`, `owner_id`, `name` 1–60, `payload` jsonb ≤16 KB, `template` text null, `sort`, `created_at`, `updated_at`), touch trigger reusing `studio_graphics_touch`, RLS owner-only read/write
- [x] `lib/services/studio_layouts.dart`: `StudioLayout` model + JSON. `cameras[]` by position, each with graphics (library ref, spot, auto-hide), elements (library ref, spot, angle on/off), layer list, onAir; plus `defaultAngle` (position or element angle) and `order` (positions)
- [x] Position = Nth camera by `slot_index` (creation order), NOT display order, so applying a layout that reorders cameras doesn't shift what "Camera 2" means
- [x] `LayoutsService`: list, create, update, rename, duplicate, delete, reorder (via `guard`)

**Implementation notes (2026-11-01):** user-facing text only — identifiers like `onTake`/`_take` stay. "Take off air" keeps its wording (a different verb). The sheet file is now `lib/widgets/studio_layers_sheet.dart` (`showLayersSheet`, `LayersChoice`, `onLayers`). Migration 0144 applied on prod: also a 100-layout cap trigger like studio_elements. Payload JSON: `{v:1, cameras:[{items:[{g|e:id, spot?, hidden?, autoHide?}], onAir?}], angles?:[elementId], defaultAngle?:{cam:n}|{el:id}, order?:[…]}` — items run front to back. Positions are 1-based; `positionsOf(List<CameraSlot>)` sorts by `slotIndex`. Services are `lib/services/studio_layouts.dart` (model, snapshot, resolve) and `lib/services/layouts_service.dart`; validation errors are thrown before `guard` so their message survives.

## Phase 2: Snapshot + resolve (pure, unit-tested)
- [x] `snapshotLayout(...)` from GraphicsState + live elements + overlay layout + ShowControl → StudioLayout ("Save current look"). All-cameras graphics become per-camera entries; items not in the library (e.g. chat-on-screen) are left out with a note
- [x] `resolveLayout(layout, slots, library)` → target on-air state + missing list. Extra cameras untouched; deleted refs skipped; covered cameras fully replaced
- [x] Tests: position mapping, extra cameras, fewer cameras than the layout, missing refs, snapshot→resolve round trip, order change doesn't shift positions

**Implementation notes (2026-11-01):** both in `studio_layouts.dart`; 20 tests in `test/studio_layouts_test.dart`. Rules decided while building:
- A graphic or element already up keeps its live value (running countdown, votes) wherever the layout keeps it; only items not up yet are built fresh. An item deleted from the library but still on air counts as found.
- A graphic that ends up on every camera goes on as "All cameras" (so the Graphics panel reads right); otherwise per camera. An all-cameras graphic the layout drops gets the covered cameras added to its "except"; if that excludes every camera it comes off entirely.
- Element angles are replaced show-wide by the layout's list; an angle that appears or goes loses any old off-air mark.
- Default angle: null in the layout = first on-air camera; one the show can't meet (Camera 5 of 3, an element not shown as an angle) keeps the current default. Order: the layout's order first, then anything else in the show's current order; empty = leave as is.
- `ResolvedLayout` gives graphics, overlay layout, show control, changed elements, covered slots, `missing` (with camera position; null = an angle) and `skippedCameras` (layout cameras the show doesn't have).
- Snapshot leaves out anything not in the library (chat on screen, sponsor logos) and names it in `leftOut`; saved auto-hide is null (= the library graphic's own).

## Phase 3: Server Apply
- [ ] `_shared/layouts.ts`: validate a resolved layout, reusing graphics/layout/show/element validators
- [ ] livekit action `apply-layout`: one room-metadata write for graphics + layout + show (offAir, defaultSlot, slotOrder) so viewers never see half a layout; stores `layoutApplied: {id, updatedAt}`
- [ ] Elements through the existing versioned element push: live ones keep state, new ones start from library config, elements not in the layout come off air on covered cameras
- [ ] Deno tests: atomic write, extra cameras untouched, element state kept, non-host refused

## Phase 4: Toolbar icon + Layouts panel
- [ ] Layouts icon in the control bar between Elements and Resync; opens a side panel
- [ ] Cards: thumbnail (Camera 1 rendered with NileGraphicsLayer on the brand background), name, badges "On air", "Cued", "Changed since applied", "N missing"
- [ ] Card menu: Rename, Duplicate, Delete (confirm); drag to reorder
- [ ] "Save current look" (name prompt) and "Update from current look"
- [ ] Cue → Apply: cue shows a per-camera summary of changes (off air, items added/removed); Apply or Enter sends it
- [ ] Hotkeys: ⌥1–9 cues the first nine layouts from anywhere in the Studio; Enter applies; plain 1–9 stays with Graphics

## Phase 5: Layout editor
- [ ] Full dialog: a tab per camera position (+/− count), live preview frame
- [ ] Per camera: add library graphics/elements, spot grid + layer list (reuse "Layers…" widgets), on/off-air switch, element-angle toggles
- [ ] Layout-wide: default angle picker, camera order list, "Copy to all cameras"

## Phase 6: Templates
- [ ] "New from template" copies into the library, creating needed library graphics and using the brand kit:
  - Starting Soon: full-screen slate + countdown to show start
  - Be Right Back: slate; Cameras 2+ off air
  - Ending: thanks slate + QR to profile
  - Main show: logo bug + lower third on Camera 1
- [ ] Tests: each template resolves cleanly on 1-camera and 3-camera shows

## Phase 7: Studio Preview, analytics, ship
- [ ] Studio Preview: library read-only, Apply in memory (follow PreviewElementLibrary pattern + preview safety test)
- [ ] PostHog: `layout_saved`, `layout_cued`, `layout_applied`, `layout_missing_items` (counts only, `preview` flag)
- [ ] Grid replay check: an Apply appears as one change
- [ ] Bump `min_build` at ship; add Layouts to the on-device checklist

## Open questions / risks
- One cue at a time? Default: cueing a layout clears cued graphics and vice versa, so Enter never applies two things.
- Should "Save current look" in Studio Preview write to the real library? Default: no (keeps Preview touching nothing real).
- Room-metadata size for big layouts — measure against LiveKit's metadata limit in Phase 3.
- Older builds miss off-air/order changes until the `min_build` bump.
