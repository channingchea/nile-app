// Studio Preview — the on-device rehearsal of the host Studio.
//
// The one guarantee that matters most is that a preview can never broadcast,
// so it is checked against the source rather than trusted to review. The rest
// covers the saved settings the real Studio now reads, the demo content, the
// shared control bar and the layouts at real Mac window widths.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nile_app/screens/studio_preview_screen.dart';
import 'package:nile_app/services/nile_badges.dart';
import 'package:nile_app/services/studio_prefs.dart';
import 'package:nile_app/widgets/nile_app_shell.dart';
import 'package:nile_app/services/studio_mode.dart';
import 'package:nile_app/widgets/nile_studio.dart';
import 'package:nile_app/widgets/nile_studio_mode_switch.dart';
import 'package:nile_app/widgets/nile_top_bar.dart';
import 'package:nile_app/widgets/studio_preview_demo.dart';

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: child), debugShowCheckedModeBanner: false);

Future<void> _size(WidgetTester tester, double width, [double height = 900]) {
  addTearDown(() => tester.view.resetPhysicalSize());
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  return tester.pump();
}

/// The Studio as the preview composes it, with a full chat column of demo
/// lines — the worst case for overflow.
Widget _previewStudio(StudioPreviewDemo demo, {required bool chatColumn}) {
  final chat = NileStudioChat(
    messages: demo.messages,
    hiddenSenders: demo.hiddenSenders,
    blockedSenders: const {},
    selfId: null,
    onHide: (m) => demo.hide(m.senderId),
    onShowAll: demo.showAll,
    onBlock: (_) {},
    onReport: (_) {},
  );
  return NileStudio(
    sources: [
      const NileStudioSource(
        identity: 'preview:self',
        label: 'Your camera',
        isLocal: true,
        isMasterAudio: true,
      ),
      ...StudioPreviewDemo.crew,
    ],
    selectedIdentity: null,
    onSelectSource: (_) {},
    selfIdentity: 'preview:self',
    stats: NileStudioStats(
      isLive: demo.isLive,
      elapsed: demo.elapsed,
      remaining: demo.remaining,
      viewerCount: demo.viewerCount,
      readyCount: demo.readyCount,
      crewCount: demo.crewCount,
      audioSourceLabel: 'Your mic',
    ),
    center: NileStudioModeSwitch(
      value: StudioMode.multicam,
      onChanged: (_) {},
    ),
    banner: StudioPreviewBanner(live: demo.isLive, onChanged: (_) {}),
    controls: NileStudioControlBar(
      isLive: demo.isLive,
      isHost: true,
      isMasterAudio: true,
      videoEnabled: true,
      showChatToggle: !chatColumn,
      showScreenShare: true,
      cameraControl: const NileStudioIconButton(
        onPressed: null,
        tooltip: 'Choose camera',
        icon: Icons.cameraswitch_outlined,
      ),
      onLeave: () {},
      leaveLabel: 'Exit',
      leaveIcon: Icons.close,
    ),
    showChatColumn: chatColumn,
    chat: chatColumn ? chat : null,
  );
}

