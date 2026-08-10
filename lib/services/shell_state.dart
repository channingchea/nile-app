import 'package:flutter/foundation.dart';

/// What the desktop chrome needs to know about the tab shell underneath it.
///
/// The chrome (`NileAppShell`) wraps the *whole* signed-in route tree so the
/// nav rail survives pushing a detail screen — which puts it strictly above the
/// `StatefulShellRoute` in the widget tree, and therefore out of reach of the
/// `StatefulNavigationShell` it needs to highlight the right rail item. The
/// shell publishes here instead of the chrome reaching down.
///
/// The same arrangement `NileShortcuts.branchSwitcher` already uses, for the
/// same reason. Deriving the branch from the URL instead would not work: a
/// pushed `/event/:id` says nothing about which tab you were standing on when
/// you opened it, and that is exactly what the rail has to keep showing.
class NileShellState {
  NileShellState._();

  /// The branch index currently selected in the tab shell. Survives a detail
  /// route being pushed above it, because the shell stays mounted underneath.
  static final ValueNotifier<int> branch = ValueNotifier<int>(0);

  /// Set by the shell on mount; cleared when it goes away.
  static void publish(int index) {
    if (branch.value != index) branch.value = index;
  }
}
