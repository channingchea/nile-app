import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';

/// A floating, translucent "Liquid Glass" bottom navigation bar.
///
/// Renders identically on every platform: instead of relying on the native
/// iOS 26 effect (which doesn't exist on Android/web/desktop), it approximates
/// the look with a backdrop blur + translucent tint + specular border. Content
/// is meant to scroll *behind* it, so the host Scaffold must set
/// `extendBody: true`, and scroll views need bottom padding of at least
/// [reservedHeight] so their last item isn't hidden under the glass.
///
/// API mirrors Material's [NavigationBar] (selectedIndex + onDestinationSelected)
/// so it's a near drop-in replacement.
class NileGlassNavBar extends StatelessWidget {
  const NileGlassNavBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.trailing,
  }) : assert(destinations.length >= 2);

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NileGlassDestination> destinations;

  /// Optional action rendered as a separate circular button to the right of the
  /// glass pill, on the same row (e.g. a create/"+" button). Sized to [_barHeight].
  final Widget? trailing;

  // ── Tunables ──────────────────────────────────────────────────────────────
  static const double _blurSigma = 20; // backdrop blur strength
  static const double _tintAlpha = 0.62; // surface tint over the blur
  static const double _barHeight = 60;
  static const double _hMargin = NileSpacing.s16; // inset from screen edges
  static const double _vMargin = NileSpacing.s8; // gap above safe-area bottom

  /// Height a scroll view must reserve at its bottom so content clears the bar.
  /// Add to it the view's own MediaQuery bottom padding (safe area).
  static double reservedHeight = _barHeight + _vMargin * 2;

  /// Route selection through here so a different tab triggers a light haptic
  /// (mobile only; a no-op on web/desktop) before notifying the host.
  void _select(int index) {
    if (index != selectedIndex) HapticFeedback.lightImpact();
    onDestinationSelected(index);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;

    // The glass pill: backdrop blur + translucent tint + specular rim, holding
    // the nav tabs. Expands to fill whatever width the outer Row leaves it.
    final glassPill = ClipRRect(
      borderRadius: BorderRadius.circular(NileRadius.xl),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: _blurSigma, sigmaY: _blurSigma),
        child: Container(
          height: _barHeight,
          decoration: BoxDecoration(
            // Tint over the blur. High enough alpha that icons stay legible
            // over a busy feed (accessibility), low enough to read as glass.
            color: NileColors.bgSurface.withValues(alpha: _tintAlpha),
            borderRadius: BorderRadius.circular(NileRadius.xl),
            // Specular rim — the "lit glass edge."
            border: Border.all(color: NileColors.borderStrong, width: 0.5),
            boxShadow: const [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 24,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            // Content-sized tabs spread across the pill: the selected tab is
            // wider (icon + label) so neighbours slide as selection moves.
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final (i, d) in destinations.indexed)
                _GlassTab(
                  destination: d,
                  selected: i == selectedIndex,
                  onTap: () => _select(i),
                ),
            ],
          ),
        ),
      ),
    );

    // Must report a finite, deterministic height: this widget sits in the
    // Scaffold's bottomNavigationBar slot, which gives a loose height
    // constraint. (Don't wrap in NileMaxWidth — its Align expands to fill the
    // loose constraint and pins the bar to the top.) Center horizontally with a
    // bounded ConstrainedBox instead.
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _hMargin,
        0,
        _hMargin,
        _vMargin + bottomInset,
      ),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Row(
            children: [
              Expanded(child: glassPill),
              if (trailing != null) ...[
                const SizedBox(width: NileSpacing.s12),
                SizedBox(
                  width: _barHeight,
                  height: _barHeight,
                  child: trailing,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class NileGlassDestination {
  const NileGlassDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

class _GlassTab extends StatelessWidget {
  const _GlassTab({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final NileGlassDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Icon inherits txtPrimary when active (sitting on the volt pill), muted
    // txtSecondary otherwise. Volt stays the pill accent — never the glyph.
    final color = selected ? NileColors.txtPrimary : NileColors.txtSecondary;
    return Semantics(
      button: true,
      selected: selected,
      // Announce the label even while it's visually hidden on unselected tabs.
      label: destination.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NileRadius.pill),
        child: AnimatedContainer(
          duration: NileMotion.base,
          curve: NileMotion.curve,
          padding: EdgeInsets.symmetric(
            horizontal: selected ? NileSpacing.s16 : NileSpacing.s12,
            vertical: NileSpacing.s8,
          ),
          decoration: BoxDecoration(
            // Volt pill hugs the active tab and grows with it as the label
            // reveals; transparent (icon-only) when unselected.
            color: selected
                ? NileColors.volt.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(NileRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                selected ? destination.selectedIcon : destination.icon,
                color: color,
                size: 24,
              ),
              // Label reveal: its width animates 0 → full (so the pill grows and
              // neighbours slide over) while the text fades in. Collapsed and
              // faded out when unselected.
              ClipRect(
                child: AnimatedAlign(
                  duration: NileMotion.base,
                  curve: NileMotion.curve,
                  alignment: Alignment.centerLeft,
                  widthFactor: selected ? 1.0 : 0.0,
                  child: AnimatedOpacity(
                    duration: NileMotion.base,
                    curve: NileMotion.curve,
                    opacity: selected ? 1.0 : 0.0,
                    child: Padding(
                      padding: const EdgeInsets.only(left: NileSpacing.s6),
                      child: ConstrainedBox(
                        // Cap so an extreme text scale can't blow out the bar.
                        constraints: const BoxConstraints(maxWidth: 120),
                        child: Text(
                          destination.label,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: NileTextStyles.caption().copyWith(
                            color: color,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
