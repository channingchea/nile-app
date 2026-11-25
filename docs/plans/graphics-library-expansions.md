# Graphics Library Expansions — Implementation Plan

## Overview
Four additions to the Studio graphics library: cue before air, a brand kit, a QR code graphic, and an in-show sponsor logo. Graphics stay what they are today — a small description in room metadata that every viewer's app draws itself — so none of this touches the video. Everything must be rehearsable in Studio Preview.

## Non-goals / Out of scope
- Tip goal bar and live data graphics (viewer count, tip progress) — deferred.
- Multiple brand kits; uploading custom font files.
- Graphics in replays (they aren't today; unchanged).
- Paid in-show sponsorship (the logo is a free bonus at the host's choice).
- A "tip page" QR link (no tip URL exists yet).

## Phase 1: Cue before air (Studio only, no server change)
- [x] Studio-local cue state (graphic + targets); never sent to the server.
- [x] Clicking a library item cues it (replacing any cue); item shows a CUED chip; panel gets Take (Enter) and Clear (Esc). Taking a graphic off stays one click.
- [x] Countdown end and auto-hide are stamped at Take, not at cue.
- [x] Cued graphic drawn on the Studio monitor with a CUED outline; CUED badge on target camera tiles.
- [x] Hotkeys 1–9 cue onto last-used cameras; Enter takes; Esc clears; ignored while a text field has focus.
- [x] Chat "Show on screen" goes through the cue too.
- [x] Studio Preview supports it.
- [x] Tests: cue never calls set-graphics, Take stamps times, Esc clears.

## Phase 2: Brand kit
- [x] Migration 0135: `brand_kits` (owner_id pk, accent/panel/text_color #RRGGBB, font from curated list, logo_path, updated_at), owner-only RLS.
- [x] Curated ~12 Google Fonts list shared in Dart + TS; default = Nile font.
- [x] `BrandKit` model + service; default logo uploads to the `studio-graphics` bucket.
- [x] `set-graphics` accepts a validated `brand` object, stored as `graphics.brand` in room metadata; Studio re-pushes when the kit is edited mid-show.
- [x] Library payload `nileStyle: true` opt-out; editor switch "Use Nile style".
- [x] NileGraphicsLayer resolves a graphics theme: accent → stripe/banner/countdown, panel → card/slate background, text → text (subtitle 70%), kit font with Nile fallback.
- [x] Brand kit editor (Graphics panel + Studio Preview): 3 colour pickers (hex + swatches), font dropdown, logo upload, live 16:9 preview, warn-only contrast note.
- [x] New logo graphics prefill with the kit's default logo.
- [x] Tests: validation both sides, kit vs Nile style rendering, old graphics unchanged.

## Phase 3: QR code graphic
- [x] `GraphicKind.qr` + migration (enum value + payload check: source custom|event|profile, url https ≤500, corner, size, caption ≤40).
- [x] Event/profile sources saved as the source and resolved at push (links.joinnile.com/e/<id>, /u/<username>).
- [x] `qr_flutter`; any corner, own `qr:<corner>` cap; sits inward beside a logo in the same corner.
- [x] Modules always dark-on-light; kit styles frame + caption only.
- [x] Viewer-only tap: "Leave Nile to open <domain>?" confirm (Nile links open in-app); not tappable on operator phones/Studio.
- [x] Server `qr` validation (https only, length cap).
- [x] Studio Preview demo + tests.

## Phase 4: Sponsor logo
- [x] Website advertiser portal: optional square logo upload on Pre-Show sponsorship offers (`ad-creatives` bucket), help text "may appear on screen during the show at the host's choice"; reviewed in the existing queue.
- [x] Migration 0136: `ad_creatives.logo_path`; `ad_events.surface` (null = existing, 'in_show'); `get_lobby_sponsorship` returns logo + advertiser name.
- [x] Built-in "Sponsor: <name>" library item when the event has an accepted sponsorship; corner + size at push.
- [x] Studio sends `campaignId` only; server verifies it is this event's accepted sponsor and fills logo URL + name; shares the logo corner cap; no logo → "Sponsored by <name>" badge in kit style.
- [x] `log_in_show_sponsor_impression(p_campaign_id, p_event_id)`: once per viewer per event, only while live, accepts active/completed lobby campaigns.
- [x] `tally-ad-spend` ignores surface='in_show'; sponsor report shows in-show impressions separately.
- [x] Viewer screen logs the impression on first render; Studio/operators never log.
- [x] Tests: eligibility, no foreign image URLs, impression rules, spend tally unaffected.

## Phase 5: Verify & ship
- [x] Full Flutter + Deno tests, analyze clean, iOS/Android/macOS debug builds.
- [ ] Studio Preview rehearsal of all four features.
- [ ] On-device checklist: QR scan from a second screen, tap-through on a phone, kit font on cold cache, sponsor impression counted once.
- [x] Old builds drop unknown kinds and ignore `brand` (draw Nile style) — no min_build bump needed.
- [x] Commit on `macos-phase5-router` (app) / `main` (website); push only on approval.

## Open questions / risks
- Google Fonts are fetched on first use; slow or offline viewers briefly see the Nile font.
- Warn-only contrast lets a host ship hard-to-read colours.
- QR-beside-logo stacking is an assumption (alternative: block the corner).

## Implementation notes (2026-10-23)
- Migrations 0135, 0135a, 0136, 0136a, 0137 applied to prod. livekit + create-ad-payment deployed.
- Brand kit gained a 4th colour, "Banner text" (`onAccent` / `brand_kits.accent_text`): one text colour can't read on both a dark panel and a bright accent. Starter kit = Nile look with dark banner text.
- Brand rides on `GraphicsState.brand`; `forSlot` attaches it to each graphic (`LiveGraphic.brand`, never sent per graphic). The Studio attaches the kit on every push and re-pushes when the kit changes.
- Cue lives in the Studio (`ValueNotifier<GraphicCue?>`); `GraphicCue.build(now)` runs at Take, so countdown/auto-hide start then. Monitor shows `cue.preview`; tiles keep showing what is really on air + a CUED chip. Cue bar sits under the stats row. Taking a graphic off is never cued.
- QR: layer has per-slot IgnorePointer; only QR codes take taps and only where `onTapLink` is given (viewer screen). Nile links open in-app via `DeepLinkService.openInApp`; others confirm first. QR in a logo's corner sits inward beside it.
- Sponsor: Studio sends `campaignId` only; `set-graphics` looks up the event's active/completed lobby campaign and fills name + logo. Impressions: `log_in_show_sponsor_impression`, `ad_events.surface='in_show'`, own unique index (once per viewer per campaign); old hourly dedupe index now `surface is null` only. Existing report numbers exclude in-show; `get_advertiser_performance.in_show_impressions` is new. `tally_ad_spend` already skips lobby campaigns, so nothing bills.
- Website (nile-website): logo upload (square, ≤1 MB, ≥200 px; non-square rejected, not cropped), "+N in-show logo" in reports + CSV column, logo shown in admin review.
- Known limits: sponsor corner/size is remembered only while the Graphics panel is open; Enter inside the panel is always captured; cued graphic's custom auto-hide isn't shown when reopening its Cameras dialog.
