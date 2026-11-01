// Studio Layouts, phase 4: the controller (cue, Apply, library), the
// per-camera change summary, ⌥1–9 and the Layouts panel.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nile_app/services/live_elements.dart';
import 'package:nile_app/services/overlay_layout.dart';
import 'package:nile_app/services/show_control.dart';
import 'package:nile_app/services/studio_graphics.dart';
import 'package:nile_app/services/studio_layouts.dart';
import 'package:nile_app/services/studio_layouts_controller.dart';
import 'package:nile_app/widgets/studio_graphics_panel.dart';
import 'package:nile_app/widgets/studio_layouts_panel.dart';

const logo = StudioGraphic(
  id: 'logo',
  kind: GraphicKind.logo,
  name: 'Logo',
  payload: {'corner': 'tr'},
);
const lower = StudioGraphic(
  id: 'lt',
  kind: GraphicKind.lowerThird,
  name: 'Host',
  payload: {'title': 'Host'},
);

LiveGraphic build(StudioGraphic g, int? _) => LiveGraphic(
  id: g.id,
  kind: g.kind,
  title: g.payload['title'] as String?,
  corner: g.payload['corner'] as String?,
);

final t0 = DateTime.utc(2026, 11, 1, 20);

StudioLayout layout(String id, String name, List<LayoutItem> cam1) =>
    StudioLayout(
      id: id,
      name: name,
      cameras: [LayoutCamera(items: cam1)],
      updatedAt: t0,
    );

/// An in-memory library.
class FakeLayouts {
  FakeLayouts(this.items);
  List<StudioLayout> items;
  int ids = 0;
  final reorders = <List<String>>[];

  LayoutsBackend get backend => LayoutsBackend(
    list: () async => items,
    create: (l) async {
      final saved = StudioLayout.fromPayload(
        l.payload,
        id: 'new${ids++}',
        name: l.name,
        sort: l.sort,
        updatedAt: t0,
      );
      items = [...items, saved];
      return saved;
    },
    update: (l) async {
      final saved = StudioLayout.fromPayload(
        l.payload,
        id: l.id,
        name: l.name,
        sort: l.sort,
        updatedAt: (l.updatedAt ?? t0).add(const Duration(minutes: 1)),
      );
      items = [for (final x in items) x.id == l.id ? saved : x];
      return saved;
    },
    delete: (l) async => items = items.where((x) => x.id != l.id).toList(),
    reorder: (l) async => reorders.add([for (final x in l) x.id]),
    graphics: () async => const [logo, lower],
    elements: () async => const [],
  );
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late FakeLayouts lib;
  late StudioLayoutsController c;
  late GraphicsState graphics;
  late List<(StudioLayout, ResolvedLayout)> sent;
  late int cueCleared;

  setUp(() {
    lib = FakeLayouts([
      layout('a', 'Main show', const [LayoutItem.graphic('logo')]),
      layout('b', 'Interview', const [LayoutItem.graphic('lt')]),
    ]);
    graphics = GraphicsState.empty;
    sent = [];
    cueCleared = 0;
    c = StudioLayoutsController(
      current: () => (
        positions: const ['s1', 's2'],
        graphics: graphics,
        elements: const <LiveElement>[],
        overlay: OverlayLayout.empty,
        show: ShowControl.empty,
      ),
      build: build,
      send: (l, r) async {
        sent.add((l, r));
        graphics = r.graphics;
      },
      backend: lib.backend,
      onCue: () => cueCleared++,
    );
  });

  group('controller', () {
    test(
      'cue toggles, clears the graphics cue, and ⌥N picks the Nth',
      () async {
        await c.cueNumber(2);
        expect(c.cued?.id, 'b');
        expect(cueCleared, 1);
        c.cue(c.layouts[1]);
        expect(c.cued, isNull);
        await c.cueNumber(9);
        expect(c.cued, isNull);
      },
    );

    test(
      'Apply sends the resolved layout, marks it on air, clears the cue',
      () async {
        await c.load();
        c.cue(c.layouts[0]);
        final r = await c.apply();
        expect(sent.single.$1.id, 'a');
        expect(
          r!.graphics.targetsOf('logo'),
          const GraphicTargets.only({'s1'}),
        );
        expect(c.cued, isNull);
        expect(c.isOnAir(c.layouts[0]), isTrue);
        expect(c.isChanged(c.layouts[0]), isFalse);
      },
    );

    test(
      'saving an on-air layout again shows "changed since applied"',
      () async {
        await c.load();
        await c.apply(c.layouts[0]);
        await c.rename(c.layouts[0], 'Main');
        expect(c.isChanged(c.layouts[0]), isTrue);
        c.setApplied((id: 'a', updatedAt: c.layouts[0].updatedAt));
        expect(c.isChanged(c.layouts[0]), isFalse);
      },
    );

    test('save current look, duplicate, delete, reorder', () async {
      graphics = const GraphicsState()
          .withOn('s2', build(lower, null))
          .withOn(
            's1',
            const LiveGraphic(
              id: 'chat:1',
              kind: GraphicKind.chat,
              title: 'sam',
              text: 'hi',
            ),
          );
      final saved = await c.saveCurrent('Now');
      expect(saved.leftOut, ['sam']);
      expect(saved.layout.cameras[1].items, const [LayoutItem.graphic('lt')]);
      expect(c.layouts.map((l) => l.name), ['Main show', 'Interview', 'Now']);

      await c.duplicate(c.layouts[0]);
      expect(c.layouts.last.name, 'Main show copy');

      c.cue(c.layouts[1]);
      await c.delete(c.layouts[1]);
      expect(c.cued, isNull);
      expect(c.layouts.length, 3);

      await c.move(2, 0);
      expect(c.layouts.first.name, 'Main show copy');
      expect(c.layouts.map((l) => l.sort), [0, 1, 2]);
      expect(lib.reorders.single.first, c.layouts.first.id);
    });

    test('update from current look keeps the name and id', () async {
      await c.load();
      graphics = const GraphicsState().withOn('s1', build(lower, null));
      await c.updateFromCurrent(c.layouts[0]);
      expect(c.layouts[0].id, 'a');
      expect(c.layouts[0].name, 'Main show');
      expect(c.layouts[0].cameras[0].items, const [LayoutItem.graphic('lt')]);
    });
  });

