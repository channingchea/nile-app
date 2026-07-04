import 'package:flutter/material.dart';

import '../services/theme_service.dart';
import '../theme.dart';

/// Three-option System / Light / Dark selector with a mini live preview per
/// option. Selecting applies instantly app-wide via [ThemeService.setMode]
/// (which also persists local + profile). Used by Settings and onboarding.
class ThemeModePicker extends StatelessWidget {
  const ThemeModePicker({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeService.instance.mode,
      builder: (context, mode, _) => Row(
        children: [
          for (final (m, label, icon) in const [
            (ThemeMode.system, 'System', Icons.brightness_auto_outlined),
            (ThemeMode.light, 'Light', Icons.light_mode_outlined),
            (ThemeMode.dark, 'Dark', Icons.dark_mode_outlined),
          ]) ...[
            if (m != ThemeMode.system) const SizedBox(width: NileSpacing.s8),
            Expanded(
              child: _ThemeOption(
                mode: m,
                label: label,
                icon: icon,
                selected: mode == m,
                onTap: () => ThemeService.instance.setMode(m),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({
    required this.mode,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final ThemeMode mode;
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  /// Palette the mini preview is drawn in — the option's own theme, not the
  /// app's current one, so the user sees what they'd get before tapping.
  NilePalette _previewPalette(BuildContext context) => switch (mode) {
    ThemeMode.light => NilePalette.light,
    ThemeMode.dark => NilePalette.dark,
    ThemeMode.system => NilePalette.of(MediaQuery.platformBrightnessOf(context)),
  };

  @override
  Widget build(BuildContext context) {
    final p = _previewPalette(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: NileMotion.fast,
        curve: NileMotion.curve,
        decoration: BoxDecoration(
          color: NileColors.bgSurface,
          borderRadius: BorderRadius.circular(NileRadius.md),
          border: Border.all(
            color: selected ? NileColors.volt : NileColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        padding: const EdgeInsets.all(NileSpacing.s12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Mini preview: page bg + surface card + volt dot, in this
            // option's own palette.
            Container(
              height: 44,
              decoration: BoxDecoration(
                color: p.bgPage,
                borderRadius: BorderRadius.circular(NileRadius.sm),
                border: Border.all(color: p.border),
              ),
              padding: const EdgeInsets.all(NileSpacing.s6),
              child: Container(
                decoration: BoxDecoration(
                  color: p.bgSurface,
                  borderRadius: BorderRadius.circular(NileRadius.xs),
                  border: Border.all(color: p.border),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: NileSpacing.s6,
                ),
                child: Row(
                  children: [
                    CircleAvatar(radius: 5, backgroundColor: p.volt),
                    const SizedBox(width: NileSpacing.s6),
                    Expanded(
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: p.txtSecondary,
                          borderRadius: BorderRadius.circular(NileRadius.pill),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: NileSpacing.s8),
            Icon(
              icon,
              size: 16,
              color: selected ? NileColors.volt : NileColors.txtSecondary,
            ),
            const SizedBox(height: NileSpacing.s4),
            Text(
              label,
              style: NileTextStyles.labelSm().copyWith(
                letterSpacing: 0,
                color: selected ? NileColors.txtPrimary : NileColors.txtSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
