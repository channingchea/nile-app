import 'package:flutter/material.dart';

import 'nile_glass_nav_bar.dart' show NileGlassDestination;

// ── Destinations ─────────────────────────────────────────────────────────────
// The phone bar and the desktop rail share the branch destinations below, so
// the two navs can never drift out of order — but they are no longer the same
// list. The phone bar shows exactly the four shipped branches; the rail follows
// the desktop wireframe, which mixes branches with plain routes (Currents,
// Notifications, My Tickets) and drops Profile in favour of the avatar in the
// top bar. `NileRailEntry` is what lets one row mean either thing.
//
// Schedule is appended to the branch list rather than inserted where it
// visually belongs: branch indices are what `shell.goBranch` and every
// `currentIndex` check speak in, so renumbering them to make the rail read
// nicely would silently change what every existing call means. The rail keeps
// its own display order instead.

const NileGlassDestination kHomeDestination = NileGlassDestination(
  icon: Icons.home_outlined,
  selectedIcon: Icons.home,
  label: 'Home',
);

const NileGlassDestination kDiscoverDestination = NileGlassDestination(
  icon: Icons.search_outlined,
  selectedIcon: Icons.search,
  label: 'Discover',
);

const NileGlassDestination kMessagesDestination = NileGlassDestination(
  icon: Icons.send_outlined,
  selectedIcon: Icons.send,
  label: 'Messages',
);

const NileGlassDestination kProfileDestination = NileGlassDestination(
  icon: Icons.person_outline,
  selectedIcon: Icons.person,
  label: 'Profile',
);

/// Desktop only — there is no room for a fifth slot in the phone bar, and the
/// phone layout is deliberately unchanged.
const NileGlassDestination kScheduleDestination = NileGlassDestination(
  icon: Icons.calendar_month_outlined,
  selectedIcon: Icons.calendar_month,
  label: 'Schedule',
);

// Rail-only destinations. None of these is a branch: each is an ordinary route
// that the rail pushes, which is why they never appear in the phone bar.

const NileGlassDestination kCurrentsDestination = NileGlassDestination(
  icon: Icons.play_circle_outline,
  selectedIcon: Icons.play_circle,
  label: 'Currents',
);

const NileGlassDestination kNotificationsDestination = NileGlassDestination(
  icon: Icons.notifications_outlined,
  selectedIcon: Icons.notifications,
  label: 'Notifications',
);

const NileGlassDestination kTicketsDestination = NileGlassDestination(
  icon: Icons.confirmation_number_outlined,
  selectedIcon: Icons.confirmation_number,
  label: 'My Tickets',
);

/// Branch index of the Schedule destination. Last, so adding it renumbered
/// nothing.
const int kScheduleBranch = 4;

/// Every branch, in router order.
const List<NileGlassDestination> kNileBranchDestinations = [
  kHomeDestination,
  kDiscoverDestination,
  kMessagesDestination,
  kProfileDestination,
  kScheduleDestination,
];

/// The phone bar, unchanged: the original four branches in their original
/// order, so `selectedIndex` is still the branch index on compact.
const List<NileGlassDestination> kNileDestinations = [
  kHomeDestination,
  kDiscoverDestination,
  kMessagesDestination,
  kProfileDestination,
];

/// Where each branch lives, indexed by branch. The desktop rail navigates by
/// location rather than by `goBranch`, because from a pushed detail screen the
/// rail has to do two things at once — pop back to the shell *and* switch
/// branch — and `context.go(root)` is exactly that in one call. It also gives
/// the phone bar's "re-tap to pop the branch to its root" behaviour for free.
const List<String> kNileBranchLocations = [
  '/',
  '/discover',
  '/messages',
  '/profile',
  '/schedule',
];

/// Which live count, if any, a rail row shows.
///
/// The rail owns both badges because it is the one piece of chrome always on
/// screen; naming the *kind* here rather than passing numbers in keeps the
/// composition of the rail declarative and the polling in one place.
enum NileRailBadge { none, notifications, messages }

/// One row of the desktop rail: either a shell branch or a pushed route.
///
/// Two constructors rather than a nullable free-for-all, so a row cannot be
/// built that is somehow both or neither.
@immutable
class NileRailEntry {
  /// A row that switches the shell to [branch].
  const NileRailEntry.branch(
    this.destination,
    int this.branch, {
    this.badge = NileRailBadge.none,
  }) : location = null;

  /// A row that pushes [location] above the shell. Selected state is an exact
  /// location match, since these routes have no branch to fall back on.
  const NileRailEntry.route(
    this.destination,
    String this.location, {
    this.badge = NileRailBadge.none,
  }) : branch = null;

  final NileGlassDestination destination;
  final int? branch;
  final String? location;
  final NileRailBadge badge;

  bool get isBranch => branch != null;
}

/// The desktop rail, in rail order — the wireframe's list exactly.
///
/// Schedule sits directly under Home ("what's on" and "what's next" are the
/// same question) and Profile is absent on purpose: the avatar in the top bar
/// already goes there, and a rail row for it would be a second door to the same
/// screen. Settings is not here either — it stays pinned below the divider,
/// because a preferences screen is not a destination you navigate *to* in the
/// course of using the app.
///
/// Route paths are written as literals rather than imported from `NileRoutes`
/// to keep this file free of a dependency on `router.dart`, which imports every
/// screen. `desktop_layouts_test.dart` asserts they still match.
const List<NileRailEntry> kNileRailEntries = [
  NileRailEntry.branch(kHomeDestination, 0),
  NileRailEntry.branch(kScheduleDestination, kScheduleBranch),
  NileRailEntry.branch(kDiscoverDestination, 1),
  NileRailEntry.route(kCurrentsDestination, '/currents'),
  NileRailEntry.branch(
    kMessagesDestination,
    2,
    badge: NileRailBadge.messages,
  ),
  NileRailEntry.route(
    kNotificationsDestination,
    '/notifications',
    badge: NileRailBadge.notifications,
  ),
  NileRailEntry.route(kTicketsDestination, '/settings/tickets'),
];

/// The rail's destinations, in rail order.
List<NileGlassDestination> get kNileRailDestinations =>
    [for (final e in kNileRailEntries) e.destination];

/// Rail slot showing [branch], or `-1` when that branch has no row.
///
/// Profile is the `-1` case by design: standing on it highlights nothing rather
/// than lighting up Home, which would be a lie about where you are.
int nileRailSlotForBranch(int branch) =>
    kNileRailEntries.indexWhere((e) => e.branch == branch);
