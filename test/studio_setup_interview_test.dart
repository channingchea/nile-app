// Studio Setup, Interview mode: the rehearsal's demo guests, green room and
// stage. The demo's clock is the test's, so countdowns and arrivals run on
// demand; the screen opens without camera or mic.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nile_app/screens/studio_preview_screen.dart';
import 'package:nile_app/services/interview.dart';
import 'package:nile_app/widgets/interview_green_room.dart';
import 'package:nile_app/widgets/interview_stage.dart';
import 'package:nile_app/widgets/studio_setup_interview_demo.dart';

const _host = StudioSetupInterviewDemo.hostId;
final _maya = StudioSetupInterviewDemo.guests[0];
final _jordan = StudioSetupInterviewDemo.guests[1];
final _priya = StudioSetupInterviewDemo.guests[2];

/// A demo on a hand-wound clock.
class _Clock {
  int ms = 1000000;
  int call() => ms;
}

StudioSetupInterviewDemo _demo(_Clock clock) =>
    StudioSetupInterviewDemo(random: Random(3), clock: clock.call);

/// Opens Studio Setup at [size], starts the rehearsal and switches to
/// Interview.
Future<StudioSetupInterviewDemo> _openInterview(
  WidgetTester tester,
  Size size,
  _Clock clock,
) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final demo = _demo(clock);
  await tester.pumpWidget(
    MaterialApp(
      home: StudioPreviewScreen(openDevices: false, interviewDemo: demo),
    ),
  );
  await tester.tap(find.text('Start preview'));
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(find.text('Your camera'), findsWidgets);
  await tester.tap(find.text('Interview'));
  await tester.pump();
  expect(tester.takeException(), isNull);
  return demo;
}

/// Steps the clock and lets the demo's timer notice.
Future<void> _advance(WidgetTester tester, _Clock clock, int ms) async {
  clock.ms += ms;
  await tester.pump(const Duration(milliseconds: 200));
}

/// Scrolls the green room (a lazy list) until [finder] is built and on screen.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  final list = find
      .descendant(
        of: find.byType(InterviewGreenRoomColumn),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.drag(list, const Offset(0, 3000));
  await tester.pump();
  await tester.scrollUntilVisible(finder, 150, scrollable: list);
}

/// Leaves the app's messenger mounted while the screen goes, as in the app,
/// so the screen's dispose can clear its toasts.
Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

Finder _button<T extends Widget>(String label, String guestName) =>
    find.descendant(
      of: find.ancestor(
        of: find.text(guestName),
        matching: find.byType(GreenRoomTile),
      ),
      matching: find.widgetWithText(T, label),
    );

