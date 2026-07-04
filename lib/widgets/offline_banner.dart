import 'package:flutter/material.dart';

import '../services/connectivity_service.dart';
import '../theme.dart';

/// A slim "You're offline" strip that slides in whenever the device loses its
/// network connection and slides away when it returns. Drop it at the top of a
/// screen's body (inside the Column, above the scrollable content):
///
/// ```dart
/// Column(children: [const OfflineBanner(), Expanded(child: list)])
/// ```
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ConnectivityService.instance.online,
      builder: (context, online, _) {
        return AnimatedSize(
          duration: NileMotion.base,
          curve: NileMotion.curve,
          child: online
              ? const SizedBox(width: double.infinity)
              : Container(
                  width: double.infinity,
                  color: NileColors.bgRaised,
                  padding: const EdgeInsets.symmetric(
                    horizontal: NileSpacing.s16,
                    vertical: NileSpacing.s8,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.wifi_off_rounded,
                        size: 15,
                        color: NileColors.txtSecondary,
                      ),
                      const SizedBox(width: NileSpacing.s8),
                      Text(
                        "You're offline",
                        style: NileTextStyles.caption().copyWith(
                          color: NileColors.txtSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}

/// A small pill shown when a realtime channel is retrying after a drop. Use with
/// [ResilientChannel]'s state so the user knows live data may be briefly stale.
class ReconnectingPill extends StatelessWidget {
  final String label;
  const ReconnectingPill({super.key, this.label = 'Reconnecting…'});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: NileSpacing.s4),
        padding: const EdgeInsets.symmetric(
          horizontal: NileSpacing.s12,
          vertical: NileSpacing.s4,
        ),
        decoration: BoxDecoration(
          color: NileColors.bgSurface,
          borderRadius: BorderRadius.circular(NileRadius.pill),
          border: Border.all(color: NileColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: NileColors.amber,
              ),
            ),
            const SizedBox(width: NileSpacing.s8),
            Text(
              label,
              style: NileTextStyles.caption().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
