// Studio live elements, phase 7: rehearsing elements in Studio Preview (the
// demo audience votes, element angles join the tiles, nothing is saved), the
// PostHog events element use reports, and the host's results after a show.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nile_app/services/analytics.dart';
import 'package:nile_app/services/live_elements.dart';
import 'package:nile_app/services/studio_elements_controller.dart';
import 'package:nile_app/services/studio_graphics.dart';
import 'package:nile_app/widgets/element_results.dart';
import 'package:nile_app/widgets/nile_studio.dart';
import 'package:nile_app/widgets/studio_elements_panel.dart';
import 'package:nile_app/widgets/studio_graphics_panel.dart' show StudioSlotRef;
import 'package:nile_app/widgets/studio_preview_demo.dart';

const _goals = StudioElement(
  id: 'el-1',
  kind: 'counter',
  name: 'Goals',
  config: {'label': 'Goals', 'step': 1, 'taps': true},
);

int _total(ElementTally? t) => t?.votes ?? 0;

/// [_goals] open for taps on every camera.
LiveElement get _openGoals => LiveElement.fromLibrary(_goals).copyWith(
  state: {'value': 0, 'open': true},
  targets: const GraphicTargets.all(),
);

StudioElementsController _local({bool rehearsal = true}) =>
    StudioElementsController(push: (e, _) async => e, rehearsal: rehearsal)
      ..setLibrary(const [_goals]);

