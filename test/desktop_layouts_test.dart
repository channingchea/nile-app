// Phase 7 — the desktop screen layouts. Same principle as
// desktop_shell_test.dart: assert the arithmetic that decides what a real
// window shows, because that is the part which changes silently when a
// constant moves.
//
// Two families of thing are covered here:
//   1. Layout maths — column counts, split widths, and whether the schedule
//      board actually fits inside the width the shell hands it.
//   2. Calendar maths — day bucketing and week stepping, which is where the
//      July UTC bug lived and where a daylight-saving boundary would bite next.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nile_app/router.dart';
import 'package:nile_app/screens/schedule_screen.dart';
import 'package:nile_app/services/nile_shortcuts.dart';
import 'package:nile_app/theme.dart';
import 'package:nile_app/widgets/nile_context_rail.dart';
import 'package:nile_app/widgets/nile_desktop.dart';
import 'package:nile_app/widgets/nile_destinations.dart';
import 'package:nile_app/widgets/nile_nav_rail.dart';

/// Content width the shell hands a branch at [windowWidth], mirroring
/// _DesktopShellState.build. Duplicated rather than imported because the shell
/// is private; desktop_shell_test.dart mirrors the same sum for the same
/// reason, and a divergence between the two is exactly what these catch.
double _shellContentWidth(double windowWidth, {required bool fullWidth}) {
  final window = NileBreakpoints.classify(Size(windowWidth, 1000));
  final rail = NileNavRail.widthFor(window.navRailLabelled);
  final available = windowWidth - rail;
  final contextRail = window.hasContextRail && !fullWidth;
  return contextRail
      ? (available - NileContextRail.minWidth < NileMaxWidth.desktop
            ? available - NileContextRail.minWidth
            : NileMaxWidth.desktop)
      : available;
}

