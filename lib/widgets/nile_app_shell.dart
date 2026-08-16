import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../router.dart';
import '../services/shell_state.dart';
import '../theme.dart';
import 'nile_context_rail.dart';
import 'nile_create_sheet.dart';
import 'nile_destinations.dart';
import 'nile_nav_rail.dart';
import 'nile_top_bar.dart';

/// The desktop chrome — nav rail, top bar, context rail — wrapped around the
/// whole signed-in route tree rather than around the tab shell alone.
///
/// **Why it sits this high.** Detail screens used to be siblings of the tab
/// shell, so pushing an event page covered the nav rail: correct on a phone,
/// wrong on a desktop, and fatal to the agreed layout for the live viewer,
/// where the right-hand column is part of the screen. Putting the chrome above
/// both the branches and the detail routes means a push changes the content and
/// nothing else. The alternative — moving detail routes down into the branches
/// — would have changed how a pushed screen behaves on the phone, which is not
/// a thing to do while beta is live.
///
/// **On compact this is a pass-through.** `child` is returned untouched, so the
/// phone tree is exactly what shipped: `HomeScreen`'s own Scaffold and glass nav
/// bar, with detail screens covering it. The only structural difference is that
/// those pages are on the shell's Navigator instead of the root one, which is
/// invisible to everything except [rootNavigatorKey] — see [shellNavigatorKey].
class NileAppShell extends StatelessWidget {
  const NileAppShell({super.key, required this.location, required this.child});

  /// The current route's path, from `GoRouterState.uri.path`. Passed in rather
  /// than read from context so the decisions below are pure and testable.
  final String location;

  final Widget child;

  /// Routes that get no chrome at all.
  ///
  /// Both are modal in intent: you are in the middle of one thing, and a rail
  /// inviting you elsewhere mid-broadcast or mid-upload is an invitation to
  /// lose work. The auth gate needs no entry here — those routes are siblings
  /// of this shell and never reach it.
  static bool isBare(String location) =>
      location.startsWith('/stream/') || location.startsWith('/create/');

  /// Routes that take the width the context rail would otherwise use.
  ///
  /// Every one of them already has a right-hand column of its own — the live
  /// viewer's chat, Messages' thread pane, the Currents comment column, the
  /// seventh day of the schedule board. A context rail beside those would be a
  /// second right-hand column showing something unrelated.
  /// The event page is here too, for a reason worth writing down: the design
  /// direction has this rail becoming *chat* on event pages, and until the
  /// pre-show lobby exists there is no chat to put in it. Showing "what's on"
  /// beside an event page instead would be a placeholder occupying the space
  /// the real thing needs. Full width now; the rail comes back as chat when the
  /// lobby lands.
  static bool wantsFullWidth(String location) {
    if (location == NileRoutes.schedule ||
        location == NileRoutes.messages ||
        location == NileRoutes.currents ||
        location.startsWith('/watch/') ||
        location.startsWith('/dm/')) {
      return true;
    }
    // `/event/:id` and its replay player, but not its sub-forms (`/edit`,
    // `/attendees`, `/crew`) — those are ordinary column-width screens.
    final parts = location.split('/');
    if (parts.length >= 3 && parts[1] == 'event') {
      return parts.length == 3 || (parts.length == 4 && parts[3] == 'replay');
    }
    return false;
  }

  /// The rail slot to highlight.
  ///
  /// At a branch root the location says it outright, which matters because that
  /// is the case where it has just changed. On a pushed detail screen the
  /// location says nothing about which tab you were standing on, so the branch
  /// the shell last published is the answer — and it is stable by then.
  static int selectedBranch(String location) {
    final i = kNileBranchLocations.indexOf(location);
    return i >= 0 ? i : NileShellState.branch.value;
  }

  /// The rail slot to highlight, or `-1` for none.
  ///
  /// A rail row that is a plain route wins over the branch underneath it: while
  /// `/currents` is open you are standing on Currents, even though the branch
  /// you opened it from is still what the shell would fall back to. Profile has
  /// no row at all, so being on it highlights nothing rather than lighting up
  /// whichever branch happens to be remembered.
  static int selectedRailSlot(String location) {
    final route = kNileRailEntries.indexWhere((e) => e.location == location);
    if (route >= 0) return route;
    return nileRailSlotForBranch(selectedBranch(location));
  }

