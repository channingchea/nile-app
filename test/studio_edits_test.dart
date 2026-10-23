// Studio edits (plan: docs/plans/studio-edits-graphics-chat-sources.md) — the
// rules behind graphics targeting and auto-hide, countdowns, show control, the
// camera status link, chat colours/links/filters, and the Studio chat column
// and source tiles. Server halves: supabase/functions/tests/studio_edits_test.ts.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nile_app/services/camera_status.dart';
import 'package:nile_app/services/chat_service.dart';
import 'package:nile_app/services/chat_tools_service.dart';
import 'package:nile_app/services/show_control.dart';
import 'package:nile_app/services/studio_graphics.dart';
import 'package:nile_app/theme.dart';
import 'package:nile_app/widgets/nile_link_text.dart';
import 'package:nile_app/widgets/nile_studio.dart';
import 'package:nile_app/widgets/studio_graphics_panel.dart';

const _lt = LiveGraphic(id: 'lt', kind: GraphicKind.lowerThird, title: 'Jane');
const _brb = LiveGraphic(id: 'brb', kind: GraphicKind.slate, title: 'BRB');

ChatMessage _msg(
  String id,
  String text, {
  String sender = 'u1',
  String? role,
  bool firstTime = false,
  bool filtered = false,
  String kind = 'user',
}) => ChatMessage(
  id: id,
  senderId: sender,
  username: 'user_$sender',
  content: text,
  sentAt: DateTime(2026),
  senderRole: role,
  firstTime: firstTime,
  filtered: filtered,
  kind: kind,
);

Widget _host(Widget child, {Size size = const Size(400, 700)}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(width: size.width, height: size.height, child: child),
    ),
  ),
);

NileStudioChat _chat(
  List<ChatMessage> messages, {
  Future<String?> Function(String)? onSend,
  PinnedMessage? pinned,
  VoidCallback? onUnpin,
  void Function(ChatMessage)? onRelease,
}) => NileStudioChat(
  messages: messages,
  hiddenSenders: const {},
  blockedSenders: const {},
  selfId: 'host',
  onHide: (_) {},
  onShowAll: () {},
  onBlock: (_) {},
  onReport: (_) {},
  onSend: onSend,
  pinned: pinned,
  onUnpin: onUnpin,
  onRelease: onRelease,
);

