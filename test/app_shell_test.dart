// Phase 7 — the desktop chrome's routing decisions.
//
// NileAppShell decides three things from a location string: whether a route
// gets chrome at all, whether it keeps the context rail, and which rail item
// lights up. All three are pure functions of that string (plus, for the last
// one, the branch the shell last published), which is deliberate — it is what
// makes them checkable here rather than only by clicking around a running app.
//
// The stakes are asymmetric. Getting `isBare` wrong puts a nav rail on the
// camera screen mid-broadcast; getting `wantsFullWidth` wrong quietly halves
// the width the live viewer's chat column was designed against.

import 'package:flutter_test/flutter_test.dart';

import 'package:nile_app/router.dart';
import 'package:nile_app/services/shell_state.dart';
import 'package:nile_app/widgets/nile_app_shell.dart';
import 'package:nile_app/widgets/nile_destinations.dart';

void main() {
  group('isBare — routes that get no chrome at all', () {
    test('the camera and studio', () {
      expect(NileAppShell.isBare('/stream/room-123'), isTrue);
    });

    test('every creation flow', () {
      for (final loc in ['/create/post', '/create/event', '/create/current']) {
        expect(NileAppShell.isBare(loc), isTrue, reason: loc);
      }
    });

    test('nothing else', () {
      for (final loc in [
        '/',
        '/discover',
        '/messages',
        '/profile',
        '/schedule',
        '/event/abc',
        '/watch/abc',
        '/settings',
        '/notifications',
      ]) {
        expect(NileAppShell.isBare(loc), isFalse, reason: loc);
      }
    });

    test('does not confuse a lookalike path for a creation flow', () {
      // '/created' and '/streams' are not '/create/' and '/stream/'.
      expect(NileAppShell.isBare('/created'), isFalse);
      expect(NileAppShell.isBare('/streams'), isFalse);
    });
  });

  group('wantsFullWidth — routes that take the context rail\'s width', () {
    test('the screens that own a right-hand column of their own', () {
      for (final loc in [
        '/schedule',
        '/messages',
        '/currents',
        '/watch/room-123',
        '/dm/user-123',
      ]) {
        expect(NileAppShell.wantsFullWidth(loc), isTrue, reason: loc);
      }
    });

    test('the event page and its replay player', () {
      expect(NileAppShell.wantsFullWidth('/event/abc'), isTrue);
      expect(NileAppShell.wantsFullWidth('/event/abc/replay'), isTrue);
    });

    test("but not the event page's sub-forms", () {
      // These are ordinary column-width screens; a form does not need the
      // window and does benefit from what's-on beside it.
      for (final sub in ['edit', 'attendees', 'crew', 'likes', 'replay-pricing']) {
        expect(
          NileAppShell.wantsFullWidth('/event/abc/$sub'),
          isFalse,
          reason: sub,
        );
      }
    });

    test('the feed and the other branch roots keep their rail', () {
      for (final loc in ['/', '/discover', '/profile', '/notifications']) {
        expect(NileAppShell.wantsFullWidth(loc), isFalse, reason: loc);
      }
    });
  });

  group('selectedBranch — which rail item lights up', () {
    setUp(() => NileShellState.branch.value = 0);

    test('a branch root names its own branch', () {
      for (var b = 0; b < kNileBranchLocations.length; b++) {
        expect(NileAppShell.selectedBranch(kNileBranchLocations[b]), b);
      }
    });

    test('a pushed route keeps the branch you opened it from', () {
      // Standing on Discover, opening an event must not jump the rail to Home.
      NileShellState.branch.value = 1;
      expect(NileAppShell.selectedBranch('/event/abc'), 1);
      expect(NileAppShell.selectedBranch('/settings'), 1);
      NileShellState.branch.value = kScheduleBranch;
      expect(NileAppShell.selectedBranch('/event/abc'), kScheduleBranch);
    });

    test('every branch location with a rail row resolves to it', () {
      for (var b = 0; b < kNileBranchLocations.length; b++) {
        final slot = NileAppShell.selectedRailSlot(kNileBranchLocations[b]);
        if (b == 3) {
          // Profile has no rail row — the avatar in the top bar is its door —
          // so standing on it highlights nothing.
          expect(slot, -1);
          continue;
        }
        expect(slot, inInclusiveRange(0, kNileRailEntries.length - 1));
        expect(kNileRailEntries[slot].branch, b);
      }
    });

    test('a rail route outranks the branch underneath it', () {
      NileShellState.branch.value = 0;
      for (final e in kNileRailEntries.where((e) => !e.isBranch)) {
        final slot = NileAppShell.selectedRailSlot(e.location!);
        expect(kNileRailEntries[slot].location, e.location);
      }
    });

    test('a pushed detail route falls back to its branch row', () {
      NileShellState.branch.value = 1; // Discover
      final slot = NileAppShell.selectedRailSlot('/event/abc');
      expect(kNileRailEntries[slot].destination.label, 'Discover');
    });
  });

  group('branch locations', () {
    test('there is one per branch, in branch order', () {
      expect(kNileBranchLocations.length, kNileBranchDestinations.length);
      expect(kNileBranchLocations[0], NileRoutes.feed);
      expect(kNileBranchLocations[2], NileRoutes.messages);
      expect(kNileBranchLocations[kScheduleBranch], NileRoutes.schedule);
    });

    test('they are distinct — two branches sharing a location would make the '
        'rail ambiguous', () {
      expect(
        kNileBranchLocations.toSet().length,
        kNileBranchLocations.length,
      );
    });

    test('none of them is bare, or the shell would vanish on a tab', () {
      for (final loc in kNileBranchLocations) {
        expect(NileAppShell.isBare(loc), isFalse, reason: loc);
      }
    });
  });
}