/// Pumps a split at a real window width. Sizing the view rather than wrapping
/// in a SizedBox matters: the default 800x600 test surface would clamp any
/// wider box back down and quietly turn a split case into a narrow one.
Future<void> _pumpSplitAt(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    const MaterialApp(
      home: NileDesktopSplit(
        content: Text('content'),
        side: Text('side'),
        narrow: Text('narrow'),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('NileCardGrid.columnsFor', () {
    test('the context rail is one column at its design width', () {
      // 322 rail minus its 16pt padding either side.
      expect(
        NileCardGrid.columnsFor(
          NileContextRail.minWidth - 32,
          minItemWidth: 240,
          maxColumns: 2,
        ),
        1,
      );
    });

    test('the context rail earns a second column once the shell widens it', () {
      // A maximised 16" MacBook hands the rail 568 — the case the Phase 5b
      // note flagged as looking sparse in one column.
      expect(
        NileCardGrid.columnsFor(
          568 - 32,
          minItemWidth: 240,
          maxColumns: 2,
        ),
        2,
      );
    });

    test('the live band is 3-up in a 900 content column, 2-up at 740', () {
      expect(
        NileCardGrid.columnsFor(
          NileMaxWidth.desktop - 32,
          minItemWidth: 260,
          maxColumns: 3,
        ),
        3,
      );
      expect(
        NileCardGrid.columnsFor(740 - 32, minItemWidth: 260, maxColumns: 3),
        2,
      );
    });

    test('never returns zero, however little room there is', () {
      expect(NileCardGrid.columnsFor(10, minItemWidth: 300), 1);
      expect(NileCardGrid.columnsFor(0, minItemWidth: 300), 1);
      expect(NileCardGrid.columnsFor(double.infinity, minItemWidth: 300), 1);
    });
  });

  group('NileDesktopSplit', () {
    const split = NileDesktopSplit(
      content: SizedBox(),
      side: SizedBox(),
      narrow: SizedBox(),
    );

    test('splits only once both zones fit', () {
      expect(split.splitsAt, NileDesktopSplit.minContentWidth + 32 + 340);
      expect(split.splitsAt, 892);
    });

    testWidgets('falls back to the narrow body below the threshold', (
      tester,
    ) async {
      await _pumpSplitAt(tester, 880);
      expect(find.text('narrow'), findsOneWidget);
      expect(find.text('side'), findsNothing);
    });

    testWidgets('splits as soon as both zones fit', (tester) async {
      await _pumpSplitAt(tester, 900);
      expect(find.text('narrow'), findsNothing);
      expect(find.text('content'), findsOneWidget);
      expect(find.text('side'), findsOneWidget);
      // Below the cap the pair uses the whole width, and the three zones sum
      // to it exactly — no stray gutter.
      final row = tester.getSize(find.byType(Row));
      expect(row.width, 900);
      expect(
        tester.getSize(find.byType(SizedBox).at(1)).width +
            32 +
            NileDesktopSplit.defaultSideWidth,
        900,
      );
    });

    testWidgets('caps and centres the pair on a wide window', (tester) async {
      // Wider than maxTotalWidth, so the pair is capped and centred rather than
      // stretched — the event page's full-bleed hero is what holds the edges.
      await _pumpSplitAt(tester, 1680);
      expect(find.text('side'), findsOneWidget);
      final row = tester.getSize(find.byType(Row));
      expect(row.width, NileDesktopSplit.defaultMaxTotalWidth);
      // Centred: equal air either side.
      final left = tester.getTopLeft(find.byType(Row)).dx;
      expect(
        left,
        (1680 - NileDesktopSplit.defaultMaxTotalWidth) / 2,
      );
    });
  });

  group('Schedule width', () {
    test('a maximised 16" MacBook gets the week board', () {
      // 1682 - 214 rail = 1468, comfortably past seven 150pt columns.
      final width = _shellContentWidth(1682, fullWidth: true);
      expect(width, 1468);
      expect(width, greaterThanOrEqualTo(ScheduleScreen.minWeekBoardWidth));
    });

    test('the narrowest three-zone window falls back to the agenda', () {
      // 1180 - 214 = 966, short of the 1050 a legible board needs.
      final width = _shellContentWidth(1180, fullWidth: true);
      expect(width, 966);
      expect(width, lessThan(ScheduleScreen.minWeekBoardWidth));
    });

    test('suppressing the context rail is what buys the board its width', () {
      // Same window, with and without the rail: the difference is the board.
      expect(_shellContentWidth(1682, fullWidth: false), NileMaxWidth.desktop);
      expect(
        _shellContentWidth(1682, fullWidth: false),
        lessThan(ScheduleScreen.minWeekBoardWidth),
      );
    });
  });

  group('Destinations', () {
    test('the phone bar is unchanged — the original four, in order', () {
      expect(kNileDestinations.length, 4);
      expect(kNileDestinations[0].label, 'Home');
      expect(kNileDestinations[1].label, 'Discover');
      expect(kNileDestinations[2].label, 'Messages');
      expect(kNileDestinations[3].label, 'Profile');
      // Branch index and phone-bar index are the same thing for these four,
      // which is what lets the compact shell pass currentIndex straight in.
      for (var i = 0; i < kNileDestinations.length; i++) {
        expect(kNileBranchDestinations[i].label, kNileDestinations[i].label);
      }
    });

    test('Schedule was appended, so no branch index moved', () {
      expect(kScheduleBranch, kNileBranchDestinations.length - 1);
      expect(kNileBranchDestinations[kScheduleBranch].label, 'Schedule');
    });

    test('the rail matches the wireframe, in order', () {
      expect(
        kNileRailDestinations.map((d) => d.label).toList(),
        ['Home', 'Schedule', 'Discover', 'Currents', 'Messages',
         'Notifications', 'My Tickets'],
      );
    });

    test('the rail shows every branch except Profile, exactly once', () {
      final branches =
          kNileRailEntries.map((e) => e.branch).nonNulls.toList();
      expect(branches.toSet().length, branches.length);
      for (var b = 0; b < kNileBranchDestinations.length; b++) {
        // Profile (3) is deliberately absent — the top-bar avatar is its door.
        expect(branches.contains(b), b != 3);
      }
    });

    test('rail route paths match the router', () {
      // The entries hold literals to keep nile_destinations.dart free of a
      // dependency on router.dart; this is what stops them drifting.
      final routes =
          kNileRailEntries.map((e) => e.location).nonNulls.toList();
      expect(routes, [
        NileRoutes.currents,
        NileRoutes.notifications,
        NileRoutes.settingsTickets,
      ]);
    });

    test('only Messages and Notifications carry a badge', () {
      for (final e in kNileRailEntries) {
        final expected = switch (e.destination.label) {
          'Messages' => NileRailBadge.messages,
          'Notifications' => NileRailBadge.notifications,
          _ => NileRailBadge.none,
        };
        expect(e.badge, expected, reason: e.destination.label);
      }
    });

    test('slot and branch round-trip', () {
      for (var b = 0; b < kNileBranchDestinations.length; b++) {
        final slot = nileRailSlotForBranch(b);
        if (b == 3) {
          expect(slot, -1);
          continue;
        }
        expect(kNileRailEntries[slot].branch, b);
      }
      // An index with no row reports -1 rather than falling back to Home,
      // which would claim you are somewhere you are not.
      expect(nileRailSlotForBranch(99), -1);
      expect(nileRailSlotForBranch(-1), -1);
    });

    test('cmd-digits follow the rail, not the branch list', () {
      final map = NileShortcuts.debugTabKeys;
      // Values are rail slots now, because three rows have no branch at all.
      expect(map[LogicalKeyboardKey.digit1], 0); // Home
      expect(map[LogicalKeyboardKey.digit2], 1); // Schedule
      expect(map[LogicalKeyboardKey.digit3], 2); // Discover
      expect(map[LogicalKeyboardKey.digit4], 3); // Currents
      expect(map[LogicalKeyboardKey.digit5], 4); // Messages
      expect(map.length, 5);
      expect(kNileRailEntries[1].branch, kScheduleBranch);
    });
  });

  group('Calendar maths', () {
    test('nileDayKey collapses a whole day onto one bucket', () {
      final morning = DateTime(2026, 8, 9, 0, 0);
      final night = DateTime(2026, 8, 9, 23, 59);
      expect(nileDayKey(morning), nileDayKey(night));
      expect(nileDayKey(night), DateTime(2026, 8, 9));
      // And keeps adjacent days apart.
      expect(nileDayKey(DateTime(2026, 8, 10, 0, 1)), isNot(nileDayKey(night)));
    });

    test('nileMondayOf lands on Monday from every day of the week', () {
      // 2026-08-10 is a Monday.
      for (var i = 0; i < 7; i++) {
        final day = DateTime(2026, 8, 10 + i);
        expect(nileMondayOf(day), DateTime(2026, 8, 10));
        expect(nileMondayOf(day).weekday, DateTime.monday);
      }
      // A Sunday belongs to the week that started six days earlier, not the
      // one about to begin.
      expect(nileMondayOf(DateTime(2026, 8, 16)), DateTime(2026, 8, 10));
      expect(nileMondayOf(DateTime(2026, 8, 17)), DateTime(2026, 8, 17));
    });

    test('nileAddDays stays on midnight across a DST boundary', () {
      // US DST ends 2026-11-01. Stepping a week either side of it with a
      // Duration would land at 23:00 or 01:00 and shift every day bucket after
      // it; wall-clock construction cannot.
      for (final start in [
        DateTime(2026, 10, 26), // the Monday before
        DateTime(2026, 3, 2), // the Monday before spring forward
      ]) {
        final next = nileAddDays(start, 7);
        expect(next.hour, 0);
        expect(next.minute, 0);
        expect(next.weekday, start.weekday);
        expect(nileDayKey(next), next);
      }
    });

    test('a week of days is seven distinct consecutive days', () {
      final monday = nileMondayOf(DateTime(2026, 11, 1));
      final week = [for (var i = 0; i < 7; i++) nileAddDays(monday, i)];
      expect(week.toSet().length, 7);
      expect(week.first.weekday, DateTime.monday);
      expect(week.last.weekday, DateTime.sunday);
      for (final d in week) {
        expect(d.hour, 0);
      }
    });

    test('nileClock reads noon and midnight the way a person does', () {
      expect(nileClock(DateTime(2026, 8, 9, 0, 5)), '12:05 AM');
      expect(nileClock(DateTime(2026, 8, 9, 12, 0)), '12:00 PM');
      expect(nileClock(DateTime(2026, 8, 9, 13, 30)), '1:30 PM');
      expect(nileClock(DateTime(2026, 8, 9, 9, 7)), '9:07 AM');
    });

    test('nileDayLabel names today and tomorrow, then dates', () {
      final now = DateTime(2026, 8, 9, 15);
      expect(nileDayLabel(DateTime(2026, 8, 9), now: now), 'Today');
      expect(nileDayLabel(DateTime(2026, 8, 10), now: now), 'Tomorrow');
      expect(nileDayLabel(DateTime(2026, 8, 12), now: now), 'Wed 12');
    });
  });

  group('nileTopicTint', () {
    test('is stable for the same topic and spread across topics', () {
      expect(nileTopicTint('topic-a'), nileTopicTint('topic-a'));
      final tints = {
        for (final id in [
          'a1',
          'b2',
          'c3',
          'd4',
          'e5',
          'f6',
          'worship',
          'sports',
        ])
          nileTopicTint(id),
      };
      // Not a guarantee of uniqueness — it's a hash into a fixed palette — but
      // eight topics collapsing to one or two colours would defeat the point.
      expect(tints.length, greaterThan(2));
    });
  });
}