void main() {
  group('Studio Preview: demo audience', () {
    test('votes arrive while taps are open and stop when they close', () {
      final demo = StudioPreviewDemo(random: Random(7));
      addTearDown(demo.dispose);
      final told = <String, ElementTally>{};
      demo.onTally = (id, t) => told[id] = t;

      demo.vote([_openGoals]);
      for (var i = 0; i < 5; i++) {
        demo.addVotes();
      }
      final early = _total(demo.tallyOf('el-1'));
      expect(early, greaterThan(0));
      expect(told['el-1'], demo.tallyOf('el-1'));

      // A believable room: most of it votes, never more than it holds
      // (24 in Sound Check, so 80% is 19).
      for (var i = 0; i < 100; i++) {
        demo.addVotes();
      }
      expect(_total(demo.tallyOf('el-1')), 19);

      demo.vote(const []);
      final closed = demo.tallyOf('el-1');
      demo.addVotes();
      expect(demo.tallyOf('el-1'), closed, reason: 'totals stay, none move');
    });

    test('element angles join the tiles last; cameras keep their numbers', () {
      final demo = StudioPreviewDemo(random: Random(1));
      addTearDown(demo.dispose);
      demo.elementAngles = ['el-1'];
      expect(demo.order.last, 'el:el-1');

      demo.reorder([
        'el:el-1',
        StudioPreviewDemo.selfSlot,
        for (final c in StudioPreviewDemo.crew) c.slotId!,
      ]);
      expect(demo.order.first, 'el:el-1');
      expect(demo.labelOf(StudioPreviewDemo.crew.first), 'Camera 2 · Alex');

      demo.toggleDefault('el:el-1');
      demo.elementAngles = const [];
      expect(demo.order, isNot(contains('el:el-1')));
      expect(demo.defaultSlot, isNull);
    });

    test(
      'the library starts from your saved elements and saves nowhere',
      () async {
        var reads = 0;
        final lib = PreviewElementLibrary(() async {
          reads++;
          return const [_goals];
        });
        expect((await lib.list()).single.id, 'el-1');
        final made = await lib.create(
          const StudioElement(
            id: 'draft',
            kind: 'counter',
            name: 'Saves',
            config: {'label': 'Saves', 'step': 1},
          ),
        );
        expect(made.id, startsWith('local-'));
        await lib.delete(_goals);
        expect([for (final e in await lib.list()) e.name], ['Saves']);
        expect(reads, 1);

        final offline = PreviewElementLibrary(() async => throw Exception('x'));
        expect(await offline.list(), isEmpty);
      },
    );

    testWidgets('an element angle tile offers show control, not Layout', (
      t,
    ) async {
      await t.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final angle = LiveElement.fromLibrary(_goals).copyWith(angle: true);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NileStudio(
              sources: [
                const NileStudioSource(
                  identity: 'preview:self',
                  label: 'Your camera',
                  isLocal: true,
                  slotId: 's1',
                ),
                NileStudioSource(
                  identity: 'el:el-1',
                  label: 'Goals',
                  sublabel: 'Element angle',
                  slotId: 'el:el-1',
                  element: angle,
                ),
              ],
              selectedIdentity: null,
              onSelectSource: (_) {},
              selfIdentity: 'preview:self',
              stats: const NileStudioStats(isLive: false),
              controls: const SizedBox(),
              showChatColumn: false,
              sourceActions: NileStudioSourceActions(
                onToggleOffAir: (_) {},
                onLayers: (_) {},
              ),
            ),
          ),
        ),
      );
      final menus = find.byTooltip('Source options');
      await t.tap(menus.at(0));
      await t.pumpAndSettle();
      expect(find.text('Layers…'), findsOneWidget);
      await t.tapAt(Offset.zero);
      await t.pumpAndSettle();
      await t.tap(menus.at(1));
      await t.pumpAndSettle();
      expect(find.text('Take off air'), findsOneWidget);
      expect(find.text('Layers…'), findsNothing);
    });
  });

  group('analytics', () {
    late List<(NileEvent, Map<String, Object>)> log;
    setUp(() => NileAnalytics.debugLog = log = []);
    tearDown(() => NileAnalytics.debugLog = null);

    test(
      'a rehearsal reports take, own angle and taps — kind and counts only',
      () async {
        final ctl = _local();
        addTearDown(ctl.dispose);
        await ctl.setTargets('el-1', GraphicTargets.only({'s1', 's2'}));
        // A retarget is not a second Apply.
        await ctl.setTargets('el-1', const GraphicTargets.all());
        await ctl.setAngle('el-1', true);
        await ctl.update(
          'el-1',
          (e) => e.copyWith(state: {...e.state, 'open': true}),
        );
        await ctl.update(
          'el-1',
          (e) => e.copyWith(state: {...e.state, 'value': 3}),
        );
        await ctl.update(
          'el-1',
          (e) => e.copyWith(state: {...e.state, 'open': false}),
        );

        expect(
          [for (final (e, _) in log) e],
          [
            NileEvent.elementTaken,
            NileEvent.elementAngleShown,
            NileEvent.elementTapsOpened,
            NileEvent.elementTapsClosed,
          ],
        );
        expect(log.first.$2, {
          'kind': 'counter',
          'preview': true,
          'all_cameras': false,
          'cameras': 2,
        });
        for (final (_, props) in log.skip(1)) {
          expect(props, {'kind': 'counter', 'preview': true});
        }
      },
    );

    test('the real Studio says live; a failed push reports nothing', () async {
      final live = _local(rehearsal: false);
      addTearDown(live.dispose);
      await live.setTargets('el-1', const GraphicTargets.all());
      expect(log.single.$2['preview'], false);
      expect(log.single.$2['all_cameras'], true);

      log.clear();
      final failing = StudioElementsController(
        push: (e, ops) async => throw Exception('offline'),
      )..setLibrary(const [_goals]);
      addTearDown(failing.dispose);
      expect(
        await failing.setTargets('el-1', const GraphicTargets.all()),
        false,
      );
      expect(log, isEmpty);
    });

    testWidgets('saving a new element reports its kind', (t) async {
      await t.binding.setSurfaceSize(const Size(1000, 1400));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final ctl = StudioElementsController(push: (e, _) async => e);
      addTearDown(ctl.dispose);
      final cue = ValueNotifier(CueSet.empty);
      addTearDown(cue.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ElementsPanel(
              controller: ctl,
              slots: const <StudioSlotRef>[(id: 's1', label: 'Camera 1')],
              cue: cue,
              onTake: () async {},
              library: MemoryElementLibrary(),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('New element'));
      await t.pumpAndSettle();
      await t.tap(find.text('Counter (test)').last);
      await t.pumpAndSettle();
      await t.scrollUntilVisible(
        find.text('Save'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await t.ensureVisible(find.text('Save'));
      await t.pumpAndSettle();
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(log.single.$1, NileEvent.elementSaved);
      expect(log.single.$2, {'kind': 'counter', 'new': true, 'preview': false});
    });
  });

  group('results after the show', () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('each choice with its final count and share', (t) async {
      await t.pumpWidget(
        wrap(
          ElementResults(
            elements: [LiveElement.fromLibrary(_goals)],
            tallies: const {
              'el-1': ElementTally({'up': 3, 'down': 1}),
            },
          ),
        ),
      );
      expect(find.text('Results'), findsOneWidget);
      expect(find.text('Goals'), findsOneWidget);
      expect(find.text('4 votes'), findsOneWidget);
      expect(find.text('3 · 75%'), findsOneWidget);
      expect(find.text('1 · 25%'), findsOneWidget);
    });

    testWidgets('no votes reads as zero', (t) async {
      await t.pumpWidget(
        wrap(
          ElementResults(
            elements: [LiveElement.fromLibrary(_goals)],
            tallies: const {},
          ),
        ),
      );
      expect(find.text('0 votes'), findsOneWidget);
      expect(find.text('0 · 0%'), findsNWidgets(2));
    });

    testWidgets('nothing at all when no element took taps', (t) async {
      final plain = LiveElement.fromLibrary(
        const StudioElement(
          id: 'el-2',
          kind: 'counter',
          name: 'Count',
          config: {'label': 'Count', 'step': 1},
        ),
      );
      expect(ElementResults.tappable([plain]), isEmpty);
      await t.pumpWidget(
        wrap(ElementResults(elements: [plain], tallies: const {})),
      );
      expect(find.text('Results'), findsNothing);
    });
  });
}
