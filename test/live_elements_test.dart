// Studio live elements (docs/plans/studio-live-elements-foundation.md),
// phases 1-3: the element model and clocks, placement on the 3×3 grid, the
// overlay hold-back, the Studio's element controller, and the Elements panel.
// Server-side rules are in supabase/functions/tests/live_elements_test.ts.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nile_app/services/brand_kit.dart';
import 'package:nile_app/services/live_elements.dart';
import 'package:nile_app/services/livekit_service.dart' show ElementStale;
import 'package:nile_app/services/overlay_layout.dart';
import 'package:nile_app/services/server_clock.dart';
import 'package:nile_app/services/studio_elements_controller.dart';
import 'package:nile_app/services/studio_graphics.dart';
import 'package:nile_app/widgets/nile_graphics_layer.dart';
import 'package:nile_app/widgets/studio_elements_panel.dart';
import 'package:nile_app/widgets/studio_graphics_panel.dart' show StudioSlotRef;
import 'package:nile_app/widgets/studio_layout_sheet.dart';

const _counter = StudioElement(
  id: 'el-1',
  kind: 'counter',
  name: 'Goals',
  config: {'label': 'Goals', 'step': 1},
);

LiveElement _live({
  GraphicTargets targets = const GraphicTargets.all(),
  int value = 0,
  Map<String, ElementClock> clocks = const {},
}) => LiveElement(
  id: 'el-1',
  kind: 'counter',
  name: 'Goals',
  config: const {'label': 'Goals', 'step': 1},
  state: {'value': value},
  clocks: clocks,
  targets: targets,
  version: 1,
);

const _lt = LiveGraphic(id: 'lt', kind: GraphicKind.lowerThird, title: 'Jane');
const _logo = LiveGraphic(
  id: 'logo',
  kind: GraphicKind.logo,
  corner: 'tr',
  imageUrl: 'https://x/a.png',
);
const _slate = LiveGraphic(id: 'slate', kind: GraphicKind.slate, title: 'BRB');

