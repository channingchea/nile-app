// Studio element HUD (docs/plans/studio-element-hud.md): the data format,
// the poll and counter cards, and the strip.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nile_app/services/element_hud.dart';
import 'package:nile_app/services/live_elements.dart';
import 'package:nile_app/services/server_clock.dart';
import 'package:nile_app/services/studio_elements_controller.dart';
import 'package:nile_app/services/studio_graphics.dart';
import 'package:nile_app/widgets/elements/element_kinds.dart';
import 'package:nile_app/widgets/elements/poll.dart';
import 'package:nile_app/widgets/studio_element_hud.dart';

const _pollItem = StudioElement(
  id: 'p1',
  kind: 'poll',
  name: 'Best opener?',
  config: {
    'type': 'choice',
    'question': 'Best opener?',
    'answers': [
      {'id': 'a1', 'text': 'Red'},
      {'id': 'a2', 'text': 'Blue'},
    ],
    'results': 'reveal',
  },
);

const _counterItem = StudioElement(
  id: 'c1',
  kind: 'counter',
  name: 'Goals',
  config: {'label': 'Goals', 'step': 2},
);

LiveElement _poll({
  String results = 'reveal',
  Map<String, dynamic> state = const {},
  int? timerSec,
}) => LiveElement(
  id: 'p1',
  kind: 'poll',
  name: 'Best opener?',
  config: {..._pollItem.config, 'results': results, 'timerSec': ?timerSec},
  state: state,
  targets: const GraphicTargets.all(),
);

Map<String, dynamic> _json(List<HudItem> items) => {
  'items': [for (final i in items) i.toJson()],
};

T _one<T extends HudItem>(List<HudItem> items, [bool Function(T)? where]) =>
    items.whereType<T>().where(where ?? (_) => true).single;

List<String> _readouts(List<HudItem> items) => [
  for (final r in items.whereType<HudReadout>()) r.text,
];

