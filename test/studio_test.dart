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
  bool isRemovable = false,
}) => NileStudioSource(
  identity: identity,
  label: label ?? identity,
  isLocal: isLocal,
  isScreenShare: isScreenShare,
  isRemovable: isRemovable,
);

/// [id] is `live_chat_messages.id`. Null models a line broadcast by a client
/// that predates #16 — it can still be banned by sender, but not removed on its
/// own, and the menu has to reflect that.
ChatMessage _msg(
  String senderId,
  String username,
  String content, {
  String? id,
}) => ChatMessage(
  id: id,
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
    // A failed replay egress used to be a toast at Start Show and nothing else,
    // on a server that reported success anyway. The chip has to be persistent:
    // there is no recovering the recording mid-show, and the host otherwise
    // finds out when they go to sell a replay that does not exist.
    testWidgets('a failed recording is stated, and only when it failed', (
      tester,
    ) async {
      Widget studio({required bool notRecording}) => _wrap(
        NileStudio(
          sources: [_source('camera-1')],
          selectedIdentity: 'camera-1',
          onSelectSource: (_) {},
          selfIdentity: null,
          stats: NileStudioStats(isLive: true, notRecording: notRecording),
          controls: const SizedBox.shrink(),
          showChatColumn: false,
        ),
      );

      await tester.pumpWidget(studio(notRecording: false));
      expect(find.text('NOT RECORDING'), findsNothing);

      await tester.pumpWidget(studio(notRecording: true));
      expect(find.text('NOT RECORDING'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

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

  group('removing a source', () {
    // Ejecting a crew feed is the host's only lever short of ending the show,
    // and it disconnects a real person mid-broadcast. Both halves of the guard
    // matter: an operator must never see the control, and the host must never
    // see it on a row where it would do nothing (their own feed, a screen
    // share, or a crew member who hasn't connected).
    Widget studio({
      required List<NileStudioSource> sources,
      ValueChanged<NileStudioSource>? onRemove,
    }) => _wrap(
      NileStudio(
        sources: sources,
        selectedIdentity: sources.first.identity,
        onSelectSource: (_) {},
        onRemoveSource: onRemove,
        selfIdentity: 'camera-me',
        stats: const NileStudioStats(isLive: true),
        controls: const SizedBox.shrink(),
        showChatColumn: false,
      ),
    );

    testWidgets('an operator gets no remove control at all', (tester) async {
      await tester.pumpWidget(
        studio(
          sources: [
            _source('camera-me', label: 'You', isLocal: true),
            _source('camera-2', label: 'Stage Right', isRemovable: true),
          ],
          onRemove: null, // camera_screen passes null unless isHost
        ),
      );
      expect(find.byIcon(Icons.more_horiz), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the host sees it only on removable sources', (tester) async {
      await tester.pumpWidget(
        studio(
          sources: [
            _source('camera-me', label: 'You', isLocal: true),
            _source('camera-2', label: 'Stage Right', isRemovable: true),
            _source('camera-2#share', label: 'Stage Right — screen',
                isScreenShare: true),
            _source('crew:abc', label: '@notyethere'),
          ],
          onRemove: (_) {},
        ),
      );
      expect(find.byIcon(Icons.more_horiz), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('choosing Remove hands back the source, not the label', (
      tester,
    ) async {
      NileStudioSource? removed;
      await tester.pumpWidget(
        studio(
          sources: [
            _source('camera-me', label: 'You', isLocal: true),
            _source('camera-2', label: 'Stage Right', isRemovable: true),
          ],
          onRemove: (s) => removed = s,
        ),
      );
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from stream'));
      await tester.pumpAndSettle();
      expect(removed?.identity, 'camera-2');
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
      void Function(ChatMessage)? onRemove,
      void Function(ChatMessage)? onBan,
      VoidCallback? onSettings,
      String? restrictionLabel,
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
          onRemove: onRemove,
          onBan: onBan,
          onSettings: onSettings,
          restrictionLabel: restrictionLabel,
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

    testWidgets('without moderator rights, only the for-me actions appear', (
      tester,
    ) async {
      // The labels carry the whole point of #16: before it, "Block" sat in this
      // menu reading like moderation while only ever changing one person's
      // view. Anything that changes just this host's screen now says "for me".
      ChatMessage? hidden;
      await tester.pumpWidget(
        chatPanel(
          messages: [_msg('u1', 'alice', 'hello', id: 'm1')],
          onHide: (m) => hidden = m,
        ),
      );
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();

      expect(find.text('Hide @alice for me'), findsOneWidget);
      expect(find.text('Block @alice for me'), findsOneWidget);
      expect(find.text('Report this message'), findsOneWidget);
      expect(find.text('Remove this message'), findsNothing);
      expect(find.text('Ban @alice from this show'), findsNothing);

      await tester.tap(find.text('Hide @alice for me'));
      await tester.pumpAndSettle();
      expect(hidden?.senderId, 'u1');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a moderator gets remove and ban, and ban hands back the '
        'message', (tester) async {
      ChatMessage? banned;
      await tester.pumpWidget(
        chatPanel(
          messages: [_msg('u1', 'alice', 'hello', id: 'm1')],
          onRemove: (_) {},
          onBan: (m) => banned = m,
        ),
      );
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();

      expect(find.text('Remove this message'), findsOneWidget);
      expect(find.text('Ban @alice from this show'), findsOneWidget);

      await tester.tap(find.text('Ban @alice from this show'));
      await tester.pumpAndSettle();
      expect(banned?.senderId, 'u1');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a message with no id offers ban but not remove', (
      tester,
    ) async {
      // Every device in the field on day one broadcasts straight to the channel
      // and sends no id, so there is nothing for the server to soft-delete.
      // Offering Remove there would be a menu item that quietly does nothing —
      // Ban still reaches those lines, because it clears by sender.
      await tester.pumpWidget(
        chatPanel(
          messages: [_msg('u1', 'alice', 'hello')],
          onRemove: (_) {},
          onBan: (_) {},
        ),
      );
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();

      expect(find.text('Remove this message'), findsNothing);
      expect(find.text('Ban @alice from this show'), findsOneWidget);
      // …and the report falls back to the account, which is all we can identify.
      expect(find.text('Report @alice'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('you cannot moderate yourself', (tester) async {
      await tester.pumpWidget(
        chatPanel(
          messages: [_msg('me', 'host', 'welcome in')],
          selfId: 'me',
          onRemove: (_) {},
          onBan: (_) {},
        ),
      );
      expect(find.textContaining('welcome in'), findsOneWidget);
      expect(find.byIcon(Icons.more_horiz), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('settings are the host\'s alone', (tester) async {
      await tester.pumpWidget(
        chatPanel(messages: [_msg('u1', 'alice', 'hi')]),
      );
      expect(find.byIcon(Icons.tune), findsNothing);

      var opened = false;
      await tester.pumpWidget(
        chatPanel(
          messages: [_msg('u1', 'alice', 'hi')],
          onSettings: () => opened = true,
        ),
      );
      await tester.tap(find.byIcon(Icons.tune));
      expect(opened, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a narrowed room says so in the header', (tester) async {
      // Slow mode and follower-only chat both look exactly like a quiet room.
      // A host who forgot they turned one on would otherwise read the silence
      // as chat being broken — which is the failure #15 spent a whole fix on.
      await tester.pumpWidget(
        chatPanel(messages: [_msg('u1', 'alice', 'hi')]),
      );
      expect(find.textContaining('Slow mode'), findsNothing);

      await tester.pumpWidget(
        chatPanel(
          messages: [_msg('u1', 'alice', 'hi')],
          restrictionLabel: 'Slow mode · 10s · Followers only',
        ),
      );
      expect(find.text('Slow mode · 10s · Followers only'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
