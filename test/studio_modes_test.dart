// Studio modes, phase 1 (docs/plans/studio-modes.md): the mode value, the
// switch, its place in the Studio top bar, and the Studio Setup rename.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nile_app/services/event_service.dart';
import 'package:nile_app/services/studio_mode.dart';
import 'package:nile_app/widgets/nile_destinations.dart';
import 'package:nile_app/widgets/nile_studio.dart';
import 'package:nile_app/widgets/nile_studio_mode_switch.dart';

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: child), debugShowCheckedModeBanner: false);

Future<void> _size(WidgetTester tester, double width) {
  addTearDown(() => tester.view.resetPhysicalSize());
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  return tester.pump();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  group('StudioMode', () {
    test('reads the stored value; anything unknown is Multicam', () {
      expect(StudioMode.fromWire('interview'), StudioMode.interview);
      expect(StudioMode.fromWire('premiere'), StudioMode.premiere);
      expect(StudioMode.fromWire(null), StudioMode.multicam);
      expect(StudioMode.fromWire('talkshow'), StudioMode.multicam);
      for (final m in StudioMode.values) {
        expect(StudioMode.fromWire(m.wire), m);
      }
    });

    test('room metadata overrides only when the Studio set a mode', () {
      expect(
        StudioMode.fromRoomMetadata('{"mode":"premiere"}'),
        StudioMode.premiere,
      );
      expect(StudioMode.fromRoomMetadata('{"offAir":[]}'), isNull);
      expect(StudioMode.fromRoomMetadata(null), isNull);
      expect(StudioMode.fromRoomMetadata('not json'), isNull);
    });

    test('locked once live', () {
      expect(StudioMode.canSwitch(isLive: false), isTrue);
      expect(StudioMode.canSwitch(isLive: true), isFalse);
    });

    test('Event reads studio_mode and defaults to Multicam', () {
      Map<String, dynamic> row([String? mode]) => {
        'id': 'e1',
        'host_id': 'h1',
        'title': 'Show',
        'status': 'scheduled',
        'created_at': '2026-11-01T20:00:00Z',
        'studio_mode': ?mode,
      };
      expect(Event.fromJson(row()).studioMode, StudioMode.multicam);
      expect(Event.fromJson(row('interview')).studioMode, StudioMode.interview);
      expect(
        Event.fromJson(row('premiere')).copyWith(likeCount: 1).studioMode,
        StudioMode.premiere,
      );
    });
  });

  group('NileStudioModeSwitch', () {
    testWidgets('tapping another mode reports it; the current one does not', (
      tester,
    ) async {
      final picked = <StudioMode>[];
      await tester.pumpWidget(
        _wrap(
          Center(
            child: NileStudioModeSwitch(
              value: StudioMode.multicam,
              onChanged: picked.add,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Interview'));
      await tester.tap(find.text('Multicam'));
      await tester.tap(find.text('Premiere'));
      expect(picked, [StudioMode.interview, StudioMode.premiere]);
    });

    testWidgets('locked: nothing fires and the reason is the tooltip', (
      tester,
    ) async {
      final picked = <StudioMode>[];
      await tester.pumpWidget(
        _wrap(
          Center(
            child: NileStudioModeSwitch(
              value: StudioMode.multicam,
              onChanged: null,
              lockedReason: 'The mode can’t change while you’re live',
            ),
          ),
        ),
      );
      await tester.tap(find.text('Premiere'));
      expect(picked, isEmpty);
      expect(
        find.byTooltip('The mode can’t change while you’re live'),
        findsOneWidget,
      );
    });

    testWidgets('form field says when it is locked', (tester) async {
      await tester.pumpWidget(
        _wrap(
          StudioModeField(
            value: StudioMode.interview,
            onChanged: (_) {},
            locked: true,
          ),
        ),
      );
      expect(find.textContaining('Locked while you’re live'), findsOneWidget);
    });
  });

  group('Studio top bar', () {
    Widget studio() => NileStudio(
      sources: const [
        NileStudioSource(identity: 'me', label: 'Camera 1', isLocal: true),
      ],
      selectedIdentity: null,
      onSelectSource: (_) {},
      selfIdentity: 'me',
      stats: const NileStudioStats(
        isLive: false,
        crewCount: 3,
        readyCount: 2,
        audioSourceLabel: 'A long stream audio device name',
      ),
      leading: IconButton(onPressed: () {}, icon: const Icon(Icons.arrow_back)),
      trailing: IconButton(onPressed: () {}, icon: const Icon(Icons.settings)),
      center: NileStudioModeSwitch(
        value: StudioMode.multicam,
        onChanged: (_) {},
      ),
      controls: const SizedBox(height: 48),
      showChatColumn: false,
    );

    for (final width in [740.0, 1024.0, 1440.0]) {
      testWidgets('switch is centered and nothing overflows at $width pt', (
        tester,
      ) async {
        await _size(tester, width);
        await tester.pumpWidget(_wrap(studio()));
        expect(tester.takeException(), isNull);
        final box = tester.getRect(find.byType(NileStudioModeSwitch));
        expect(box.center.dx, moreOrLessEquals(width / 2, epsilon: 0.5));
      });
    }
  });

  test('Studio Preview is now called Studio Setup', () {
    expect(kStudioPreviewDestination.label, 'Studio Setup');
  });
}
