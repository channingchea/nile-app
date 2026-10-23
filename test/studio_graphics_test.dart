// Studio master host, phases 4-6: the graphics library rules, what a viewer
// of each camera sees, and the on-screen layer. Server-side validation and the
// resync rate limit are in supabase/functions/tests/studio_test.ts.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nile_app/services/studio_graphics.dart';
import 'package:nile_app/widgets/nile_graphics_layer.dart';
import 'package:nile_app/widgets/studio_graphics_panel.dart';

LiveGraphic _g(String id, GraphicKind kind, {String? corner, String? title}) =>
    LiveGraphic(id: id, kind: kind, corner: corner, title: title ?? id);

void main() {
  group('library payloads (mirror of the DB check)', () {
    test('lower third needs a title', () {
      expect(StudioGraphic.validate(GraphicKind.lowerThird, {'title': 'Jane'}), isNull);
      expect(StudioGraphic.validate(GraphicKind.lowerThird, {'title': '  '}), isNotNull);
      expect(
        StudioGraphic.validate(GraphicKind.lowerThird, {
          'title': 'Jane',
          'subtitle': 'x' * 81,
        }),
        isNotNull,
      );
    });

    test('logo needs an image and a real corner', () {
      expect(
        StudioGraphic.validate(GraphicKind.logo, {'imagePath': 'u/a.png', 'corner': 'tr'}),
        isNull,
      );
      expect(StudioGraphic.validate(GraphicKind.logo, {'corner': 'tr'}), isNotNull);
      expect(
        StudioGraphic.validate(GraphicKind.logo, {'imagePath': 'u/a.png', 'corner': 'mid'}),
        isNotNull,
      );
    });

    test('banner says whether it scrolls', () {
      expect(
        StudioGraphic.validate(GraphicKind.banner, {'text': 'Hi', 'scrolling': true}),
        isNull,
      );
      expect(StudioGraphic.validate(GraphicKind.banner, {'text': 'Hi'}), isNotNull);
    });

    test('slate countdown is bounded', () {
      expect(
        StudioGraphic.validate(GraphicKind.slate, {'title': 'Soon', 'countdownSeconds': 300}),
        isNull,
      );
      expect(
        StudioGraphic.validate(GraphicKind.slate, {'title': 'Soon', 'countdownSeconds': 0}),
        isNotNull,
      );
    });

    test('every preset is valid', () {
      for (final p in StudioGraphicPresets.all) {
        expect(StudioGraphic.validate(p.kind, p.payload), isNull, reason: p.name);
        expect(p.isPreset, isTrue);
      }
    });
  });

  group('snapshots', () {
    test('a pushed graphic carries a URL and a countdown end, not a path', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1000000);
      final live = LiveGraphic.snapshot(
        const StudioGraphic(
          id: 'g1',
          kind: GraphicKind.slate,
          name: 'Soon',
          payload: {'title': 'Soon', 'imagePath': 'u/bg.png', 'countdownSeconds': 60},
        ),
        publicUrl: (p) => 'https://cdn/$p',
        now: now,
      );
      expect(live.imageUrl, 'https://cdn/u/bg.png');
      expect(live.endsAt, 1000000 + 60000);
      expect(live.toJson().containsKey('imagePath'), isFalse);
      expect(LiveGraphic.fromJson(jsonDecode(jsonEncode(live.toJson()))), live);
    });
  });

  group('what a viewer of each camera sees', () {
    final lowerAll = _g('lt-all', GraphicKind.lowerThird);
    final lowerCam1 = _g('lt-cam1', GraphicKind.lowerThird);
    final logoTl = _g('logo-tl', GraphicKind.logo, corner: 'tl');
    final logoTr = _g('logo-tr', GraphicKind.logo, corner: 'tr');
    final state = GraphicsState(
      all: [lowerAll, logoTl],
      bySlot: {
        's1': [lowerCam1, logoTr],
      },
    );

    test('a camera-specific graphic replaces the show-wide one of its kind', () {
      expect(state.forSlot('s1').map((g) => g.id), unorderedEquals(['logo-tl', 'lt-cam1', 'logo-tr']));
    });

    test('other cameras and screen shares see only the show-wide ones', () {
      expect(state.forSlot('s2').map((g) => g.id), ['lt-all', 'logo-tl']);
      expect(state.forSlot(null).map((g) => g.id), ['lt-all', 'logo-tl']);
    });

    test('turning one on replaces what held its place on that target', () {
      final next = state.withOn(null, _g('lt-new', GraphicKind.lowerThird));
      expect(next.all.map((g) => g.id), ['logo-tl', 'lt-new']);
      final logos = state.withOn(null, _g('logo-br', GraphicKind.logo, corner: 'br'));
      expect(logos.all.length, 3, reason: 'different corners coexist');
    });

    test('off and clear touch only their target', () {
      expect(state.withOff('s1', 'lt-cam1').bySlot['s1']!.map((g) => g.id), ['logo-tr']);
      final cleared = state.cleared('s1');
      expect(cleared.bySlot.containsKey('s1'), isFalse);
      expect(cleared.all, state.all);
      expect(state.cleared(null).all, isEmpty);
      expect(state.isOn('s1', 'logo-tr'), isTrue);
      expect(state.isOn(null, 'logo-tr'), isFalse);
    });

    test('read from room metadata next to everything else, junk tolerated', () {
      final raw = jsonEncode({
        'eventName': 'Show',
        'showStartedAt': 123,
        'graphics': state.toJson(),
      });
      expect(GraphicsState.fromRoomMetadata(raw), state);
      expect(GraphicsState.fromRoomMetadata(null).isEmpty, isTrue);
      expect(GraphicsState.fromRoomMetadata('nope').isEmpty, isTrue);
      expect(
        GraphicsState.fromRoomMetadata(
          jsonEncode({
            'graphics': {
              'all': [
                {'kind': 'slate'},
                {'id': 'x', 'kind': 'mystery'},
                'str',
              ],
            },
          }),
        ).isEmpty,
        isTrue,
      );
    });
  });

  group('on-screen layer', () {
    Widget frame(List<LiveGraphic> g) => MaterialApp(
      home: Center(
        child: SizedBox(
          width: 640,
          height: 360,
          child: NileGraphicsLayer(graphics: g),
        ),
      ),
    );

    testWidgets('draws a lower third and a banner', (t) async {
      await t.pumpWidget(
        frame([
          const LiveGraphic(
            id: 'a',
            kind: GraphicKind.lowerThird,
            title: 'Jane Doe',
            subtitle: 'Host',
          ),
          const LiveGraphic(id: 'b', kind: GraphicKind.banner, text: 'Tickets at joinnile.com'),
        ]),
      );
      await t.pumpAndSettle();
      expect(find.text('Jane Doe'), findsOneWidget);
      expect(find.text('Host'), findsOneWidget);
      expect(find.text('Tickets at joinnile.com'), findsOneWidget);
    });

    testWidgets('a countdown slate counts down', (t) async {
      final end = DateTime.now().add(const Duration(minutes: 2, seconds: 5));
      await t.pumpWidget(
        frame([
          LiveGraphic(
            id: 's',
            kind: GraphicKind.slate,
            title: 'Starting in',
            endsAt: end.millisecondsSinceEpoch,
          ),
        ]),
      );
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Starting in'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^2:0[0-5]$')), findsOneWidget);
      await t.pumpWidget(frame(const []));
      await t.pumpAndSettle();
    });

    testWidgets('nothing on air draws nothing', (t) async {
      await t.pumpWidget(frame(const []));
      expect(find.byType(Text), findsNothing);
    });
  });

  group('Graphics panel', () {
    const slots = <StudioSlotRef>[
      (id: 's1', label: 'Camera 1'),
      (id: 's2', label: 'Camera 2'),
    ];

    Widget opener(
      GraphicsState current,
      Future<bool> Function(GraphicsState) push, {
      bool isLive = false,
      void Function(String, GraphicTargets)? used,
    }) => MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showGraphicsPushPanel(
            context,
            current: current,
            slots: slots,
            push: push,
            isLive: isLive,
            onTargetsUsed: used,
          ),
          child: const Text('open'),
        ),
      ),
    );

    Future<void> openCameras(WidgetTester t, String name) async {
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      final row = find.widgetWithText(ListTile, name);
      await t.tap(find.descendant(of: row, matching: find.byType(OutlinedButton)));
      await t.pumpAndSettle();
    }

    testWidgets('Cameras: all but one camera, then that camera alone', (t) async {
      final pushed = <GraphicsState>[];
      final used = <String, GraphicTargets>{};
      await t.pumpWidget(
        opener(GraphicsState.empty, (next) async {
          pushed.add(next);
          return true;
        }, used: (id, tg) => used[id] = tg),
      );
      await openCameras(t, 'Be right back');
      // All cameras is the starting point; untick Camera 2.
      await t.tap(find.widgetWithText(CheckboxListTile, 'Camera 2'));
      await t.pump();
      await t.tap(find.text('Put on air'));
      await t.pumpAndSettle();
      final brb = pushed.single.all.single;
      expect(brb.id, 'preset:brb');
      expect(brb.except, ['s2']);
      expect(used['preset:brb'], const GraphicTargets.all(except: {'s2'}));
      expect(find.text('All but Camera 2'), findsOneWidget);
      expect(pushed.single.forSlot('s2'), isEmpty);
      expect(pushed.single.forSlot('s1').single.id, 'preset:brb');
    });

    testWidgets('Remove from all, and Clear all confirms when live', (t) async {
      final pushed = <GraphicsState>[];
      final start = GraphicsState.empty.withTargets(
        const LiveGraphic(id: 'preset:brb', kind: GraphicKind.slate, title: 'Be right back'),
        const GraphicTargets.only({'s1'}),
      );
      await t.pumpWidget(
        opener(start, (next) async {
          pushed.add(next);
          return true;
        }, isLive: true),
      );
      await openCameras(t, 'Be right back');
      await t.tap(find.text('Remove from all'));
      await t.pumpAndSettle();
      expect(pushed.last.isEmpty, isTrue);

      // Put it back, then Clear all asks first.
      await t.tap(find.descendant(
        of: find.widgetWithText(ListTile, 'Thank you'),
        matching: find.byType(OutlinedButton),
      ));
      await t.pumpAndSettle();
      await t.tap(find.text('Put on air'));
      await t.pumpAndSettle();
      expect(pushed.last.all.single.id, 'preset:thanks');
      await t.tap(find.text('Clear all'));
      await t.pumpAndSettle();
      expect(find.text('Clear every graphic?'), findsOneWidget);
      await t.tap(find.text('Clear all').last);
      await t.pumpAndSettle();
      expect(pushed.last.isEmpty, isTrue);
    });

    testWidgets('a refused push leaves it off and says so', (t) async {
      await t.pumpWidget(opener(GraphicsState.empty, (_) async => false));
      await openCameras(t, 'Be right back');
      await t.tap(find.text('Put on air'));
      await t.pumpAndSettle();
      expect(find.text('Couldn’t update the show’s graphics. Try again.'), findsOneWidget);
      expect(find.text('Off'), findsWidgets);
    });
  });
}