  @override
  Widget build(BuildContext context) {
    final window = NileBreakpoints.of(context);
    if (!window.hasNavRail || isBare(location)) return child;

    final atBranchRoot = kNileBranchLocations.contains(location);

    // Labels are the user's call, but only where the window has room for them:
    // below `expanded` the rail is icon-only regardless and the toggle is
    // hidden rather than left to do nothing.
    return ValueListenableBuilder<bool>(
      valueListenable: NileShellState.railCollapsed,
      builder: (context, collapsed, _) {
        final labelled = window.navRailLabelled && !collapsed;
        // One animated number drives both zones. Animating the rail alone would
        // slide it out from under a content column that jumped to its new width
        // a frame earlier.
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: NileNavRail.widthFor(labelled)),
          duration: NileMotion.fast,
          curve: NileMotion.curve,
          builder: (context, railWidth, _) => _layout(
            context,
            location: location,
            window: window,
            labelled: labelled,
            railWidth: railWidth,
            atBranchRoot: atBranchRoot,
          ),
        );
      },
    );
  }

  Widget _layout(
    BuildContext context, {
    required String location,
    required NileWindowClass window,
    required bool labelled,
    required double railWidth,
    required bool atBranchRoot,
  }) {
    // Same zone arithmetic as before the chrome moved up: both rails pinned to
    // the window edges, the content column growing first to its ceiling, the
    // context rail absorbing the surplus. The three always sum to exactly the
    // window width, so nothing floats.
    final available = MediaQuery.sizeOf(context).width - railWidth;
    final showContextRail = window.hasContextRail && !wantsFullWidth(location);
    final contentWidth = showContextRail
        ? math.min(available - NileContextRail.minWidth, NileMaxWidth.desktop)
        : available;

    return Scaffold(
      backgroundColor: NileColors.bgPage,
      body: Row(
        children: [
          NileNavRail(
            // The rail's order is not the branch order — Schedule shows second
            // but is branch 4 — and three of its rows are not branches at all,
            // so both directions go through the entry list.
            selectedIndex: selectedRailSlot(location),
            onDestinationSelected: (slot) {
              final entry = kNileRailEntries[slot];
              if (entry.isBranch) {
                context.go(kNileBranchLocations[entry.branch!]);
              } else if (entry.location != location) {
                // Guarded, because unlike `go` a repeated `push` would stack a
                // second copy of the same screen under the same rail row.
                context.push(entry.location!);
              }
            },
            entries: kNileRailEntries,
            labelled: labelled,
            width: railWidth,
            onToggle: window.navRailLabelled ? NileShellState.toggleRail : null,
            onCreate: () => showNileCreateSheet(context),
            onSettings: () => context.push(NileRoutes.settings),
          ),
          SizedBox(
            // The chrome owns the column width, so screens sit flush against
            // the nav rail instead of being re-centred by their own
            // NileMaxWidth inside a wider area.
            width: contentWidth,
            child: Column(
              children: [
                NileTopBar(leading: atBranchRoot ? null : const _ShellBack()),
                Expanded(child: child),
              ],
            ),
          ),
          if (showContextRail) NileContextRail(width: available - contentWidth),
        ],
      ),
    );
  }
}

/// Back, for the top bar. Pops the shell's Navigator — the one detail screens
/// are pushed onto now — rather than whatever Navigator happens to be nearest,
/// which from the chrome's own context is the root one holding a single page.
class _ShellBack extends StatelessWidget {
  const _ShellBack();

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Back',
    icon: const Icon(Icons.arrow_back),
    onPressed: () {
      final nav = shellNavigatorKey.currentState;
      if (nav != null && nav.canPop()) {
        nav.pop();
      } else {
        // Arrived cold on a detail route: there is nothing to pop back to, so
        // fall back to the tab the rail is already highlighting.
        context.go(kNileBranchLocations[NileShellState.branch.value]);
      }
    },
  );
}
