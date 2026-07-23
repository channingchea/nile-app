# Bottom Nav Bar Microinteraction — Implementation Plan

## Overview
Upgrade `NileGlassNavBar` so tab selection feels alive. Today it cross-fades a volt pill in place and always shows every label. The new behavior: unselected tabs show only their icon, the selected tab expands to reveal its label inside a volt pill that resizes to hug it, and as selection moves the pills grow/shrink in sync so the highlight reads as gliding across the bar. A light haptic fires on selection. All motion is subtle easeOut (300ms), consistent with the existing design language.

## Non-goals / out of scope
- No change to the trailing "+" create button.
- No change to bar height, glass/blur styling, or `reservedHeight` (scroll padding stays the same).
- No spring/overshoot — subtle & smooth only.
- No new motion tokens unless the two existing durations don't fit.

## Approach note
The "slide" is achieved by each tab animating its own width + pill together (the shrinking pill and growing pill are adjacent, so the volt block appears to travel). This is far more robust than a single measured, absolutely-positioned pill and reads identically at these durations.

## Phase 1: Layout — icon-only vs. icon + label
- Change `_GlassTab` so unselected renders icon only; selected renders icon + label in a horizontal row inside the volt pill.
- Replace the fixed `Expanded` (equal-width) tab layout with content-sized tabs distributed across the pill (`MainAxisAlignment.spaceEvenly`), so the selected tab can be wider than the rest.
- Shape the volt background as a full pill that hugs its content (icon, or icon + label) with appropriate horizontal padding.
- Keep `Semantics(label:)` on every tab so the label is still announced even when visually hidden.
- Verify: static look is correct for each selected index before adding motion.

## Phase 2: Motion — reveal + glide
- Animate the label reveal with `AnimatedSize` + `AnimatedOpacity` (label width animates 0 -> full, fades in) so siblings re-flow smoothly and the pill appears to slide.
- Animate the volt pill color/size with the same duration + curve so grow/shrink stay in sync.
- Duration/curve: `NileMotion.base` (300ms) + `easeOutCubic`. Confirm interrupted taps (rapid switching) retarget cleanly.
- Swap outline -> filled icon on selection.

## Phase 3: Haptics + polish + verification
- Add `HapticFeedback.lightImpact()` on tap, only when the tapped index differs from the current one; import `package:flutter/services.dart`.
- Edge cases: verify no overflow on a narrow screen (~320pt wide) with the longest label selected; handle large text-scale / accessibility font sizes gracefully (ellipsis / clamp).
- Run `flutter analyze`; visually check light and dark, and confirm behavior on both a mobile build and web/desktop (haptic no-ops off-mobile).

## Open questions / risks
- Narrow-width overflow is the main risk: 4 icons + one expanded label + the "+" button on a small phone. Mitigation options if tight — reduce inter-tab spacing when selected, cap label with ellipsis, or slightly shrink icon size.
- Alternative considered: a single absolutely-positioned pill that measures tab offsets and slides via `AnimatedPositioned`. Rejected as more fragile (needs layout measurement, breaks with variable tab widths) for no visible benefit here.
