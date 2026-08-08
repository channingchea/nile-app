import 'package:flutter/foundation.dart';

/// Remount counters for the four shell tabs.
///
/// The tab shell used to hold these as `_HomeScreenState` fields and bump them
/// with `setState` to force a `ValueKey` change (repost → rebuild Profile,
/// create → rebuild Feed and Profile). Under a router the tabs are built by
/// route builders rather than by the shell, so the counters live here and the
/// builders key off them. Same contract, same remount points.
class TabRefresh {
  TabRefresh._();

  static final feed = ValueNotifier<int>(0);
  static final profile = ValueNotifier<int>(0);
  static final discover = ValueNotifier<int>(0);

  /// Something the user did changed their own content (repost, delete).
  static void contentChanged() => profile.value++;

  /// A new post/current/event was created: both the feed and the profile grid
  /// are stale.
  static void contentCreated() {
    feed.value++;
    profile.value++;
  }

  static void discoverChanged() => discover.value++;
}
