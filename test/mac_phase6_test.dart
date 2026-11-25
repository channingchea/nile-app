// Phase 6 — the Mac-native layer.
//
// Everything AppKit-facing (the menu bar, the tray, the Dock badge, the window
// title) is a no-op off macOS, and the test VM is not macOS, so what is worth
// asserting here is the logic underneath: the route→title mapping, the shared
// badge poll's consumer count, and that none of it leaks into the phone tree.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nile_app/services/mac_host.dart';
import 'package:nile_app/services/nile_badges.dart';
import 'package:nile_app/services/nile_window_title.dart';
import 'package:nile_app/widgets/nile_destinations.dart';
import 'package:nile_app/widgets/nile_menu_bar.dart';

void main() {
  test('the Mac layer is inert off macOS', () {
    // Everything below leans on this: MacHost short-circuits before touching a
    // channel, so no test needs to stub one.
    expect(MacHost.supported, isFalse);
  });

  group('window title', () {
    test('names every rail row exactly as the rail names it', () {
      for (final entry in kNileRailEntries) {
        final location = entry.isBranch
            ? kNileBranchLocations[entry.branch!]
            : entry.location!;
        expect(
          NileWindowTitle.titleFor(location),
          entry.destination.label,
          reason: location,
        );
      }
    });

    test('names the detail routes by kind, not by id', () {
      const cases = {
        '/settings': 'Settings',
        '/settings/payouts': 'Settings',
        '/event/abc-123': 'Event',
        '/event/abc-123/replay': 'Event',
        '/watch/room-1': 'Live',
        '/stream/room-1': 'Go Live',
        '/dm/user-1': 'Messages',
        '/post/post-1': 'Post',
        '/u/user-1': 'Profile',
        '/profile': 'Profile',
        '/create/post': 'New Post',
        '/create/event': 'New Event',
      };
      cases.forEach((location, title) {
        expect(NileWindowTitle.titleFor(location), title, reason: location);
      });
    });

    test('falls back to the app name rather than guessing', () {
      for (final location in ['/login', '/splash', '/nothing-here', '/']) {
        if (location == '/') continue; // that one is Home, covered above.
        expect(NileWindowTitle.titleFor(location), 'Nile', reason: location);
      }
    });
  });

  group('NileBadges', () {
    setUp(NileBadges.resetForTesting);
    tearDown(NileBadges.resetForTesting);

    test('one timer serves however many consumers ask for it', () {
      expect(NileBadges.isPolling, isFalse);
      NileBadges.listen();
      NileBadges.listen();
      expect(NileBadges.isPolling, isTrue);

      // The rail going away must not stop the Dock badge counting.
      NileBadges.release();
      expect(NileBadges.isPolling, isTrue);

      NileBadges.release();
      expect(NileBadges.isPolling, isFalse);
    });

    test('an unbalanced release cannot drive the count negative', () {
      NileBadges.release();
      NileBadges.listen();
      NileBadges.release();
      expect(NileBadges.isPolling, isFalse);
    });

    test('clearing a badge is immediate, and independent per kind', () {
      NileBadges.notifications.value = 4;
      NileBadges.messages.value = 2;

      NileBadges.clearMessages();
      expect(NileBadges.messages.value, 0);
      expect(NileBadges.notifications.value, 4);
    });
  });

  testWidgets('NileMenuBar is a pass-through off macOS', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: NileMenuBar(child: Text('body'))),
    );
    expect(find.text('body'), findsOneWidget);
    // Not merely absent from the screen — never built at all, which is what
    // keeps the phone tree byte-for-byte what shipped.
    expect(find.byType(PlatformMenuBar), findsNothing);
  });
}
