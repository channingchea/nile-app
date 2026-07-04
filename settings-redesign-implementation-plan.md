# Settings Redesign — Implementation Plan

## Overview
Restructure the own-profile Settings screen from today's flat list of individually-separated tiles into Revolut-style grouped cards. Each section becomes a single rounded `bgSurface` card holding its rows stacked inside (no dividers between rows), with a small UPPERCASE section label above each card. This is a visual/organizational refactor plus one behavioral change: Appearance moves from an inline theme picker to a row that navigates to a dedicated screen.

## Goals & Non-Goals

**Goals**
- Group settings rows into labeled section cards: Experience, Events, Security, (standalone) Sign out, Danger zone.
- Match the reference image: one rounded card per section, rows stacked inside with no divider lines, per-row tap ripple.
- UPPERCASE section headers (reuse `NileTextStyles.labelSm`, consistent with today's `APPEARANCE` header).
- Move the theme Light/Dark/System picker out of the inline card into a new `AppearanceScreen`; "Appearance" becomes a normal tappable row with a chevron.
- Preserve all existing navigation targets, the sign-out confirm dialog, and the typed-DELETE dialog.

**Non-Goals**
- No changes to any destination screen (Edit profile, My tickets, Payouts, Interests, Notifications, Change password, Blocked accounts) beyond the new Appearance screen.
- No changes to `ThemeService`, theme persistence, or the `ThemeModePicker` widget itself.
- No new settings entries, reordering beyond the specified grouping, or copy changes.
- No backend/data/migration work.

## User Flow / UX
The user opens Settings and sees vertically stacked section cards, each preceded by an uppercase label:

- **EXPERIENCE**: Appearance → Edit profile → Your interests → Notifications
- **EVENTS**: My tickets → Payouts
- **SECURITY**: Change password → Blocked accounts
- **(no header)**: Sign out — its own standalone card, coral/error color
- **DANGER ZONE**: Delete account — coral/error color

Tapping any row behaves as it does today (push its screen or open its dialog), except **Appearance**, which now pushes a new `AppearanceScreen` containing the existing three-option theme picker. Selecting a theme there still applies instantly app-wide via `ThemeService`.

## Technical Approach
All work is in `lib/screens/settings_screen.dart` plus one new file `lib/screens/appearance_screen.dart`. Styling uses existing tokens only (`NileColors`, `NileTextStyles`, `NileRadius`, `NileSpacing`); body stays wrapped in `NileMaxWidth`.

**New grouped-card structure.** Replace the flat `ListView` children with a set of section blocks. Introduce two small private helpers in the file:
- `_SettingsSection` — renders an optional uppercase header (`NileTextStyles.labelSm`) followed by one `Material`/rounded `bgSurface` card (`NileRadius.lg`, `clipBehavior: antiAlias`) wrapping a `Column` of rows. Bottom margin between sections via `NileSpacing`.
- `_SettingsRow` — the icon + label + chevron row (adapted from today's `_SettingsTile` but with NO outer card/gap of its own, since the card now lives on the section). Each row keeps its own `InkWell` for the tap ripple. Rows within a card are stacked directly with vertical padding and no `Divider`, matching the reference image. Error-colored rows (Sign out, Delete) omit the chevron, as today.

Since rows now sit inside a shared clipped card, per-row `InkWell` ripples are bounded by the card corners automatically. The existing `NilePressable` press-scale can wrap the whole card (or be dropped per-row); wrap per section card to keep the tactile feel without double-nesting.

**Appearance screen.** New `AppearanceScreen` (StatelessWidget) following the standard screen pattern: `Scaffold` with `NileColors.bgPage`, `extendBodyBehindAppBar: true`, `NileGlassBar.appBar(title: Text('Appearance'))`, body wrapped in `NileMaxWidth` with a `ListView`/`Padding` (same top-inset math as SettingsScreen) containing an `APPEARANCE`-style label and the existing `const ThemeModePicker()`. Wire `_appearance(BuildContext)` in SettingsScreen to push it.

**Cleanup.** Remove the now-unused inline `ThemeModePicker` usage and the standalone `APPEARANCE` header from the SettingsScreen build; keep the `theme_mode_picker.dart` import only in the new AppearanceScreen. `_SettingsTile` is replaced by `_SettingsRow` (+ `_SettingsSection`).

## Task Breakdown
- [ ] Create `lib/screens/appearance_screen.dart` with a Scaffold + glass app bar + `NileMaxWidth` body holding the `ThemeModePicker`.
- [ ] In `settings_screen.dart`, add `_SettingsSection` (optional header + single rounded card wrapping a Column of rows).
- [ ] Add `_SettingsRow` (icon + label + optional chevron, own InkWell, no outer card/gap); support `color` override for error rows.
- [ ] Rebuild the `build` method body as stacked sections: Experience, Events, Security, standalone Sign out, Danger zone.
- [ ] Add `_appearance(context)` handler pushing `AppearanceScreen`; make the Appearance row use it.
- [ ] Remove inline `ThemeModePicker` + old `APPEARANCE` header and the `theme_mode_picker` import from SettingsScreen; delete `_SettingsTile`.
- [ ] Verify spacing/tokens: section gap, in-card row padding, card radius `NileRadius.lg`, header via `labelSm`.
- [ ] `flutter analyze` clean; visual check in-app (light + dark) that cards, rows, ripples, and Appearance navigation render correctly.

## Edge Cases & Failure Modes
- **Ripple bleeding past rounded corners** — card must use `clipBehavior: Clip.antiAlias` so per-row InkWell ripples are clipped.
- **First/last row corner radius** — because the card is clipped, top/bottom rows inherit the card's rounded corners without per-row radius handling.
- **Error rows** — Sign out and Delete keep `NileColors.error` and omit the chevron; Sign out sits alone in its own card (no header) between Security and Danger zone.
- **Appearance navigation while theme changing** — `ThemeModePicker` applies instantly via `ThemeService`; navigating back to Settings reflects the new theme with no extra wiring.
- **Long labels / accessibility text scaling** — row uses `Expanded` around the label so it wraps/truncates without overflowing the chevron.

## Success Criteria
- Settings shows four labeled section cards plus a standalone Sign out card, in the specified order and grouping.
- Each section is a single rounded card with rows stacked inside, no dividers, matching the reference image.
- Appearance is a tappable row that opens a dedicated screen with the working theme picker; no inline picker remains on Settings.
- All other rows navigate/behave exactly as before; sign-out and delete dialogs unchanged.
- `flutter analyze` passes; layout renders correctly in light and dark within `NileMaxWidth`.

## Open Questions / Risks
- Reference image (Revolut) shows no dividers and fairly generous in-card row padding; exact vertical padding is a judgment call — will match current tile padding (`NileSpacing.s16`) unless it looks cramped.
- Whether to keep `NilePressable` press-scale per section card or drop it entirely — low-risk, will keep it at the card level for consistency with the rest of the app.
