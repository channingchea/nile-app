import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../router.dart';
import '../services/platform_support.dart';
import '../services/tab_refresh.dart';
import '../theme.dart';

/// The Create menu, opened from the phone bar's "+" and from the desktop rail's
/// volt Create button.
///
/// Lifted out of `home_screen.dart` when the desktop chrome moved above the tab
/// shell: the rail lives in the chrome now, but the sheet it opens is the same
/// one the phone bar opens, and one copy is the point.
void showNileCreateSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: NileColors.bgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
    ),
    builder: (_) => const _CreateSheet(),
  );
}

class _CreateSheet extends StatelessWidget {
  const _CreateSheet();

  /// Close the sheet, open the create screen, and when it returns mark the feed
  /// and profile tabs stale. `pop` then `push` has to stay in that order — the
  /// sheet is a route too.
  void _open(BuildContext context, String location) {
    Navigator.pop(context);
    context.push(location).then((_) => TabRefresh.contentCreated());
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          NileSpacing.s24,
          NileSpacing.s16,
          NileSpacing.s24,
          NileSpacing.s24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: NileColors.border,
                  borderRadius: BorderRadius.circular(NileRadius.pill),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text('Create', style: NileTextStyles.headingMd()),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _open(context, NileRoutes.createPost),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Create Post'),
            ),
            // The trim strip needs video_thumbnail — mobile only.
            if (NilePlatform.canCreateCurrents) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _open(context, NileRoutes.createCurrent),
                icon: const Icon(Icons.bolt_outlined),
                label: const Text('Create Current'),
              ),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _open(context, NileRoutes.createEvent),
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Create Event'),
            ),
            // Viewing/streaming is entered from the event detail screen, which
            // knows whether you're the host (and so whether you get Start Show
            // / End Stream) — not from this create sheet.
          ],
        ),
      ),
    );
  }
}