void main() {
  group('graphics targeting', () {
    test('all cameras except one, then off that one only', () {
      final s = GraphicsState.empty.withTargets(
        _lt,
        const GraphicTargets.all(except: {'s2'}),
      );
      expect(s.forSlot('s1').single.id, 'lt');
      expect(s.forSlot('s2'), isEmpty);
      expect(s.targetsOf('lt'), const GraphicTargets.all(except: {'s2'}));

      final off3 = s.withoutOnSlot('lt', 's3');
      expect(
        off3.targetsOf('lt'),
        const GraphicTargets.all(except: {'s2', 's3'}),
      );
      expect(off3.forSlot('s1').single.id, 'lt');
    });

    test('only some cameras; moving targets replaces the old ones', () {
      var s = GraphicsState.empty.withTargets(
        _lt,
        const GraphicTargets.only({'s1', 's3'}),
      );
      expect(s.targetsOf('lt'), const GraphicTargets.only({'s1', 's3'}));
      expect(s.all, isEmpty);
      s = s.withTargets(_lt, const GraphicTargets.all());
      expect(s.bySlot, isEmpty);
      expect(s.targetsOf('lt').all, isTrue);
      expect(s.withoutEverywhere('lt').isEmpty, isTrue);
    });

    test('summaries read like the panel', () {
      String label(String id) =>
          {'s1': 'Cam 1', 's2': 'Cam 2', 's3': 'Cam 3'}[id]!;
      const order = ['s1', 's2', 's3'];
      expect(GraphicTargets.none.summary(label, order), 'Off');
      expect(const GraphicTargets.all().summary(label, order), 'All cameras');
      expect(
        const GraphicTargets.all(except: {'s2'}).summary(label, order),
        'All but Cam 2',
      );
      expect(
        const GraphicTargets.only({'s3', 's1'}).summary(label, order),
        'Cam 1, Cam 3',
      );
    });

    test('hotkey toggles on last targets, then off everywhere', () {
      var s = GraphicsState.empty.toggled(
        _brb,
        const GraphicTargets.only({'s2'}),
      );
      expect(s.targetsOf('brb'), const GraphicTargets.only({'s2'}));
      s = s.toggled(_brb, const GraphicTargets.only({'s2'}));
      expect(s.isEmpty, isTrue);
    });

    test('graphicsAfterHotkey: a key past the library does nothing', () {
      const lib = [
        StudioGraphic(
          id: 'g1',
          kind: GraphicKind.lowerThird,
          name: 'One',
          payload: {'title': 'One'},
        ),
      ];
      final now = DateTime(2026, 1, 1, 12);
      final on = graphicsAfterHotkey(
        digit: 1,
        library: lib,
        current: GraphicsState.empty,
        lastTargets: const {},
        now: now,
      );
      expect(on!.targetsOf('g1').all, isTrue);
      expect(
        graphicsAfterHotkey(
          digit: 2,
          library: lib,
          current: GraphicsState.empty,
          lastTargets: const {},
          now: now,
        ),
        isNull,
      );
    });
  });

  group('auto-hide', () {
    test('snapshot stamps hideAt from the saved default or the override', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1000000);
      const g = StudioGraphic(
        id: 'g',
        kind: GraphicKind.lowerThird,
        name: 'g',
        payload: {'title': 'Hi', 'autoHideSeconds': 8},
      );
      String url(String p) => p;
      expect(LiveGraphic.snapshot(g, publicUrl: url, now: now).hideAt, 1008000);
      expect(
        LiveGraphic.snapshot(
          g,
          publicUrl: url,
          now: now,
          autoHideSeconds: 0,
        ).hideAt,
        isNull,
      );
      expect(
        LiveGraphic.snapshot(
          g,
          publicUrl: url,
          now: now,
          autoHideSeconds: 30,
        ).hideAt,
        1030000,
      );
    });

    test('expired graphics leave forSlot at once; the Studio tidies them', () {
      final s = GraphicsState(
        all: [_lt.copyWith(hideAt: 500), _brb.copyWith(hideAt: 2000)],
      );
      expect(s.forSlot(null, nowMs: 1000).map((g) => g.id), ['brb']);
      expect(s.nextHideAt, 500);
      expect(s.withoutExpired(1000).all.map((g) => g.id), ['brb']);
    });

    test('json round trip keeps except, hideAt and chat cards', () {
      final chat = LiveGraphic.chatMessage(
        messageId: 'm1',
        username: 'maya',
        message: 'Hello!',
        now: DateTime.fromMillisecondsSinceEpoch(0),
      );
      final s = GraphicsState(
        all: [
          _lt.copyWith(except: ['s1']),
          chat,
        ],
      );
      expect(GraphicsState.fromJson(s.toJson()), s);
      expect(chat.hideAt, 10000);
      expect(chat.capKey, 'chat');
    });

    test('a chat message is capped for the screen', () {
      final g = LiveGraphic.chatMessage(
        messageId: 'm',
        username: 'x' * 60,
        message: 'y' * 300,
        now: DateTime(2026),
      );
      expect(g.title!.length, 40);
      expect(g.text!.length, 200);
    });
  });

  group('countdowns', () {
    final now = DateTime(2026, 10, 23, 18, 30);

    test('duration, legacy seconds, and validation', () {
      expect(
        countdownEnd({
          'countdown': {'mode': 'duration', 'seconds': 60},
        }, now: now),
        (now.add(const Duration(minutes: 1)).millisecondsSinceEpoch, false),
      );
      expect(
        countdownEnd({'countdownSeconds': 60}, now: now)!.$1,
        now.add(const Duration(minutes: 1)).millisecondsSinceEpoch,
      );
      expect(countdownError({'mode': 'duration', 'seconds': 0}), isNotNull);
      expect(countdownError({'mode': 'clock', 'at': '25:00'}), isNotNull);
      expect(countdownError({'mode': 'showStart'}), isNull);
    });

    test('a clock time is the next time the clock shows it', () {
      final later = countdownEnd({
        'countdown': {'mode': 'clock', 'at': '19:00'},
      }, now: now)!;
      expect(later.$1, DateTime(2026, 10, 23, 19).millisecondsSinceEpoch);
      expect(later.$2, isTrue);
      final tomorrow = countdownEnd({
        'countdown': {'mode': 'clock', 'at': '08:00'},
      }, now: now)!;
      expect(tomorrow.$1, DateTime(2026, 10, 24, 8).millisecondsSinceEpoch);
    });

    test('show start uses the schedule, or no countdown without one', () {
      final start = DateTime(2026, 10, 23, 20);
      expect(
        countdownEnd(
          {
            'countdown': {'mode': 'showStart'},
          },
          now: now,
          showStartAt: start,
        ),
        (start.millisecondsSinceEpoch, true),
      );
      expect(
        countdownEnd({
          'countdown': {'mode': 'showStart'},
        }, now: now),
        isNull,
      );
    });

    test('the library check accepts the new countdown and auto-hide', () {
      expect(
        StudioGraphic.validate(GraphicKind.slate, {
          'title': 'In',
          'countdown': {'mode': 'clock', 'at': '20:30'},
          'autoHideSeconds': 30,
        }),
        isNull,
      );
      expect(
        StudioGraphic.validate(GraphicKind.lowerThird, {
          'title': 'Jane',
          'autoHideSeconds': 0,
        }),
        isNotNull,
      );
    });
  });

  group('show control', () {
    const meta =
        '{"offAir":["s2"],"defaultSlot":"s3","sendAll":{"slot":"s1","nonce":7},'
        '"slotOrder":["s3","s1","s2"],"graphics":{"all":[]}}';
    final show = ShowControl.fromRoomMetadata(meta);

    test('parses the room metadata', () {
      expect(show.offAir, {'s2'});
      expect(show.defaultSlot, 's3');
      expect(show.sendAll, (slot: 's1', nonce: 7));
      expect(show.isOnAir('s2'), isFalse);
      expect(ShowControl.fromRoomMetadata('not json'), ShowControl.empty);
    });

    test('order follows slotOrder; unknown slots keep their place after', () {
      expect(show.ordered(['s1', 's2', 'x', 's3'], (s) => s), [
        's3',
        's1',
        's2',
        'x',
      ]);
    });

    test('new viewers start on the default angle, else the first on air', () {
      expect(show.startSlot(['s1', 's2', 's3']), 's3');
      expect(show.startSlot(['s1', 's2']), 's1');
      expect(const ShowControl(offAir: {'s1'}).startSlot(['s1', 's2']), 's2');
    });

    test('off air moves the viewer; sendAll moves them once', () {
      const s = ShowControl(offAir: {'s2'}, defaultSlot: 's3');
      expect(
        s.viewerMove(
          watching: 's2',
          available: ['s1', 's2', 's3'],
          seenNonce: null,
        ),
        (slot: 's3', reason: ViewerMoveReason.offAir),
      );
      expect(
        show.viewerMove(watching: 's3', available: ['s1', 's3'], seenNonce: null),
        (slot: 's1', reason: ViewerMoveReason.sendAll),
      );
      expect(
        show.viewerMove(watching: 's3', available: ['s1', 's3'], seenNonce: 7),
        isNull,
      );
      expect(
        show.viewerMove(watching: 's1', available: ['s1', 's3'], seenNonce: null),
        isNull,
      );
    });
  });

  group('camera status link', () {
    test('status messages round trip', () {
      const h = CameraHealth(
        battery: 12,
        thermal: ThermalLevel.serious,
        height: 1080,
        fps: 30,
        caps: CameraCaps(torch: true, zoom: true),
        torchOn: true,
        zoom: 2,
      );
      final back =
          StatusMessage.decode(const HealthMessage(h).encode()) as HealthMessage;
      expect(back.health.battery, 12);
      expect(back.health.thermal, ThermalLevel.serious);
      expect(back.health.caps.torch, isTrue);
      expect(back.health.caps.focusLock, isFalse);
      expect(back.health.zoom, 2);
      expect(back.health.resolutionLabel, '1080p · 30 fps');
      expect(
        (StatusMessage.decode(const LevelMessage(1.7).encode()) as LevelMessage)
            .level,
        1,
      );
      expect(
        (StatusMessage.decode(const AckMessage('n1').encode()) as AckMessage)
            .id,
        'n1',
      );
      expect(StatusMessage.decode([1, 2, 3]), isNull);
    });

    test('commands round trip and tell the operator what happened', () {
      final nudge = StudioCommand.decode(
        NudgeCommand('n', '  Go   wide ${'!' * 100}').encode(),
      );
      expect(nudge, isA<NudgeCommand>());
      expect((nudge as NudgeCommand).text.length, NudgePresets.maxLength);
      expect(nudge.text, startsWith('Go wide !'));
      expect(
        StudioCommand.decode(const TorchCommand(true).encode())!.operatorNotice,
        'Studio turned on your flashlight',
      );
      expect(
        (StudioCommand.decode(const ZoomCommand(2).encode()) as ZoomCommand)
            .zoom,
        2,
      );
      expect(
        StudioCommand.decode(
          const LockCommand(focus: true, exposure: false).encode(),
        )!.operatorNotice,
        'Studio locked your focus',
      );
      expect(
        StudioCommand.decode(const FlipCommand().encode()),
        isA<FlipCommand>(),
      );
      expect(StudioCommand.decode('{"t":"selfdestruct"}'.codeUnits), isNull);
    });

    test('alerts fire once and re-arm when cleared', () {
      final a = CameraAlerts();
      final t0 = DateTime(2026);
      const low = CameraHealth(battery: 10);
      expect(a.update('c1', health: low, poorSignal: false, now: t0), [
        CameraAlertKind.battery,
      ]);
      expect(a.update('c1', health: low, poorSignal: false, now: t0), isEmpty);
      // Charging clears it…
      expect(
        a.update(
          'c1',
          health: const CameraHealth(battery: 10, charging: true),
          poorSignal: false,
          now: t0,
        ),
        isEmpty,
      );
      // …so unplugging again fires again.
      expect(a.update('c1', health: low, poorSignal: false, now: t0), [
        CameraAlertKind.battery,
      ]);
      // Poor signal only after 10 s.
      expect(a.update('c2', poorSignal: true, now: t0), isEmpty);
      expect(
        a.update(
          'c2',
          poorSignal: true,
          now: t0.add(const Duration(seconds: 11)),
        ),
        [CameraAlertKind.signal],
      );
      expect(
        a.update(
          'c2',
          health: const CameraHealth(thermal: ThermalLevel.critical),
          poorSignal: true,
          now: t0.add(const Duration(seconds: 12)),
        ),
        [CameraAlertKind.heat],
      );
    });
  });

  group('chat', () {
    test('server fields parse; only host and crew may link', () {
      final m = ChatMessage.fromJson({
        'id': 'a',
        'sender_id': 'u',
        'username': 'x',
        'content': 'Any merch?',
        'sender_role': 'crew',
        'first_time': true,
      });
      expect(m.mayLink, isTrue);
      expect(m.isHost, isFalse);
      expect(m.firstTime, isTrue);
      expect(m.isQuestion, isTrue);
      expect(ChatMessage.fromJson({'sender_role': 'admin'}).senderRole, isNull);
      expect(ChatMessage.fromJson(m.toJson()).senderRole, 'crew');
    });

    test('filters', () {
      expect(ChatFilter.questions.matches(_msg('1', 'why?')), isTrue);
      expect(ChatFilter.questions.matches(_msg('1', 'yes')), isFalse);
      expect(
        ChatFilter.tips.matches(_msg('1', 'tipped', kind: 'system')),
        isTrue,
      );
      expect(
        ChatFilter.firstTime.matches(_msg('1', 'hi', firstTime: true)),
        isTrue,
      );
    });

    test('name colours are stable per person; the host is coral', () {
      expect(nileChatNameColor('abc'), nileChatNameColor('abc'));
      expect(NileColors.chatNames, contains(nileChatNameColor('abc')));
      expect(nileChatNameColor('abc', isHost: true), NileColors.coral);
    });

    test('pinned snapshots parse', () {
      expect(PinnedMessage.fromJson(null), isNull);
      final p = PinnedMessage.fromJson({
        'messageId': 'm',
        'senderId': 'u',
        'username': 'x',
        'body': 'Merch at nile.tv/shop',
        'pinnedAt': '2026-10-23T10:00:00Z',
        'senderRole': 'host',
      })!;
      expect(p.mayLink, isTrue);
    });

    test('blocked terms are normalised like the server matches them', () {
      expect(ChatToolsService.cleanTerm('  Bad   Word '), 'bad word');
      expect(ChatToolsService.cleanTerm('   '), isNull);
      expect(ChatToolsService.cleanTerm('x' * 61), isNull);
    });

    test('links: urls and bare domains, not emails or numbers', () {
      List<String> links(String s) => [
        for (final (a, b, _) in NileLinkText.findLinks(s)) s.substring(a, b),
      ];
      expect(links('Merch: https://nile.tv/shop.'), ['https://nile.tv/shop']);
      expect(links('see nile.tv/x, ok?'), ['nile.tv/x']);
      expect(links('mail me@nile.tv or call 3.14'), isEmpty);
      expect(links('javascript:alert(1)'), isEmpty);
    });
  });

  group('Studio chat column', () {
    testWidgets('host composer sends, and shows a refusal inline', (t) async {
      final sent = <String>[];
      await t.pumpWidget(
        _host(
          _chat(
            const [],
            onSend: (text) async {
              sent.add(text);
              return sent.length > 1 ? 'Slow down' : null;
            },
          ),
        ),
      );
      await t.enterText(find.byType(TextField), 'Welcome!');
      await t.testTextInput.receiveAction(TextInputAction.send);
      await t.pumpAndSettle();
      expect(sent, ['Welcome!']);
      expect(find.text('Welcome!'), findsNothing); // field cleared
      await t.enterText(find.byType(TextField), 'Again');
      await t.tap(find.byTooltip('Send'));
      await t.pumpAndSettle();
      expect(find.text('Slow down'), findsOneWidget);
    });

    testWidgets('pinned bar, a held-back line, and filters', (t) async {
      var unpinned = false;
      ChatMessage? released;
      final msgs = [
        _msg('3', 'blocked thing', sender: 'u3', filtered: true),
        _msg('2', 'When does it start?', sender: 'u2', firstTime: true),
        _msg('1', 'Hello there', sender: 'u1'),
      ];
      await t.pumpWidget(
        _host(
          _chat(
            msgs,
            pinned: PinnedMessage(
              messageId: 'p',
              senderId: 'host',
              username: 'host',
              body: 'Merch tonight',
              pinnedAt: DateTime(2026),
              senderRole: 'host',
            ),
            onUnpin: () => unpinned = true,
            onRelease: (m) => released = m,
          ),
        ),
      );
      expect(find.textContaining('Merch tonight'), findsOneWidget);
      await t.tap(find.text('Unpin'));
      expect(unpinned, isTrue);

      expect(find.text('Hidden by your blocked words'), findsOneWidget);
      await t.tap(find.text('Show anyway'));
      expect(released?.id, '3');

      await t.tap(find.text('Questions'));
      await t.pumpAndSettle();
      expect(find.textContaining('When does it start?'), findsOneWidget);
      expect(find.textContaining('Hello there'), findsNothing);
    });

    testWidgets('rows are compact: the options button is 20 pt', (t) async {
      await t.pumpWidget(_host(_chat([_msg('1', 'Hi')])));
      final popup = find.byWidgetPredicate((w) => w is PopupMenuButton);
      expect(t.getSize(popup), const Size(20, 20));
    });
  });

  group('source tiles', () {
    NileStudio studio(
      List<NileStudioSource> sources, {
      NileStudioSourceActions actions = const NileStudioSourceActions(),
    }) => NileStudio(
      sources: sources,
      selectedIdentity: null,
      onSelectSource: (_) {},
      selfIdentity: null,
      stats: const NileStudioStats(isLive: true),
      controls: const SizedBox(),
      showChatColumn: false,
      sourceActions: actions,
      graphicsFor: (s) => const GraphicsState(all: [_lt]).forSlot(s.slotId),
    );

    testWidgets('off air, default, viewers, health and a graphic chip', (
      t,
    ) async {
      LiveGraphic? removed;
      bool? all;
      await t.pumpWidget(
        _host(
          studio(
            const [
              NileStudioSource(
                identity: 'camera-a',
                label: 'Camera 2',
                slotId: 's2',
                isOffAir: true,
                isDefaultAngle: true,
                viewers: 14,
                level: 0.4,
                health: CameraHealth(battery: 9),
              ),
            ],
            actions: NileStudioSourceActions(
              onRemoveGraphic: (s, g, {required everywhere}) {
                removed = g;
                all = everywhere;
              },
            ),
          ),
          size: const Size(1200, 800),
        ),
      );
      expect(find.text('OFF AIR'), findsOneWidget);
      expect(find.byIcon(Icons.star), findsOneWidget);
      expect(find.text('14'), findsOneWidget);
      expect(find.byIcon(Icons.battery_alert), findsOneWidget);

      await t.tap(find.byTooltip('Jane'));
      await t.pumpAndSettle();
      await t.tap(find.text('Remove from this camera'));
      await t.pumpAndSettle();
      expect(removed?.id, 'lt');
      expect(all, isFalse);
    });

    testWidgets('the tile menu offers only what applies', (t) async {
      final sent = <String>[];
      await t.pumpWidget(
        _host(
          studio(
            const [
              NileStudioSource(
                identity: 'camera-a',
                label: 'Camera 1',
                slotId: 's1',
              ),
              NileStudioSource(
                identity: 'slot:s2',
                label: 'Camera 2',
                slotId: 's2',
              ),
            ],
            actions: NileStudioSourceActions(
              onToggleOffAir: (s) => sent.add('off:${s.slotId}'),
              onSetDefault: (s) => sent.add('default:${s.slotId}'),
              onSendEveryone: (s) => sent.add('send:${s.slotId}'),
              onMakeMasterAudio: (s) => sent.add('master:${s.identity}'),
              onNudge: (s, text) => sent.add('nudge:$text'),
            ),
          ),
          size: const Size(1200, 900),
        ),
      );
      // The connected camera: everything.
      await t.tap(find.byTooltip('Source options').first);
      await t.pumpAndSettle();
      expect(find.text('Make master audio'), findsOneWidget);
      expect(find.text('Nudge operator…'), findsOneWidget);
      await t.tap(find.text('Take off air'));
      await t.pumpAndSettle();
      // The open slot: show controls, but no operator to nudge and no audio.
      await t.tap(find.byTooltip('Source options').last);
      await t.pumpAndSettle();
      expect(find.text('Make master audio'), findsNothing);
      expect(find.text('Nudge operator…'), findsNothing);
      await t.tap(find.text('Set as default angle'));
      await t.pumpAndSettle();
      expect(sent, ['off:s1', 'default:s2']);
    });
  });
}