  group('changes', () {
    test('per camera: added, removed, off air; untouched cameras left out', () {
      final before = const GraphicsState().withTargets(
        build(logo, null),
        const GraphicTargets.all(),
      );
      final to = resolveLayout(
        const StudioLayout(
          name: 'x',
          cameras: [
            LayoutCamera(items: [LayoutItem.graphic('lt')]),
            LayoutCamera(items: [LayoutItem.graphic('logo')], onAir: false),
          ],
        ),
        positions: const ['s1', 's2', 's3'],
        graphicsLibrary: const {'logo': logo, 'lt': lower},
        elementsLibrary: const {},
        build: build,
        graphics: before,
      );
      final changes = layoutChanges(
        to: to,
        labelOf: (s) => 'Cam ${s.substring(1)}',
        nameOf: (id) => id == 'lt' ? 'Host' : 'Logo',
        graphics: before,
      );
      expect(changes.map(describeChange), [
        'Cam 1: + Host · − Logo',
        'Cam 2: goes off air',
      ]);
    });

    test('layoutApplied reads from room metadata', () {
      expect(layoutAppliedFromRoomMetadata('{}'), isNull);
      expect(layoutAppliedFromRoomMetadata('not json'), isNull);
      final a = layoutAppliedFromRoomMetadata(
        '{"layoutApplied":{"id":"a","updatedAt":"2026-11-01T20:00:00.000Z"}}',
      );
      expect(a?.id, 'a');
      expect(a?.updatedAt, t0);
    });
  });

  group('hotkeys', () {
    testWidgets('⌥1–9 go to layouts, plain digits to graphics', (t) async {
      final alt = <int>[];
      final plain = <int>[];
      await t.pumpWidget(
        MaterialApp(
          home: StudioGraphicsHotkeys(
            onDigit: plain.add,
            onAltDigit: alt.add,
            child: const SizedBox(),
          ),
        ),
      );
      await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await t.sendKeyEvent(
        LogicalKeyboardKey.digit3,
        physicalKey: PhysicalKeyboardKey.digit3,
      );
      await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.digit2);
      expect(alt, [3]);
      expect(plain, [2]);
    });
  });

  group('panel', () {
    Widget app() => MaterialApp(
      home: Scaffold(
        body: LayoutsPanel(
          controller: c,
          slots: const [
            (id: 's1', label: 'Camera 1'),
            (id: 's2', label: 'Camera 2'),
          ],
        ),
      ),
    );

    testWidgets('cue shows what changes; Apply puts it on air', (t) async {
      await t.pumpWidget(app());
      await t.pumpAndSettle();
      expect(find.text('Main show'), findsOneWidget);
      expect(find.text('Interview'), findsOneWidget);

      await t.tap(find.widgetWithText(OutlinedButton, 'Cue').first);
      await t.pump();
      expect(find.text('CUED'), findsOneWidget);
      expect(find.text('Camera 1: + Logo'), findsOneWidget);

      await t.tap(find.text('Apply (Enter)'));
      await t.pumpAndSettle();
      expect(sent.single.$1.id, 'a');
      expect(find.text('ON AIR'), findsOneWidget);
      expect(find.text('“Main show” is on air.'), findsOneWidget);
    });

    testWidgets('Enter applies the cued layout', (t) async {
      await t.pumpWidget(app());
      await t.pumpAndSettle();
      c.cue(c.layouts[1]);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(sent.single.$1.id, 'b');
    });

    testWidgets('a missing item is flagged on the card', (t) async {
      lib.items = [
        layout('a', 'Old', const [LayoutItem.graphic('gone')]),
      ];
      await t.pumpWidget(app());
      await t.pumpAndSettle();
      expect(find.text('1 MISSING'), findsOneWidget);
    });

    testWidgets('empty library says how to start', (t) async {
      lib.items = [];
      await t.pumpWidget(app());
      await t.pumpAndSettle();
      expect(find.textContaining('No layouts yet'), findsOneWidget);
    });
  });
}
