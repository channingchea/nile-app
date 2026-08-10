// Phase 8 — the macOS Studio.
//
// Same principle as the other desktop tests: assert the decisions, not the
// pixels. Three families here:
//   1. Column arithmetic — that a monitor still has room to be a monitor at the
//      narrowest window a Mac can make, and at the three-column threshold.
//   2. Roster behaviour — which feed the monitor falls back to, and when the
//      self-preview is redundant.
//   3. Moderation — who can be moderated and whose messages disappear. This is
//      the part with real consequences, and chat is ephemeral so there is no
//      server-side test to catch a mistake here.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nile_app/services/chat_service.dart';
import 'package:nile_app/theme.dart';
import 'package:nile_app/widgets/nile_app_shell.dart';
import 'package:nile_app/widgets/nile_studio.dart';

/// Width left for the monitor at [windowWidth], mirroring `NileStudio.build`.
/// Two 1 px dividers when the chat column is in, one when it isn't.
double _monitorWidth(double windowWidth) {
  final window = NileBreakpoints.classify(Size(windowWidth, 900));
  final chat = window.hasContextRail;
  final dividers = chat ? 2.0 : 1.0;
  return windowWidth -
      NileStudio.sourceColumnWidth -
      (chat ? NileStudio.chatColumnWidth : 0) -
      dividers;
}

NileStudioSource _source(
  String identity, {
  String? label,
  bool isLocal = false,
  bool isScreenShare = false,
}) => NileStudioSource(
  identity: identity,
  label: label ?? identity,
  isLocal: isLocal,
  isScreenShare: isScreenShare,
);

ChatMessage _msg(String senderId, String username, String content) =>
    ChatMessage(
      senderId: senderId,
      username: username,
      content: content,
      sentAt: DateTime(2026, 8, 10),
    );

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: child), debugShowCheckedModeBanner: false);