void main() {
  group('HUD data', () {
    test('every block survives JSON, unknown ones are dropped', () {
      const items = <HudItem>[
        HudButton(
          action: 'go',
          label: 'Go',
          icon: 'check',
          style: HudStyle.danger,
          active: true,
          enabled: false,
          confirm: 'Sure?',
        ),
        HudTimer(
          start: 't',
          stop: 's',
          running: true,
          ms: 4200,
          presets: [30, 60],
          defaultSec: 30,
        ),
        HudReadout('128 votes', tone: HudTone.accent, strong: true),
        HudInput(action: 'set', label: 'Set to', number: true, min: 0, max: 9),
      ];
      final wire = [
        for (final i in items) i.toJson(),
        {'type': 'video'},
        7,
      ];
      final back = HudItem.listFromJson(wire);
      expect(back, hasLength(4));
      expect(_json(back), _json(items));
    });

    test('inputs clamp numbers and trim text', () {
      const n = HudInput(
        action: 'a',
        label: 'n',
        number: true,
        min: 0,
        max: 10,
      );
      expect(n.parse(' 42 '), 10);
      expect(n.parse('-3'), 0);
      expect(n.parse('2.5'), 2.5);
      expect(n.parse('x'), isNull);
      expect(n.parse('  '), isNull);
      const t = HudInput(action: 'a', label: 't', maxLength: 3);
      expect(t.parse('  abcdef '), 'abc');
    });
  });

  group('poll card', () {
    final now = ServerClock.now();

    test('not started: Open, a timer menu, Reveal, no votes', () {
      final items = pollHud(_poll(), null, now);
      expect(_one<HudButton>(items, (b) => b.action == 'open').label, 'Open');
      final timer = _one<HudTimer>(items);
      expect(timer.running, isFalse);
      expect(timer.presets, pollTimerChoices);
      final reveal = _one<HudButton>(items, (b) => b.action == 'reveal');
      expect(
        (reveal.label, reveal.active, reveal.enabled),
        ('Reveal', false, true),
      );
      expect(_readouts(items), ['No votes yet', 'Hidden from viewers']);
    });

    test('open with a countdown: Close, time left, votes, still hidden', () {
      final e = _poll(
        timerSec: 45,
        state: {'open': true, 'closesAt': now + 42000},
      );
      final items = pollHud(e, const ElementTally({'a1': 100, 'a2': 28}), now);
      final open = _one<HudButton>(items, (b) => b.action == 'open');
      expect((open.label, open.style), ('Close', HudStyle.danger));
      final timer = _one<HudTimer>(items);
      expect((timer.running, timer.ms), (true, 42000));
      expect(timer.presets.first, 45);
      expect(timer.defaultSec, 45);
      expect(_readouts(items), ['128 votes', 'Hidden from viewers']);
    });

    test('closed and revealed; live polls fix Reveal on', () {
      final closed = pollHud(
        _poll(state: const {'revealed': true}),
        const ElementTally({'a1': 3}),
        now,
      );
      expect(
        _one<HudButton>(closed, (b) => b.action == 'open').label,
        'Reopen',
      );
      expect(
        _one<HudButton>(closed, (b) => b.action == 'reveal').label,
        'Revealed',
      );
      expect(_readouts(closed), ['3 votes', 'Closed']);

      final live = pollHud(_poll(results: 'live'), null, now);
      final reveal = _one<HudButton>(live, (b) => b.action == 'reveal');
      expect((reveal.active, reveal.enabled), (true, false));
      expect(_readouts(live).last, 'Viewers always see totals');
      expect(
        _readouts(pollHud(_poll(results: 'voted'), null, now)).last,
        'Shown after voting',
      );
    });

    test('actions are the panel\'s own changes', () {
      final e = _poll(timerSec: 30);
      expect(pollHudAct(e, 'open', null)!.ops, pollToggleOpen(e).ops);
      expect(pollHudAct(e, 'timer', 120)!.ops.timerSec, 120);
      expect(pollHudAct(e, 'stopTimer', null)!.ops.timer, isFalse);
      expect(
        pollHudAct(e, 'reveal', null)!.change(e).state,
        pollReveal(e).change(e).state,
      );
      expect(pollHudAct(e, 'reset', null), isNull);
    });
  });

  test('counter card: set clamps; ± use the step', () {
    final ui = elementKindUis['counter']!;
    final e = LiveElement.fromLibrary(_counterItem);
    expect(ui.hudAct!(e, 'up', null)!.change(e).state['value'], 2);
    expect(ui.hudAct!(e, 'set', 1e9)!.change(e).state['value'], 99999);
    final items = ui.hud!(e, null, ServerClock.now());
    expect(items.whereType<HudInput>(), hasLength(1));
    expect(items.whereType<HudTimer>().single.startLabel, 'Start clock');
  });

  group('strip', () {
    late StudioElementsController c;
    late ValueNotifier<CueSet> cue;
    final taken = <String>[];
    final opened = <String>[];

    setUp(() {
      c = StudioElementsController(push: (e, _) async => e, rehearsal: true)
        ..setLibrary(const [_pollItem, _counterItem]);
      cue = ValueNotifier(CueSet.empty);
      taken.clear();
      opened.clear();
    });

    Widget app() => MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            const Expanded(child: SizedBox()),
            ElementHudStrip(
              controller: c,
              cue: cue,
              cameraSummary: (t) => t.all ? 'All cameras' : 'Some',
              onTakeOne: (q) async => taken.add(q.id),
              onOpenPanel: opened.add,
            ),
          ],
        ),
      ),
    );

    testWidgets('cards follow on and off air; Open runs on the element', (
      t,
    ) async {
      await t.pumpWidget(app());
      expect(find.byType(HudCard), findsNothing);

      await c.setTargets('p1', const GraphicTargets.all());
      await t.pumpAndSettle();
      expect(find.text('ON AIR'), findsOneWidget);
      expect(find.text('Best opener?'), findsOneWidget);

      await t.tap(find.widgetWithText(FilledButton, 'Open'));
      await t.pump();
      expect(c.live('p1')!.open, isTrue);
      expect(find.widgetWithText(FilledButton, 'Close'), findsOneWidget);

      await c.setAngle('c1', true);
      await t.pump();
      expect(find.byType(HudCard), findsNWidgets(2));
      expect(find.text('ANGLE'), findsOneWidget);

      await t.tap(find.byTooltip('Open in Elements panel').first);
      expect(opened, ['p1']);

      await c.setTargets('p1', GraphicTargets.none);
      await t.pump();
      expect(find.byType(HudCard), findsOneWidget);
    });

    testWidgets('✕ hides a card until it comes back on air', (t) async {
      await c.setTargets('p1', const GraphicTargets.all());
      await t.pumpWidget(app());
      await t.tap(find.byTooltip('Hide this card'));
      await t.pump();
      expect(find.byType(HudCard), findsNothing);
      expect(find.text('1 hidden'), findsOneWidget);

      await t.tap(find.text('1 hidden'));
      await t.pumpAndSettle();
      await t.tap(find.text('Show “Best opener?”'));
      await t.pumpAndSettle();
      expect(find.byType(HudCard), findsOneWidget);

      c.setHudHidden('p1', true);
      await c.setTargets('p1', GraphicTargets.none);
      await c.setTargets('p1', const GraphicTargets.all());
      await t.pump();
      expect(c.hudHidden('p1'), isFalse);
      expect(find.byType(HudCard), findsOneWidget);
    });

    testWidgets('Off air takes it off cameras and angle; Undo puts it back', (
      t,
    ) async {
      await c.update(
        'p1',
        (e) => e.copyWith(targets: const GraphicTargets.all(), angle: true),
      );
      await t.pumpWidget(app());
      await t.tap(find.text('Off air'));
      await t.pumpAndSettle();
      expect(c.live('p1')!.live, isFalse);
      expect(find.byType(HudCard), findsNothing);
      expect(find.textContaining('taken off air. Votes kept.'), findsOneWidget);

      await t.tap(find.text('Undo'));
      await t.pumpAndSettle();
      final back = c.live('p1')!;
      expect((back.targets.all, back.angle), (true, true));
    });

    testWidgets('a cued element gets a dimmed card with Take', (t) async {
      cue.value = cue.value.addingElement(
        const ElementCue(
          id: 'p1',
          name: 'Best opener?',
          targets: GraphicTargets.all(),
        ),
      );
      await t.pumpWidget(app());
      expect(find.byType(HudCuedCard), findsOneWidget);
      expect(find.text('Goes on All cameras'), findsOneWidget);
      await t.tap(find.text('Take'));
      expect(taken, ['p1']);

      await t.tap(find.text('Remove from cue'));
      await t.pump();
      expect(cue.value.isEmpty, isTrue);
      expect(find.byType(HudCuedCard), findsNothing);
    });

    testWidgets('many cards scroll sideways', (t) async {
      await t.binding.setSurfaceSize(const Size(900, 600));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final lib = [
        for (var i = 0; i < 6; i++)
          StudioElement(
            id: 'c$i',
            kind: 'counter',
            name: 'Counter $i',
            config: const {'label': 'n', 'step': 1},
          ),
      ];
      c.setLibrary(lib);
      for (final e in lib) {
        await c.setTargets(e.id, const GraphicTargets.all());
      }
      await t.pumpWidget(app());
      expect(t.takeException(), isNull);
      expect(find.text('Counter 5'), findsNothing);
      await t.drag(find.byType(ListView), const Offset(-3000, 0));
      await t.pumpAndSettle();
      expect(find.text('Counter 5'), findsOneWidget);
    });
  });
}