void main() {
  group('safety', () {
    // Studio Preview runs your real camera and mic. The only thing standing
    // between that and a broadcast is that these files never reach for a
    // room, an event, chat or crew. Checked on the source so a future edit
    // that "just reuses" a service fails here, not in front of an audience.
    test('the preview never touches a room, event, chat or crew', () {
      const banned = [
        'Room(',
        'LivekitService',
        'EventService',
        'ChatService',
        'CrewService',
        'supabase',
        'publishVideoTrack',
        'publishAudioTrack',
        'publishData',
        'AngleWatchers',
        'setShow',
      ];
      for (final path in [
        'lib/screens/studio_preview_screen.dart',
        'lib/widgets/studio_preview_demo.dart',
      ]) {
        // Comments may describe what the file avoids; code may not use it.
        final code = File(path)
            .readAsLinesSync()
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        for (final word in banned) {
          expect(code.contains(word), isFalse, reason: '$path uses $word');
        }
      }
    });

    test('the preview route takes no app chrome, like the real Studio', () {
      expect(NileAppShell.isBare('/studio-preview'), isTrue);
    });
  });

  group('StudioPrefs', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults match the Studio as it shipped', () async {
      final p = await StudioPrefs.load();
      expect(p.cameraDeviceId, isNull);
      expect(p.externalMicProcessing, isFalse);
      expect(p.chatVisible, isTrue);
      expect(p.videoStartsOff, isFalse);
    });

    test('choices survive a reload', () async {
      final p = await StudioPrefs.load();
      p
        ..cameraDeviceId = 'cam-usb'
        ..externalMicProcessing = true
        ..chatVisible = false
        ..videoStartsOff = true;
      await pumpEventQueue();
      final again = await StudioPrefs.load();
      expect(again.cameraDeviceId, 'cam-usb');
      expect(again.externalMicProcessing, isTrue);
      expect(again.chatVisible, isFalse);
      expect(again.videoStartsOff, isTrue);
    });

    test('picking the default camera forgets the saved one', () async {
      final p = await StudioPrefs.load();
      p.cameraDeviceId = 'cam-usb';
      await pumpEventQueue();
      p.cameraDeviceId = null;
      await pumpEventQueue();
      expect((await StudioPrefs.load()).cameraDeviceId, isNull);
    });
  });

  group('demo content', () {
    test('chat keeps only the latest lines', () {
      final demo = StudioPreviewDemo();
      for (var i = 0; i < StudioPreviewDemo.maxMessages + 10; i++) {
        demo.addMessage();
      }
      expect(demo.messages.length, StudioPreviewDemo.maxMessages);
      demo.dispose();
    });

    test('Sound Check has no clock or audience; Live has both', () {
      final demo = StudioPreviewDemo();
      expect(demo.elapsed, isNull);
      expect(demo.viewerCount, 0);
      demo.isLive = true;
      expect(demo.elapsed, isNotNull);
      expect(demo.viewerCount, inInclusiveRange(40, 120));
      // Just outside the countdown window at the start, so it appears soon.
      expect(demo.remaining, isNull);
      expect(
        StudioPreviewDemo.showLength - StudioPreviewDemo.countdownWindow,
        lessThanOrEqualTo(const Duration(minutes: 1)),
      );
      demo.isLive = false;
      expect(demo.elapsed, isNull);
      demo.dispose();
    });

    test('two demo crew cameras, one ready', () {
      final demo = StudioPreviewDemo();
      expect(demo.readyCount, 1);
      expect(demo.crewCount, 2);
      // "demo:" not "crew:" — the Studio treats crew: rows as absent, and
      // these rehearse a connected camera's meter, health and remote controls.
      expect(
        StudioPreviewDemo.crew.every((c) => c.identity.startsWith('demo:')),
        isTrue,
      );
      demo.dispose();
    });

    test('hide is local and reversible', () {
      final demo = StudioPreviewDemo()..addMessage();
      final sender = demo.messages.single.senderId;
      demo.hide(sender);
      expect(demo.hiddenSenders, {sender});
      demo.showAll();
      expect(demo.hiddenSenders, isEmpty);
      demo.dispose();
    });
  });

  group('control bar', () {
    NileStudioControlBar bar({
      bool live = false,
      bool master = true,
      bool video = true,
    }) => NileStudioControlBar(
      isLive: live,
      isHost: true,
      isMasterAudio: master,
      videoEnabled: video,
      onLeave: () {},
      leaveLabel: 'Exit',
    );

    testWidgets('Sound Check offers Start Show; Live offers End Stream', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(bar()));
      expect(find.text('Start Show'), findsOneWidget);
      expect(find.text('View as Viewer'), findsOneWidget);
      expect(find.text('End Stream'), findsNothing);
      expect(find.text('Exit'), findsOneWidget);

      await tester.pumpWidget(_wrap(bar(live: true)));
      expect(find.text('Start Show'), findsNothing);
      expect(find.text('End Stream'), findsOneWidget);
    });

    testWidgets('a camera that started off can always turn back on', (
      tester,
    ) async {
      // Not master audio, so Video Off would normally be hidden — but a
      // camera opened with "Start with camera off" needs a way back.
      await tester.pumpWidget(_wrap(bar(master: false, video: false)));
      expect(find.text('Video On'), findsOneWidget);
      await tester.pumpWidget(_wrap(bar(master: false)));
      expect(find.text('Video Off'), findsNothing);
    });
  });

  group('layout', () {
    for (final (width, chatColumn) in [
      (740.0, false), // the narrowest window a Mac can make
      (1180.0, true), // the third column arrives
      (1728.0, true), // a maximised 16-inch MacBook
    ]) {
      testWidgets('no overflow at $width with a full chat', (tester) async {
        await _size(tester, width);
        final demo = StudioPreviewDemo();
        for (var i = 0; i < StudioPreviewDemo.maxMessages; i++) {
          demo.addMessage();
        }
        await tester.pumpWidget(_wrap(_previewStudio(demo, chatColumn: chatColumn)));
        expect(tester.takeException(), isNull);
        expect(find.text('Rehearsal — not live. Only you can see this.'),
            findsOneWidget);

        demo.isLive = true;
        await tester.pumpWidget(_wrap(_previewStudio(demo, chatColumn: chatColumn)));
        expect(tester.takeException(), isNull);
        expect(find.text('End Stream'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
        demo.dispose();
      });
    }

    testWidgets('start screen asks first, and promises privacy', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await _size(tester, 1280);
      await tester.pumpWidget(
        const MaterialApp(home: StudioPreviewScreen()),
      );
      expect(find.text('Start preview'), findsOneWidget);
      expect(find.textContaining('nothing is broadcast or recorded'),
          findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a phone-width window is asked to widen, not given a Studio', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await _size(tester, 500);
      await tester.pumpWidget(
        const MaterialApp(home: StudioPreviewScreen()),
      );
      expect(find.text('Start preview'), findsNothing);
      expect(find.textContaining('needs a wider window'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('notifications bell', () {
    setUp(NileBadges.resetForTesting);
    tearDown(NileBadges.resetForTesting);

    testWidgets('carries the unread count and says it', (tester) async {
      await tester.pumpWidget(_wrap(const NileNotificationsBell()));
      expect(find.bySemanticsLabel('Notifications'), findsOneWidget);

      NileBadges.notifications.value = 3;
      await tester.pump();
      expect(find.text('3'), findsOneWidget);
      expect(find.bySemanticsLabel('Notifications, 3 unread'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