void main() {
  group('column arithmetic', () {
    test('the monitor keeps usable width at the minimum macOS window', () {
      // MainFlutterWindow pins minSize to 740×600, so this is the narrowest
      // Studio that can exist on a Mac. Two columns there, not three.
      expect(NileBreakpoints.classify(const Size(740, 600)).hasContextRail,
          isFalse);
      expect(_monitorWidth(740), greaterThan(500));
    });

    test('the chat column arrives with the shell\'s context rail, not before',
        () {
      expect(NileBreakpoints.classify(const Size(1179, 900)).hasContextRail,
          isFalse);
      expect(NileBreakpoints.classify(const Size(1180, 900)).hasContextRail,
          isTrue);
      // Adding a third column must not starve the monitor at the threshold.
      expect(_monitorWidth(1180), greaterThan(600));
    });

    test('a maximised 16-inch MacBook gives the monitor the surplus', () {
      expect(_monitorWidth(1728), closeTo(1174, 1));
    });

    test('the stream route takes no app chrome', () {
      // The Studio owns the whole window; a nav rail beside a live broadcast
      // is an invitation to click away mid-show.
      expect(NileAppShell.isBare('/stream/my-show'), isTrue);
    });
  });

  group('clock formatting', () {
    test('drops the hour until there is one', () {
      expect(
        NileStudioStats.formatClock(const Duration(minutes: 9, seconds: 5)),
        '09:05',
      );
      expect(
        NileStudioStats.formatClock(
          const Duration(hours: 2, minutes: 3, seconds: 4),
        ),
        '2:03:04',
      );
    });
  });

  group('roster', () {
    testWidgets('an unknown selection falls back to the first source', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          NileStudio(
            sources: [
              _source('camera-1', label: 'Stage Left'),
              _source('camera-2', label: 'Stage Right'),
            ],
            // The selected camera dropped mid-show.
            selectedIdentity: 'camera-gone',
            onSelectSource: (_) {},
            selfIdentity: null,
            stats: const NileStudioStats(isLive: true),
            controls: const SizedBox.shrink(),
            showChatColumn: false,
          ),
        ),
      );
      expect(find.text('MONITOR · Stage Left'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('your own camera is not previewed twice', (tester) async {
      final sources = [
        _source('camera-me', label: 'You · Desk Cam', isLocal: true),
        _source('camera-2', label: 'Stage Right'),
      ];

      // Monitoring yourself: the second pane would be the same picture.
      await tester.pumpWidget(
        _wrap(
          NileStudio(
            sources: sources,
            selectedIdentity: 'camera-me',
            onSelectSource: (_) {},
            selfIdentity: 'camera-me',
            stats: const NileStudioStats(isLive: false),
            controls: const SizedBox.shrink(),
            showChatColumn: false,
          ),
        ),
      );
      expect(find.text('YOUR CAMERA'), findsNothing);

      // Monitoring someone else: you need your own framing back.
      await tester.pumpWidget(
        _wrap(
          NileStudio(
            sources: sources,
            selectedIdentity: 'camera-2',
            onSelectSource: (_) {},
            selfIdentity: 'camera-me',
            stats: const NileStudioStats(isLive: false),
            controls: const SizedBox.shrink(),
            showChatColumn: false,
          ),
        ),
      );
      expect(find.text('YOUR CAMERA'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tapping a source selects it', (tester) async {
      String? picked;
      await tester.pumpWidget(
        _wrap(
          NileStudio(
            sources: [
              _source('camera-1', label: 'Stage Left'),
              _source('camera-2', label: 'Stage Right'),
            ],
            selectedIdentity: 'camera-1',
            onSelectSource: (id) => picked = id,
            selfIdentity: null,
            stats: const NileStudioStats(isLive: false),
            controls: const SizedBox.shrink(),
            showChatColumn: false,
          ),
        ),
      );
      await tester.tap(find.text('Stage Right'));
      expect(picked, 'camera-2');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the chat column appears only when asked for', (tester) async {
      Widget studio({required bool chat}) => _wrap(
        NileStudio(
          sources: [_source('camera-1')],
          selectedIdentity: 'camera-1',
          onSelectSource: (_) {},
          selfIdentity: null,
          stats: const NileStudioStats(isLive: true),
          controls: const SizedBox.shrink(),
          showChatColumn: chat,
          chat: NileStudioChat(
            messages: const [],
            hiddenSenders: const {},
            blockedSenders: const {},
            selfId: null,
            onHide: (_) {},
            onShowAll: () {},
            onBlock: (_) {},
            onReport: (_) {},
          ),
        ),
      );

      await tester.pumpWidget(studio(chat: false));
      expect(find.text('CHAT'), findsNothing);

      await tester.pumpWidget(studio(chat: true));
      expect(find.text('CHAT'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('stats row', () {
    testWidgets('reports the show state a host asks about', (tester) async {
      await tester.pumpWidget(
        _wrap(
          NileStudio(
            sources: [_source('camera-1')],
            selectedIdentity: 'camera-1',
            onSelectSource: (_) {},
            selfIdentity: null,
            stats: const NileStudioStats(
              isLive: true,
              elapsed: Duration(minutes: 12, seconds: 34),
              remaining: Duration(minutes: 1, seconds: 30),
              viewerCount: 1204,
              readyCount: 3,
              crewCount: 4,
              cameraCount: 2,
              quality: NileStudioQuality.poor,
              audioSourceLabel: 'Stream Audio',
            ),
            controls: const SizedBox.shrink(),
            showChatColumn: false,
          ),
        ),
      );

      expect(find.text('LIVE'), findsOneWidget);
      expect(find.text('12:34'), findsOneWidget);
      expect(find.text('01:30 left'), findsOneWidget);
      expect(find.text('1204'), findsOneWidget);
      expect(find.text('3/4 ready'), findsOneWidget);
      expect(find.text('Stream Audio'), findsOneWidget);
      expect(find.text('Poor'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('sound check shows no clock and no viewer count', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          NileStudio(
            sources: [_source('camera-1')],
            selectedIdentity: 'camera-1',
            onSelectSource: (_) {},
            selfIdentity: null,
            stats: const NileStudioStats(isLive: false, viewerCount: 7),
            controls: const SizedBox.shrink(),
            showChatColumn: false,
          ),
        ),
      );
      expect(find.text('SOUND CHECK'), findsOneWidget);
      // Nobody is watching a sound check — showing a count would be a lie.
      expect(find.text('7'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the auto-end beat replaces the countdown', (tester) async {
      await tester.pumpWidget(
        _wrap(
          NileStudio(
            sources: [_source('camera-1')],
            selectedIdentity: 'camera-1',
            onSelectSource: (_) {},
            selfIdentity: null,
            stats: const NileStudioStats(
              isLive: true,
              remaining: Duration.zero,
              autoEnding: true,
            ),
            controls: const SizedBox.shrink(),
            showChatColumn: false,
          ),
        ),
      );
      expect(find.text('Ending stream…'), findsOneWidget);
      expect(find.text('00:00 left'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('moderation', () {
    Widget chatPanel({
      required List<ChatMessage> messages,
      Set<String> hidden = const {},
      Set<String> blocked = const {},
      String? selfId,
      void Function(ChatMessage)? onHide,
      VoidCallback? onShowAll,
    }) => _wrap(
      SizedBox(
        width: NileStudio.chatColumnWidth,
        child: NileStudioChat(
          messages: messages,
          hiddenSenders: hidden,
          blockedSenders: blocked,
          selfId: selfId,
          onHide: onHide ?? (_) {},
          onShowAll: onShowAll ?? () {},
          onBlock: (_) {},
          onReport: (_) {},
        ),
      ),
    );

    testWidgets('hidden and blocked senders both disappear', (tester) async {
      await tester.pumpWidget(
        chatPanel(
          messages: [
            _msg('u1', 'alice', 'hello'),
            _msg('u2', 'bob', 'spam'),
            _msg('u3', 'carol', 'abuse'),
          ],
          hidden: const {'u2'},
          blocked: const {'u3'},
        ),
      );
      expect(find.textContaining('hello'), findsOneWidget);
      expect(find.textContaining('spam'), findsNothing);
      expect(find.textContaining('abuse'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('"Show all" offers to undo hides, not blocks', (tester) async {
      // A block is a deliberate, persisted act — it is undone in Settings, not
      // by a convenience button in a broadcast tool.
      await tester.pumpWidget(
        chatPanel(messages: [_msg('u1', 'alice', 'hi')], blocked: const {'u9'}),
      );
      expect(find.textContaining('Show all'), findsNothing);

      var restored = false;
      await tester.pumpWidget(
        chatPanel(
          messages: [_msg('u1', 'alice', 'hi')],
          hidden: const {'u9'},
          onShowAll: () => restored = true,
        ),
      );
      expect(find.text('1 hidden · Show all'), findsOneWidget);
      await tester.tap(find.text('1 hidden · Show all'));
      expect(restored, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('system announcements survive every filter', (tester) async {
      final system = ChatMessage(
        senderId: '',
        username: '',
        content: 'Someone tipped \$5',
        sentAt: DateTime(2026, 8, 10),
        kind: 'system',
      );
      await tester.pumpWidget(
        chatPanel(
          messages: [system],
          hidden: const {''},
          blocked: const {''},
        ),
      );
      expect(find.text('Someone tipped \$5'), findsOneWidget);
      // …and there is nobody to moderate on an app-generated line.
      expect(find.byIcon(Icons.more_horiz), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a viewer message offers hide, block and report', (
      tester,
    ) async {
      ChatMessage? hidden;
      await tester.pumpWidget(
        chatPanel(
          messages: [_msg('u1', 'alice', 'hello')],
          onHide: (m) => hidden = m,
        ),
      );
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();

      expect(find.text('Hide @alice for this show'), findsOneWidget);
      expect(find.text('Block @alice'), findsOneWidget);
      expect(find.text('Report @alice'), findsOneWidget);

      await tester.tap(find.text('Hide @alice for this show'));
      await tester.pumpAndSettle();
      expect(hidden?.senderId, 'u1');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('you cannot moderate yourself', (tester) async {
      await tester.pumpWidget(
        chatPanel(
          messages: [_msg('me', 'host', 'welcome in')],
          selfId: 'me',
        ),
      );
      expect(find.textContaining('welcome in'), findsOneWidget);
      expect(find.byIcon(Icons.more_horiz), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