void main() {
  setUp(() => ServerClock.debugSetOffset(0));

  group('clocks (mirror of applyClockOp on the server)', () {
    test('start, pause, resume, set and reset', () {
      var c = const ElementClock().apply(ClockOp.start, 1000);
      expect(c.running, isTrue);
      expect(c.valueAt(4000), 3000);
      expect(c.apply(ClockOp.start, 2000), c);
      c = c.apply(ClockOp.pause, 5000);
      expect(c, const ElementClock(elapsedMs: 4000, pausedAt: 5000));
      expect(c.valueAt(99000), 4000);
      c = c.apply(ClockOp.start, 10000);
      expect(c.valueAt(11000), 5000);
      expect(
        c.apply(const ClockOp(ClockOpKind.set, 60000), 12000),
        const ElementClock(elapsedMs: 60000, runningSince: 12000),
      );
      expect(c.apply(ClockOp.reset, 12000), const ElementClock());
    });

    test('reads like a scoreboard clock', () {
      expect(formatClock(65000), '1:05');
      expect(formatClock(3723000), '1:02:03');
      expect(formatClock(-5), '0:00');
    });
  });

  group('live element model', () {
    test('round-trips, with clocks kept apart from the values', () {
      final e = _live(
        value: 3,
        clocks: {'main': const ElementClock(elapsedMs: 5, runningSince: 9)},
      );
      final back = LiveElement.fromJson({...e.toJson(), 'at': 77})!;
      expect(back.state, {'value': 3});
      expect(back.clock('main').runningSince, 9);
      expect(back.at, 77);
      expect(back.targets, const GraphicTargets.all());
      expect(e.toJson()['state'], {
        'value': 3,
        'clocks': {
          'main': {'elapsedMs': 5, 'runningSince': 9},
        },
      });
    });

    test('a kind this build does not know is dropped', () {
      expect(
        LiveElement.fromJson({'id': 'x', 'kind': 'hologram', 'name': 'X'}),
        isNull,
      );
      final s = ElementsState.fromJson({
        'items': [
          {'id': 'x', 'kind': 'hologram'},
          _live().toJson(),
        ],
        'at': 5,
      });
      expect(s.items.map((e) => e.id), ['el-1']);
      expect(s.at, 5);
    });

    test('follows the camera a viewer picks', () {
      final s = ElementsState(
        items: [
          _live(targets: const GraphicTargets.all(except: {'s2'})),
          LiveElement(
            id: 'el-2',
            kind: 'counter',
            name: 'B',
            targets: const GraphicTargets.only({'s2'}),
          ),
        ],
      );
      expect(s.forSlot('s1').map((e) => e.id), ['el-1']);
      expect(s.forSlot('s2').map((e) => e.id), ['el-2']);
      // A screen share carries the all-camera ones only.
      expect(s.forSlot(null).map((e) => e.id), ['el-1']);
    });

    test('targets on the wire', () {
      expect(targetsToJson(GraphicTargets.none), {'slots': <String>[]});
      expect(
        targetsFromJson({
          'all': true,
          'except': ['s2'],
        }),
        const GraphicTargets.all(except: {'s2'}),
      );
    });

    test('style: kit with overrides, or Nile style', () {
      const kit = BrandStyle(accent: '#112233', panel: '#000000', text: '#FFFFFF');
      expect(ElementStyle.none.resolve(null), isNull);
      expect(ElementStyle.none.resolve(kit), kit);
      expect(
        const ElementStyle(accent: '#FF0000').resolve(kit)?.accent,
        '#FF0000',
      );
      expect(const ElementStyle(nileStyle: true).resolve(kit), isNull);
      // Overrides without a kit sit on Nile's own colours.
      expect(const ElementStyle(panel: '#123456').resolve(null)?.panel, '#123456');
      expect(const ElementStyle(accent: 'red').error, isNotNull);
    });

    test('the counter kind is test-only and validates its settings', () {
      expect(ElementKinds.offered(debug: false), isEmpty);
      expect(ElementKinds.offered(debug: true), [ElementKinds.counter]);
      expect(_counter.error, isNull);
      expect(_counter.copyWith(config: {'label': 'x', 'step': 500}).error, isNotNull);
      expect(_counter.copyWith(name: ' ').error, isNotNull);
    });
  });

  group('placement', () {
    test('without a layout everything sits where it always did', () {
      final p = placeOverlay(graphics: [_slate, _lt, _logo], elements: [_live()]);
      final at = {for (final x in p) x.id: x.spot};
      expect(at, {
        'logo': LayoutSpot.tr,
        'lt': LayoutSpot.bl,
        'slate': LayoutSpot.full,
        'el-1': LayoutSpot.tr,
      });
      // Back to front: corner bug, element, lower third, slate on top.
      expect(p.map((x) => x.id), ['logo', 'el-1', 'lt', 'slate']);
    });

    test('a layer list moves and orders items; disallowed spots are ignored', () {
      final p = placeOverlay(
        graphics: [_lt, _slate],
        elements: [_live()],
        layers: const [
          LayerEntry('el-1', spot: LayoutSpot.full),
          LayerEntry('lt', spot: LayoutSpot.tc),
          LayerEntry('slate', spot: LayoutSpot.bl),
        ],
      );
      final at = {for (final x in p) x.id: x.spot};
      expect(at['el-1'], LayoutSpot.full);
      expect(at['lt'], LayoutSpot.tc);
      expect(at['slate'], LayoutSpot.full); // a slate is always full screen
      // Top of the list = front.
      expect(p.last.id, 'el-1');
    });

    test('hidden items are left out; unlisted ones go in front', () {
      final p = placeOverlay(
        graphics: [_lt, _logo],
        elements: [_live()],
        layers: const [LayerEntry('lt', hidden: true), LayerEntry('el-1')],
      );
      expect(p.map((x) => x.id), ['el-1', 'logo']);
    });

    test('warns when something covers something else', () {
      final p = placeOverlay(
        graphics: [_lt],
        elements: [_live()],
        layers: const [
          LayerEntry('el-1', spot: LayoutSpot.full),
          LayerEntry('lt'),
        ],
      );
      expect(layoutWarnings(p).single, contains('Goals covers Jane'));
      expect(layoutWarnings(placeOverlay(graphics: [_lt])), isEmpty);
    });

    test('measures against the 16:9 picture inside any box', () {
      expect(videoFrame(const Size(1600, 900)), const Rect.fromLTWH(0, 0, 1600, 900));
      // Sideways phone: pillarboxed.
      expect(videoFrame(const Size(2000, 900)), const Rect.fromLTWH(200, 0, 1600, 900));
      // Upright phone: letterboxed.
      expect(videoFrame(const Size(900, 1600)).height, closeTo(506.25, 0.01));
      expect(videoFrame(Size.zero), Rect.zero);
    });

    test('layout: own list, else the shared one; copy to all', () {
      const a = [LayerEntry('lt', spot: LayoutSpot.tc)];
      const b = [LayerEntry('logo', hidden: true)];
      final l = const OverlayLayout(all: a).withLayers('s2', b);
      expect(l.layersFor('s1'), a);
      expect(l.layersFor('s2'), b);
      expect(l.layersFor(null), a);
      expect(l.copiedToAll(b).bySlot, isEmpty);
      final back = OverlayLayout.fromJson({...l.toJson(), 'at': 9});
      expect(back, l);
      expect(back.at, 9);
    });
  });

  group('hold-back', () {
    test('waits until this viewer\'s picture reaches the change', () {
      expect(
        overlayHoldback(contentAtMs: 10000, serverNowMs: 10200, viewerAgeMs: 900),
        const Duration(milliseconds: 700),
      );
      // Already caught up.
      expect(
        overlayHoldback(contentAtMs: 10000, serverNowMs: 11000, viewerAgeMs: 300),
        Duration.zero,
      );
    });

    test('never guesses: no clock or no picture age means no wait', () {
      expect(
        overlayHoldback(contentAtMs: 10000, serverNowMs: null, viewerAgeMs: 900),
        Duration.zero,
      );
      expect(
        overlayHoldback(contentAtMs: 10000, serverNowMs: 1, viewerAgeMs: null),
        Duration.zero,
      );
      expect(
        overlayHoldback(contentAtMs: 99999999, serverNowMs: 0, viewerAgeMs: 0),
        const Duration(seconds: 10),
      );
    });
  });

  group('cue with elements', () {
    const cue = ElementCue(id: 'el-1', name: 'Goals', targets: GraphicTargets.all());
    test('cues alongside graphics and lands on cameras', () {
      final s = CueSet.empty.addingElement(cue);
      expect(s.length, 1);
      expect(s.label, 'Goals');
      expect(s.lands('s1'), isTrue);
      expect(s.without('el-1').isEmpty, isTrue);
      expect(s.minus(CueSet(const [], [cue])).isEmpty, isTrue);
      // Re-cueing replaces.
      expect(
        s.addingElement(cue.withTargets(const GraphicTargets.only({'s2'}))).length,
        1,
      );
    });
  });

  group('controller', () {
    late List<(LiveElement, Map<String, ClockOp>)> pushed;
    late StudioElementsController c;

    setUp(() {
      pushed = [];
      c = StudioElementsController(
        push: (e, ops) async {
          pushed.add((e, ops));
          return e.withClockOps(ops, 0);
        },
      )..setLibrary(const [_counter]);
    });

    test('changes apply at once and push in order with rising versions', () async {
      for (var i = 0; i < 3; i++) {
        unawaited(
          c.update(
            'el-1',
            (e) => e.copyWith(state: {'value': (e.state['value'] as int) + 1}),
          ),
        );
      }
      expect(c.live('el-1')!.state['value'], 3);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(pushed.map((p) => p.$1.version), [1, 2, 3]);
    });

    test('undo goes back one change, at most ten', () async {
      for (var i = 0; i < 12; i++) {
        await c.update('el-1', (e) => e.copyWith(state: {'value': i}));
      }
      var undone = 0;
      while (await c.undo('el-1')) {
        undone++;
      }
      expect(undone, StudioElementsController.undoDepth);
      expect(c.live('el-1')!.state['value'], 1);
    });

    test('Take puts it on air; the monitor previews a cued one', () async {
      final cues = CueSet.empty.addingElement(
        const ElementCue(id: 'el-1', name: 'Goals', targets: GraphicTargets.only({'s1'})),
      );
      expect(c.onAir.isEmpty, isTrue);
      expect(c.preview(cues).forSlot('s1').single.id, 'el-1');
      await c.setTargets('el-1', const GraphicTargets.only({'s1'}));
      expect(c.onAir.forSlot('s1').single.id, 'el-1');
      expect(pushed.last.$1.targets, const GraphicTargets.only({'s1'}));
    });

    test('out of step: takes the server\'s version and says so', () async {
      String? error;
      final server = _live(value: 9).copyWith(version: 40);
      final stale = StudioElementsController(
        push: (e, ops) async => throw ElementStale(server),
        onError: (m) => error = m,
      )..setLibrary(const [_counter]);
      expect(await stale.update('el-1', (e) => e), isFalse);
      expect(stale.live('el-1')!.version, 40);
      expect(error, isNotNull);
    });

    test('clock commands run locally on the server clock estimate', () async {
      ServerClock.debugSetOffset(0);
      await c.update('el-1', (e) => e, clockOps: {'main': ClockOp.start});
      expect(c.live('el-1')!.clock('main').running, isTrue);
      expect(pushed.single.$2['main']!.kind, ClockOpKind.start);
    });

    test('restore: the server wins over older local state', () async {
      final r = StudioElementsController(
        push: (e, ops) async => e,
        load: () async => [_live(value: 7).copyWith(version: 5)],
      );
      await r.restore();
      expect(r.live('el-1')!.state['value'], 7);
    });
  });

  group('drawing', () {
    Widget frame(Widget child) => MaterialApp(
      home: Center(child: SizedBox(width: 640, height: 360, child: child)),
    );

    testWidgets('draws a counter element with its clock', (t) async {
      await t.pumpWidget(
        frame(
          NileGraphicsLayer(
            graphics: const [],
            elements: [
              _live(
                value: 4,
                clocks: {'main': const ElementClock(elapsedMs: 65000)},
              ),
            ],
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Goals'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(find.text('1:05'), findsOneWidget);
    });

    testWidgets('a layout moves a lower third to the top', (t) async {
      await t.pumpWidget(frame(const NileGraphicsLayer(graphics: [_lt])));
      await t.pumpAndSettle();
      final bottom = t.getCenter(find.text('Jane')).dy;
      await t.pumpWidget(
        frame(
          const NileGraphicsLayer(
            graphics: [_lt],
            layers: [LayerEntry('lt', spot: LayoutSpot.tc)],
          ),
        ),
      );
      await t.pumpAndSettle();
      final top = t.getCenter(find.text('Jane')).dy;
      expect(bottom, greaterThan(360 / 2));
      expect(top, lessThan(360 / 2));
    });

    testWidgets('sits on the picture, not the pillarbox', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              key: const Key('box'),
              width: 760,
              height: 360,
              child: NileGraphicsLayer(graphics: const [_lt]),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      // 360 high → a 640-wide picture centred in the 760-wide box (60 px
      // pillarbox each side), then the 3% safe margin (19.2 px).
      final box = t.getTopLeft(find.byKey(const Key('box')));
      expect(t.getTopLeft(find.text('Jane')).dx - box.dx, greaterThan(79));
    });

    testWidgets('a hidden item is not drawn', (t) async {
      await t.pumpWidget(
        frame(
          const NileGraphicsLayer(
            graphics: [_lt],
            layers: [LayerEntry('lt', hidden: true)],
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Jane'), findsNothing);
    });
  });

  group('layout sheet', () {
    test('starts front to back, keeping entries for items not on air', () {
      final l = initialLayers(
        graphics: const [_lt, _logo],
        elements: const [],
        layers: const [
          LayerEntry('gone', spot: LayoutSpot.mc),
          LayerEntry('logo', hidden: true),
        ],
      );
      expect(l.map((e) => e.id), ['lt', 'logo', 'gone']);
      expect(l[1].hidden, isTrue);
    });

    testWidgets('saves spots, order and copy to all', (t) async {
      LayoutChoice? got;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => got = await showLayoutSheet(
                context,
                cameraLabel: 'Camera 1',
                graphics: const [_lt, _logo],
                layers: const [],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('Layout · Camera 1'), findsOneWidget);
      await t.tap(find.byTooltip('Hide').first);
      await t.pump();
      await t.tap(find.text('Copy to all'));
      await t.pumpAndSettle();
      expect(got!.copyToAll, isTrue);
      expect(got!.layers.first.hidden, isTrue);
    });
  });

  group('Elements panel', () {
    testWidgets('select, keys act on it, cue it with Cameras', (t) async {
      t.view.physicalSize = const Size(1200, 1600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final pushed = <LiveElement>[];
      final ctl = StudioElementsController(
        push: (e, ops) async {
          pushed.add(e);
          return e.withClockOps(ops, 0);
        },
      );
      final cue = ValueNotifier(CueSet.empty);
      var took = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ElementsPanel(
              controller: ctl,
              slots: const <StudioSlotRef>[
                (id: 's1', label: 'Camera 1'),
                (id: 's2', label: 'Camera 2'),
              ],
              cue: cue,
              onTake: () async => took++,
              library: MemoryElementLibrary(const [_counter]),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Goals'), findsWidgets);
      // The first element starts selected: its controls are open.
      await t.sendKeyEvent(LogicalKeyboardKey.equal);
      await t.pumpAndSettle();
      expect(ctl.live('el-1')!.state['value'], 1);
      expect(pushed.single.version, 1);
      await t.tap(find.text('Undo'));
      await t.pumpAndSettle();
      expect(ctl.live('el-1')!.state['value'], 0);

      await t.tap(find.text('Off'));
      await t.pumpAndSettle();
      expect(find.text('Hide after'), findsNothing);
      await t.tap(find.text('Cue'));
      await t.pumpAndSettle();
      expect(cue.value.elementById('el-1'), isNotNull);
      expect(find.text('CUED'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(took, 1);
    });
  });
}

void unawaited(Future<void> f) {}
