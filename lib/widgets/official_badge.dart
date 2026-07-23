import 'package:flutter/material.dart';
import '../theme.dart';

/// Volt check mark marking the official Nile account (`profiles.is_official`).
/// One shared widget, dropped in next to a name wherever identity renders.
/// Render it only when the profile is official — it draws unconditionally.
class OfficialBadge extends StatelessWidget {
  /// Diameter of the badge in logical pixels.
  final double size;
  const OfficialBadge({super.key, this.size = 15});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: context.nile.volt,
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.check_rounded,
        size: size * 0.72,
        color: NileColors.onVolt,
      ),
    );
  }
}
