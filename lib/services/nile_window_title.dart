import 'package:flutter/foundation.dart';

import '../router.dart';
import '../widgets/nile_destinations.dart';
import 'mac_host.dart';

/// Keeps the Mac window's title in step with the route.
///
/// A Flutter app leaves the title at whatever `MainMenu.xib` set — "Nile", for
/// the life of the process — which on a Mac reads as an app that does not know
/// where it is. `MaterialApp.title` does not help: the `Title` widget behind it
/// only speaks to Android's task switcher.
class NileWindowTitle {
  NileWindowTitle._();

  static bool _started = false;

  static void start() {
    if (_started || !MacHost.supported) return;
    _started = true;
    nileRouter.routerDelegate.addListener(_sync);
    _sync();
  }

  static void _sync() {
    final String path;
    try {
      path = nileRouter.state.uri.path;
    } catch (_) {
      // Asked before the first route has resolved; the next notification will
      // have an answer.
      return;
    }
    MacHost.setWindowTitle(titleFor(path));
  }

  /// The section name alone, not "Nile — Section": the app name is already two
  /// inches away in the menu bar, and repeating it in every title is the kind
  /// of thing Mac apps do not do.
  @visibleForTesting
  static String titleFor(String path) {
    // The rail's own labels first, so a renamed destination renames its window
    // title with it and the two can't drift.
    for (final entry in kNileRailEntries) {
      final at = entry.isBranch
          ? kNileBranchLocations[entry.branch!]
          : entry.location!;
      if (at == path) return entry.destination.label;
    }

    return switch (path) {
      '/profile' => 'Profile',
      NileRoutes.createPost => 'New Post',
      NileRoutes.createEvent => 'New Event',
      NileRoutes.createCurrent => 'New Current',
      NileRoutes.boost => 'Boost',
      NileRoutes.userList => 'People',
      _ => _prefixed(path),
    };
  }

  static String _prefixed(String path) {
    if (path.startsWith('/settings')) return 'Settings';
    if (path.startsWith('/event/')) return 'Event';
    if (path.startsWith('/watch/')) return 'Live';
    if (path.startsWith('/stream/')) return 'Go Live';
    if (path.startsWith('/dm/')) return 'Messages';
    if (path.startsWith('/post/')) return 'Post';
    if (path.startsWith('/u/')) return 'Profile';
    // The auth routes and anything unrouted: the app name is the honest answer.
    return 'Nile';
  }
}
