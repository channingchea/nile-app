// Studio Layouts, phases 5-7: templates, the editor, the rehearsal (Studio
// Preview) storage and analytics.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nile_app/services/analytics.dart';
import 'package:nile_app/services/layout_templates.dart';
import 'package:nile_app/services/live_elements.dart';
import 'package:nile_app/services/overlay_layout.dart';
import 'package:nile_app/services/show_control.dart';
import 'package:nile_app/services/studio_graphics.dart';
import 'package:nile_app/services/studio_layouts.dart';
import 'package:nile_app/services/studio_layouts_controller.dart';
import 'package:nile_app/widgets/studio_layout_editor.dart';

LiveGraphic build(StudioGraphic g, int? _) => LiveGraphic(
  id: g.id,
  kind: g.kind,
  title: g.payload['title'] as String?,
  corner: g.payload['corner'] as String?,
);

const counter = StudioElement(id: 'ctr', kind: 'counter', name: 'Count');

/// A controller over a rehearsal backend seeded with [graphics].
({StudioLayoutsController c, List<StudioGraphic> created}) setup({
  List<String> positions = const ['s1', 's2', 's3'],
  List<StudioGraphic> graphics = const [],
}) {
  final created = <StudioGraphic>[];
  final base = LayoutsBackend.rehearsal(
    elements: () async => const [counter],
    savedLayouts: () async => const [],
    savedGraphics: () async => graphics,
  );
  final backend = LayoutsBackend(
    list: base.list,
    create: base.create,
    update: base.update,
    delete: base.delete,
    reorder: base.reorder,
    graphics: base.graphics,
    elements: base.elements,
    createGraphic: (g) async {
      final saved = await base.createGraphic(g);
      created.add(saved);
      return saved;
    },
  );
  return (
    c: StudioLayoutsController(
      current: () => (
        positions: positions,
        graphics: GraphicsState.empty,
        elements: const <LiveElement>[],
        overlay: OverlayLayout.empty,
        show: ShowControl.empty,
      ),
      build: build,
      send: (_, _) async {},
      backend: backend,
      rehearsal: true,
    ),
    created: created,
  );
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  group('templates', () {
    for (final cameras in [1, 3]) {
      test('each one resolves cleanly on a $cameras-camera show', () {
        final positions = [for (var i = 1; i <= cameras; i++) 's$i'];
        for (final t in layoutTemplates(logoPath: 'u/logo.png')) {
          final ids = {for (final g in t.graphics) g.id: 'lib-${g.id}'};
          final lib = {
            for (final g in t.graphics)
              ids[g.id]!: StudioGraphic(
                id: ids[g.id]!,
                kind: g.kind,
                name: g.name,
                payload: g.payload,
              ),
          };
          for (final g in t.graphics) {
            expect(
              StudioGraphic.validate(g.kind, g.payload),
              isNull,
              reason: '${t.id}/${g.id}',
            );
          }
          final layout = t.build((k) => ids[k]!, cameras);
          expect(layout.error, isNull, reason: t.id);
          expect(layout.cameras.length, cameras);
          final r = resolveLayout(
            layout,
            positions: positions,
            graphicsLibrary: lib,
            elementsLibrary: const {},
            build: build,
          );
          expect(r.missing, isEmpty, reason: t.id);
          expect(r.skippedCameras, 0);
          expect(r.covered, positions);
        }
      });
    }

    test('Be right back keeps only Camera 1 on air', () {
      final brb = layoutTemplates().firstWhere((t) => t.id == 'be_right_back');
      final l = brb.build((k) => k, 3);
      expect(l.cameras.map((c) => c.onAir), [true, false, false]);
    });

    test('Ending puts the QR code in front of the slate', () {
      final end = layoutTemplates().firstWhere((t) => t.id == 'ending');
      final l = end.build((k) => k, 1);
      expect(l.cameras.single.items.map((i) => i.ref), ['qr', 'slate']);
    });

    test('Main show: logo bug only with a brand-kit logo', () {
      final withLogo = layoutTemplates(
        logoPath: 'u/logo.png',
        hostName: 'Ana',
      ).firstWhere((t) => t.id == 'main_show');
      expect(withLogo.graphics.map((g) => g.id), ['logo', 'lt']);
      expect(withLogo.graphics.last.payload['title'], 'Ana');
      final l = withLogo.build((k) => k, 2);
      expect(l.cameras[0].items.map((i) => i.ref), ['lt', 'logo']);
      expect(l.cameras[1].items.map((i) => i.ref), ['logo']);

      final none = layoutTemplates().firstWhere((t) => t.id == 'main_show');
      expect(none.graphics.map((g) => g.id), ['lt']);
    });

    test('new from template saves its graphics once and reuses them', () async {
      final s = setup();
      final starting = layoutTemplates().firstWhere(
        (t) => t.id == 'starting_soon',
      );
      final a = await s.c.newFromTemplate(starting);
      final b = await s.c.newFromTemplate(starting);
      expect(s.created.length, 1);
      expect(a.template, 'starting_soon');
      expect(a.cameras.length, 3);
      expect(a.refs, b.refs);
      expect(s.c.layouts.length, 2);
    });

    test('an identical graphic already in the library is reused', () async {
      const mine = StudioGraphic(
        id: 'mine',
        kind: GraphicKind.slate,
        name: 'My BRB',
        payload: {'title': 'Be right back'},
      );
      final s = setup(graphics: const [mine]);
      final brb = layoutTemplates().firstWhere((t) => t.id == 'be_right_back');
      final l = await s.c.newFromTemplate(brb);
      expect(s.created, isEmpty);
      expect(l.refs, {'mine'});
    });
  });

  group('rehearsal storage', () {
    test('starts from the account but saves nowhere', () async {
      var reads = 0;
      final backend = LayoutsBackend.rehearsal(
        elements: () async => const [],
        savedLayouts: () async {
          reads++;
          return const [
            StudioLayout(id: 'real', name: 'Real', cameras: [LayoutCamera()]),
          ];
        },
        savedGraphics: () async => const [],
      );
      final saved = await backend.create(
        const StudioLayout(name: 'Practice', cameras: [LayoutCamera()]),
      );
      final edited = await backend.update(saved.copyWith(name: 'Practice 2'));
      expect((await backend.list()).map((l) => l.name), ['Real', 'Practice 2']);
      expect(edited.updatedAt, isNotNull);
      await backend.delete(saved);
      expect((await backend.list()).map((l) => l.id), ['real']);
      expect(reads, 1);
    });

    test('a bad layout is refused with its reason', () async {
      final backend = LayoutsBackend.rehearsal(
        elements: () async => const [],
        savedLayouts: () async => const [],
        savedGraphics: () async => const [],
      );
      expect(
        () => backend.create(
          const StudioLayout(name: '', cameras: [LayoutCamera()]),
        ),
        throwsArgumentError,
      );
    });
  });

  group('analytics', () {
    setUp(() => NileAnalytics.debugLog = []);
    tearDown(() => NileAnalytics.debugLog = null);

    test('saved, cued, applied — counts only, marked as a rehearsal', () async {
      final s = setup();
      final l = await s.c.save(
        const StudioLayout(name: 'Secret name', cameras: [LayoutCamera()]),
      );
      s.c.cue(l);
      await s.c.apply();
      final log = NileAnalytics.debugLog!;
      expect(log.map((e) => e.$1), [
        NileEvent.layoutSaved,
        NileEvent.layoutCued,
        NileEvent.layoutApplied,
      ]);
      for (final (_, props) in log) {
        expect(props['preview'], isTrue);
        expect(props['cameras'], 1);
        expect(props.values.contains('Secret name'), isFalse);
      }
      expect(log.last.$2['covered'], 1);
    });

    test('missing items are reported', () async {
      final s = setup();
      await s.c.apply(
        const StudioLayout(
          id: 'x',
          name: 'x',
          cameras: [
            LayoutCamera(items: [LayoutItem.graphic('gone')]),
          ],
        ),
      );
      final (event, props) = NileAnalytics.debugLog!.last;
      expect(event, NileEvent.layoutMissingItems);
      expect(props, {'cameras': 1, 'preview': true, 'missing': 1});
    });
  });

  group('editor', () {
    late StudioLayoutsController c;
    StudioLayout? result;

    setUp(() async {
      c = setup(
        graphics: const [
          StudioGraphic(
            id: 'lt',
            kind: GraphicKind.lowerThird,
            name: 'Host',
            payload: {'title': 'Host'},
          ),
        ],
      ).c;
      await c.load();
      result = null;
    });

    Widget app(StudioLayout l, {bool onAir = false}) => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async => result = await showLayoutEditor(
                context,
                layout: l,
                controller: c,
                onAir: onAir,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    testWidgets('add a camera, add a graphic, switch a camera off, save', (
      t,
    ) async {
      t.view
        ..physicalSize = const Size(1400, 1800)
        ..devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        app(const StudioLayout(name: 'Show', cameras: [LayoutCamera()])),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();

      await t.tap(find.text('Add'));
      await t.pumpAndSettle();
      await t.tap(find.text('Host').last);
      await t.pumpAndSettle();
      expect(find.text('Bottom left'), findsOneWidget);

      await t.tap(find.byTooltip('Add a camera'));
      await t.pumpAndSettle();
      expect(find.text('Camera 2'), findsOneWidget);
      await t.tap(find.byType(Switch).first);
      await t.pumpAndSettle();
      expect(find.text('Camera 2 · off'), findsOneWidget);

      final chip = find.widgetWithText(FilterChip, 'Count');
      await t.scrollUntilVisible(
        chip,
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await t.tap(chip);
      await t.pumpAndSettle();
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();

      expect(result!.cameras.length, 2);
      expect(result!.cameras[0].items, const [LayoutItem.graphic('lt')]);
      expect(result!.cameras[1].onAir, isFalse);
      expect(result!.angles, ['ctr']);
    });

    testWidgets('an on-air layout warns that saving needs a re-Apply', (
      t,
    ) async {
      t.view
        ..physicalSize = const Size(1400, 1800)
        ..devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        app(
          const StudioLayout(name: 'Show', cameras: [LayoutCamera()]),
          onAir: true,
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.textContaining('Apply it again'), findsOneWidget);
    });

    testWidgets('an empty name is refused', (t) async {
      t.view
        ..physicalSize = const Size(1400, 1800)
        ..devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        app(const StudioLayout(name: 'Show', cameras: [LayoutCamera()])),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).first, ' ');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(find.text('Name is 1–60 characters.'), findsOneWidget);
      expect(result, isNull);
    });
  });
}