void main() {
  group('demo', () {
    test('you start on stage; the invited guest joins after 10 s', () {
      final clock = _Clock();
      final demo = _demo(clock)..start();
      addTearDown(demo.dispose);
      final joined = <String>[];
      demo.onJoined = (g) => joined.add(g.id);

      expect(demo.stage.ids, [_host]);
      expect(demo.statusOf(_priya.id), GuestStatus.invited);
      clock.ms += 9000;
      demo.tick();
      expect(joined, isEmpty);
      clock.ms += 1000;
      demo.tick();
      expect(joined, [_priya.id]);
      expect(demo.statusOf(_priya.id), GuestStatus.greenRoom);
    });

    test('bring on counts down 5 s, then introduces them once', () {
      final clock = _Clock();
      final demo = _demo(clock)..start();
      addTearDown(demo.dispose);
      final introduced = <String>[];
      demo.onCameOn = (g) => introduced.add(g.id);

      expect(demo.bringOn(_maya.id), isTrue);
      expect(demo.stage.countdownFor(_maya.id, demo.now), 5);
      expect(demo.stage.visibleAt(demo.now), [_host]);
      clock.ms += 4999;
      demo.tick();
      expect(introduced, isEmpty);
      clock.ms += 1;
      demo.tick();
      demo.tick();
      expect(introduced, [_maya.id]);
      expect(demo.stage.visibleAt(demo.now), [_host, _maya.id]);
      expect(demo.onStageFor(_maya.id), Duration.zero);
    });

    test('the stage holds six, you included', () {
      final clock = _Clock();
      final demo = _demo(clock)..start();
      addTearDown(demo.dispose);
      while (demo.addGuest() != null) {}
      expect(demo.canAddGuest, isFalse);
      clock.ms += 10000;
      demo.tick();
      final guests = StudioSetupInterviewDemo.guests;
      for (final g in guests.take(5)) {
        expect(demo.bringOn(g.id), isTrue);
      }
      expect(demo.stage.isFull, isTrue);
      expect(demo.bringOn(guests.last.id), isFalse);
      expect(demo.stage.ids.length, kStageMax);
    });

    test('send back, remove and invite back', () {
      final clock = _Clock();
      final demo = _demo(clock)..start();
      addTearDown(demo.dispose);
      demo
        ..bringOn(_jordan.id)
        ..feature(_jordan.id);
      expect(demo.stage.focus, _jordan.id);
      demo.sendBack(_jordan.id);
      expect(demo.stage.contains(_jordan.id), isFalse);
      expect(demo.stage.focus, isNull);
      expect(demo.statusOf(_jordan.id), GuestStatus.greenRoom);

      demo.remove(_jordan.id);
      expect(demo.statusOf(_jordan.id), GuestStatus.removed);
      expect(
        demo.greenRoomEntries(hostLevel: 0).map((e) => e.identity),
        isNot(contains(_jordan.id)),
      );
      expect(demo.addGuest()?.id, _jordan.id);
      expect(demo.statusOf(_jordan.id), GuestStatus.invited);
    });

    test('mute is instant; asking to unmute takes a moment', () {
      final clock = _Clock();
      final demo = _demo(clock)..start();
      addTearDown(demo.dispose);
      demo.setMuted(_maya.id, true);
      expect(demo.isMuted(_maya.id), isTrue);
      expect(demo.levelOf(_maya.id), 0);
      demo.setMuted(_maya.id, false);
      expect(demo.isMuted(_maya.id), isTrue);
      clock.ms += 2000;
      demo.tick();
      expect(demo.isMuted(_maya.id), isFalse);
    });

    test('private line and talk to all are local toggles', () {
      final demo = _demo(_Clock())..start();
      addTearDown(demo.dispose);
      expect(demo.talk(_maya.id), isTrue);
      expect(demo.talkingTo, _maya.id);
      // Brought on stage, the private line closes.
      demo.bringOn(_maya.id);
      expect(demo.talkingTo, isNull);
      demo.talkToAll(true);
      expect(demo.talkingToAll, isTrue);
      demo.stop();
      expect(demo.talkingToAll, isFalse);
      expect(demo.isRunning, isFalse);
    });
  });

  group('Studio Setup', () {
    for (final size in const [Size(1180, 800), Size(1728, 1000)]) {
      final w = size.width.toInt();

      testWidgets('Interview shows the green room and stage at $w', (
        tester,
      ) async {
        final clock = _Clock();
        final demo = await _openInterview(tester, size, clock);
        expect(find.text('GREEN ROOM'), findsOneWidget);
        expect(find.text('ON STAGE 1/$kStageMax'), findsOneWidget);
        expect(find.byType(InterviewStageView), findsOneWidget);
        expect(find.byType(StageLayoutPicker), findsOneWidget);
        expect(find.text(_maya.name), findsOneWidget);
        expect(find.text('Your camera'), findsNothing);
        expect(demo.isRunning, isTrue);

        await _advance(tester, clock, 10000);
        expect(demo.statusOf(_priya.id), GuestStatus.greenRoom);
        expect(
          find.text('${_priya.name} joined the green room.'),
          findsOneWidget,
        );
        await _reveal(tester, find.text(_priya.name));
        await tester.tap(find.byTooltip('Notes'));
        await tester.pump();
        expect(find.textContaining('aren’t saved'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _close(tester);
      });

      testWidgets('back to Multicam shows the camera list at $w', (
        tester,
      ) async {
        final demo = await _openInterview(tester, size, _Clock());
        await tester.tap(find.text('Multicam'));
        await tester.pump();
        expect(find.text('GREEN ROOM'), findsNothing);
        expect(find.byType(InterviewStageView), findsNothing);
        expect(find.text('Your camera'), findsWidgets);
        expect(demo.isRunning, isFalse, reason: 'no demo timer off screen');
        expect(tester.takeException(), isNull);
        await _close(tester);
      });
    }

    testWidgets('bring on: countdown, then on stage with a lower third', (
      tester,
    ) async {
      final clock = _Clock();
      final demo = await _openInterview(tester, const Size(1180, 800), clock);
      final bring = _button<FilledButton>('Bring on', _maya.name);
      await _reveal(tester, bring);
      await tester.tap(bring);
      await tester.pump();
      expect(demo.stage.ids, [_host, _maya.id]);
      await _reveal(tester, find.text('ON STAGE 2/$kStageMax'));
      expect(find.textContaining('On in 5'), findsOneWidget);
      // Their stage tile's name tag, counting down.
      expect(find.text(_maya.title), findsOneWidget);

      await _advance(tester, clock, 5000);
      expect(demo.stage.visibleAt(demo.now), contains(_maya.id));
      expect(find.textContaining('On in'), findsNothing);
      expect(find.text('${_maya.title} · On stage'), findsOneWidget);
      // Plus the automatic name lower third over the stage.
      expect(find.text(_maya.title), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await _close(tester);
    });

    testWidgets('a full stage turns Bring on off', (tester) async {
      final clock = _Clock();
      final demo = await _openInterview(tester, const Size(1728, 1000), clock);
      while (demo.addGuest() != null) {}
      await _advance(tester, clock, 10000);
      final guests = StudioSetupInterviewDemo.guests;
      for (final g in guests.take(5)) {
        demo.bringOn(g.id);
      }
      await tester.pump();
      expect(find.text('ON STAGE 6/$kStageMax'), findsOneWidget);
      final last = _button<FilledButton>('Bring on', guests.last.name);
      await _reveal(tester, last);
      expect(tester.widget<FilledButton>(last).onPressed, isNull);
      expect(tester.takeException(), isNull);
      await _close(tester);
    });

    testWidgets('send back takes you off the stage', (tester) async {
      final demo = await _openInterview(
        tester,
        const Size(1180, 800),
        _Clock(),
      );
      await tester.tap(_button<OutlinedButton>('Send back', 'You'));
      await tester.pump();
      expect(demo.stage.ids, isEmpty);
      expect(find.text('ON STAGE 0/$kStageMax'), findsOneWidget);
      expect(find.text('Bring someone on from the green room'), findsOneWidget);
      await _close(tester);
    });

    testWidgets('the layout picker changes the stage', (tester) async {
      final demo = await _openInterview(
        tester,
        const Size(1180, 800),
        _Clock(),
      );
      await tester.tap(find.byTooltip(StageLayout.spotlight.label));
      await tester.pump();
      expect(demo.stage.layout, StageLayout.spotlight);
      expect(find.text('STAGE · SPOTLIGHT'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  });
}
