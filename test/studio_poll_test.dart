// Studio polls (docs/plans/studio-poll.md): the model, the look, the Studio's
// editor and controls, and viewer voting.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nile_app/services/live_elements.dart';
import 'package:nile_app/services/overlay_clock.dart';
import 'package:nile_app/services/studio_elements_controller.dart';
import 'package:nile_app/services/studio_graphics.dart';
import 'package:nile_app/widgets/elements/element_kinds.dart';
import 'package:nile_app/widgets/elements/poll.dart';
import 'package:nile_app/widgets/element_results.dart';
import 'package:nile_app/widgets/nile_graphics_layer.dart';
import 'package:nile_app/widgets/studio_preview_demo.dart';

const _answers = [
  {'id': 'a1', 'text': 'Red'},
  {'id': 'a2', 'text': 'Blue'},
  {'id': 'a3', 'text': 'Green'},
];

LiveElement _poll({
  String type = 'choice',
  String results = 'live',
  int? maxPicks,
  int? timerSec,
  Map<String, dynamic> state = const {'open': true},
  List<Map<String, String>> answers = _answers,
}) => LiveElement(
  id: 'p1',
  kind: 'poll',
  name: 'Poll',
  config: {
    'type': type,
    'question': 'Best colour?',
    'answers': answers,
    'results': results,
    'maxPicks': ?maxPicks,
    'timerSec': ?timerSec,
  },
  state: state,
  targets: const GraphicTargets.all(),
);

const _tally = ElementTally({'a1': 6, 'a2': 3, 'a3': 1});

void main() {
  group('poll model', () {
    test('settings: answers, fixed answers, limits and errors', () {
      final c = PollConfig.fromJson(_poll().config);
      expect(c.items.map((a) => a.text), ['Red', 'Blue', 'Green']);
      expect(c.error, isNull);
      expect(c.pickLimit, 1);
      expect(c.labelOf('a2'), 'Blue');
      expect(
        PollConfig.fromJson(_poll(type: 'yesno').config).items.map((a) => a.id),
        ['yes', 'no'],
      );
      expect(
        PollConfig.fromJson(_poll(type: 'rating').config).items,
        hasLength(5),
      );
      expect(PollConfig.fromJson(_poll(type: 'several').config).pickLimit, 3);
      expect(
        PollConfig.fromJson(
          _poll(type: 'several', maxPicks: 2).config,
        ).pickLimit,
        2,
      );

      expect(c.copyWith(question: ' ').error, 'Write the question.');
      expect(
        c.copyWith(answers: [c.answers.first]).error,
        'Add at least two answers.',
      );
      expect(
        c
            .copyWith(answers: [...c.answers, const PollAnswer('a4', 'red')])
            .error,
        contains('twice'),
      );
      expect(
        c.copyWith(answers: [...c.answers, const PollAnswer('a4', ' ')]).error,
        isNotNull,
      );
      expect(c.copyWith(timerSec: 5).error, isNotNull);
      expect(c.nextAnswerId(), 'a4');

      // Wording changes keep the answers; order, number and type don't.
      final reworded = c.copyWith(
        answers: [for (final a in c.answers) PollAnswer(a.id, '${a.text}!')],
      );
      expect(c.sameAnswers(reworded), isTrue);
      expect(
        c.sameAnswers(c.copyWith(answers: c.answers.reversed.toList())),
        isFalse,
      );
      expect(c.sameAnswers(c.copyWith(type: PollType.several)), isFalse);

      // The kind spec agrees.
      final e = _poll(type: 'several', maxPicks: 2);
      expect(e.choices, ['a1', 'a2', 'a3']);
      expect(e.maxPicks, 2);
      expect(e.labelOf('a3'), 'Green');
      expect(
        ElementKinds.poll.validate!(ElementKinds.poll.defaultConfig),
        isNotNull,
      );
    });

    test(
      'results: percent of votes, of voters for pick several, rating average',
      () {
        final r = PollResults(PollConfig.fromJson(_poll().config), _tally);
        expect(r.votes, 10);
        expect(r.voters, 10);
        expect(r.percent('a1'), 60);
        expect(r.votesLabel, '10 votes');

        final several = PollResults(
          PollConfig.fromJson(_poll(type: 'several').config),
          const ElementTally({'a1': 4, 'a2': 3, 'a3': 1}, 5),
        );
        expect(several.percent('a1'), 80);
        expect(several.votesLabel, '5 votes');

        final rating = PollResults(
          PollConfig.fromJson(_poll(type: 'rating').config),
          const ElementTally({'5': 2, '4': 1, '1': 1}),
        );
        expect(rating.average, 3.8);
        expect(
          PollResults(
            PollConfig.fromJson(_poll().config),
            ElementTally.empty,
          ).isEmpty,
          isTrue,
        );
        expect(
          PollResults(
            PollConfig.fromJson(_poll(type: 'rating').config),
            ElementTally.empty,
          ).average,
          isNull,
        );
      },
    );

    test('who sees totals', () {
      PollConfig c(String m) => PollConfig.fromJson(_poll(results: m).config);
      const hidden = PollState(open: true);
      const shown = PollState(revealed: true);
      bool see(
        String m,
        PollState s,
        ElementAudience a, {
        bool voted = false,
      }) => pollResultsVisible(c(m), s, audience: a, voted: voted);
      expect(see('live', hidden, ElementAudience.viewer), isTrue);
      expect(see('voted', hidden, ElementAudience.viewer), isFalse);
      expect(see('voted', hidden, ElementAudience.viewer, voted: true), isTrue);
      expect(see('voted', shown, ElementAudience.viewer), isTrue);
      expect(
        see('reveal', hidden, ElementAudience.viewer, voted: true),
        isFalse,
      );
      expect(see('reveal', shown, ElementAudience.viewer), isTrue);
      expect(see('reveal', hidden, ElementAudience.staff), isTrue);
      expect(see('reveal', hidden, ElementAudience.replay), isFalse);
      expect(see('reveal', shown, ElementAudience.replay), isTrue);
      expect(see('voted', hidden, ElementAudience.replay), isTrue);
    });

    test('timer and reset apply locally the way the server does', () {
      final e = _poll(timerSec: 30, state: const {'open': true, 'round': 2});
      final timed = e.withOps(const ElementOps(timer: true), 1000);
      expect(timed.state['closesAt'], 31000);
      expect(
        e
            .withOps(const ElementOps(timer: true, timerSec: 10), 0)
            .state['closesAt'],
        10000,
      );
      expect(
        timed
            .withOps(const ElementOps(timer: false), 0)
            .state
            .containsKey('closesAt'),
        isFalse,
      );
      final reset = timed.withOps(const ElementOps(reset: true), 0);
      expect(reset.state['round'], 3);
      expect(reset.state.containsKey('closesAt'), isFalse);
      // A timer in the past closes voting.
      expect(
        _poll(state: const {'open': true, 'closesAt': 1}).openChoices,
        isEmpty,
      );
      expect(const ElementOps(timer: true, timerSec: 20).toJson(), {
        'timer': {'op': 'start', 'sec': 20},
      });
      expect(ElementOps.none.isEmpty, isTrue);
    });

    test(
      'the controller sends ops once and a reset clears the totals',
      () async {
        final sent = <LiveElement>[];
        final c =
            StudioElementsController(
              push: (e, _) async {
                sent.add(e);
                return e;
              },
            )..setLibrary([
              StudioElement(
                id: 'p1',
                kind: 'poll',
                name: 'Poll',
                config: _poll().config,
              ),
            ]);
        c.setTally('p1', _tally);
        await c.update(
          'p1',
          (e) => e.copyWith(state: const {}),
          ops: const ElementOps(reset: true),
        );
        expect(sent.single.toJson()['ops'], {'reset': true});
        expect(c.tally('p1'), ElementTally.empty);
        expect(c.live('p1')!.state['round'], 1);
        expect(c.live('p1')!.ops.isEmpty, isTrue);
        await c.update('p1', (e) => e);
        expect(sent.last.toJson().containsKey('ops'), isFalse);
      },
    );
  });

  group('poll look', () {
    Widget host(
      LiveElement e, {
      ElementInteraction? interaction,
      Size screen = const Size(1200, 800),
      Size box = const Size(640, 360),
      bool full = false,
    }) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: screen),
        child: Scaffold(
          body: Center(
            child: SizedBox.fromSize(
              size: box,
              child: full
                  ? NileElementAngle(element: e, interaction: interaction)
                  : NileGraphicsLayer(
                      graphics: const [],
                      elements: [e],
                      interactionFor: (_) => interaction,
                    ),
            ),
          ),
        ),
      ),
    );

    testWidgets('live results: percentages, votes, your pick ticked', (
      t,
    ) async {
      await t.pumpWidget(
        host(
          _poll(),
          interaction: const ElementInteraction(tally: _tally, mine: ['a2']),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Best colour?'), findsOneWidget);
      expect(find.text('60%'), findsOneWidget);
      expect(find.textContaining('10 votes'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('results hidden until you vote, or until the reveal', (
      t,
    ) async {
      await t.pumpWidget(
        host(
          _poll(results: 'voted'),
          interaction: const ElementInteraction(tally: _tally),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('60%'), findsNothing);
      expect(find.textContaining('Results after you vote'), findsOneWidget);

      await t.pumpWidget(
        host(
          _poll(results: 'reveal'),
          interaction: const ElementInteraction(tally: _tally, mine: ['a1']),
        ),
      );
      await t.pumpAndSettle();
      expect(find.textContaining('Results soon'), findsOneWidget);

      await t.pumpWidget(
        host(
          _poll(results: 'reveal', state: const {'revealed': true}),
          interaction: const ElementInteraction(tally: _tally),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('60%'), findsOneWidget);
      expect(find.text('Closed'), findsOneWidget);
    });

    testWidgets('a countdown while the timer runs', (t) async {
      await t.pumpWidget(
        OverlayClock(
          now: () => 1000,
          child: host(
            _poll(state: const {'open': true, 'closesAt': 43000}),
            interaction: const ElementInteraction(),
          ),
        ),
      );
      await t.pump();
      expect(find.text('0:42'), findsOneWidget);
    });

    testWidgets('larger screens: tap an answer on the card', (t) async {
      List<String>? voted;
      await t.pumpWidget(
        host(_poll(), interaction: ElementInteraction(onTap: (p) => voted = p)),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Blue'));
      expect(voted, ['a2']);
    });

    testWidgets(
      'pick several on the card: choose, then Submit within the limit',
      (t) async {
        List<String>? voted;
        await t.pumpWidget(
          host(
            _poll(type: 'several', maxPicks: 2),
            interaction: ElementInteraction(onTap: (p) => voted = p),
          ),
        );
        await t.pumpAndSettle();
        await t.tap(find.text('Green'));
        await t.tap(find.text('Red'));
        await t.tap(find.text('Blue'));
        await t.pump();
        expect(find.text('Pick up to 2'), findsWidgets);
        await t.tap(find.text('Blue'));
        await t.pump();
        await t.tap(find.text('Submit'));
        expect(voted, ['a1', 'a3'], reason: 'in answer order');
      },
    );

    testWidgets('rating: tap a star; results show the average', (t) async {
      List<String>? voted;
      await t.pumpWidget(
        host(
          _poll(type: 'rating'),
          interaction: ElementInteraction(onTap: (p) => voted = p),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byIcon(Icons.star_outline_rounded).at(3));
      expect(voted, ['4']);

      await t.pumpWidget(
        host(
          _poll(type: 'rating', state: const {}),
          interaction: const ElementInteraction(
            tally: ElementTally({'5': 2, '4': 1, '1': 1}),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('3.8'), findsOneWidget);
    });

    testWidgets('phones vote from a sheet with big buttons', (t) async {
      List<String>? voted;
      await t.pumpWidget(
        host(
          _poll(),
          screen: const Size(390, 844),
          box: const Size(390, 220),
          interaction: ElementInteraction(onTap: (p) => voted = p),
        ),
      );
      await t.pumpAndSettle();
      expect(find.textContaining('Tap to vote'), findsOneWidget);
      await t.tap(find.text('Blue'));
      await t.pumpAndSettle();
      expect(voted, isNull, reason: 'the card itself opens the sheet');
      expect(find.byType(PollVoteSheet), findsOneWidget);
      await t.tap(
        find.descendant(
          of: find.byType(PollVoteSheet),
          matching: find.text('Blue'),
        ),
      );
      await t.pumpAndSettle();
      expect(voted, ['a2']);
      expect(find.byType(PollVoteSheet), findsNothing);
    });

    testWidgets('signed out: the sheet says to sign in', (t) async {
      await t.pumpWidget(
        host(
          _poll(),
          screen: const Size(390, 844),
          box: const Size(390, 220),
          interaction: const ElementInteraction(needsSignIn: true),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Best colour?'));
      await t.pumpAndSettle();
      expect(find.text('Sign in to vote'), findsOneWidget);
    });

    testWidgets('closed: nothing to tap', (t) async {
      var taps = 0;
      await t.pumpWidget(
        host(
          _poll(state: const {}),
          interaction: ElementInteraction(onTap: (_) => taps++),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Blue'), warnIfMissed: false);
      expect(taps, 0);
    });

    testWidgets(
      'six answers fit the smallest tile, on a camera and full screen',
      (t) async {
        final six = [
          for (var i = 1; i <= 6; i++)
            {'id': 'a$i', 'text': 'A rather long answer number $i'},
        ];
        for (final type in ['choice', 'several', 'rating', 'yesno']) {
          final e = _poll(type: type, answers: six, timerSec: 30);
          const i = ElementInteraction(
            tally: ElementTally({'a1': 3, '4': 2}),
            audience: ElementAudience.replay,
          );
          await t.pumpWidget(host(e, interaction: i, box: const Size(160, 90)));
          await t.pumpAndSettle();
          expect(t.takeException(), isNull, reason: '$type on a camera');
          await t.pumpWidget(
            host(e, interaction: i, box: const Size(160, 90), full: true),
          );
          await t.pumpAndSettle();
          expect(t.takeException(), isNull, reason: '$type full screen');
        }
      },
    );
  });

  group('Studio', () {
    Widget panel(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

    testWidgets('editor: answers lock while running; warnings show', (t) async {
      Map<String, dynamic>? out;
      final ui = elementKindUis['poll']!;
      await t.pumpWidget(
        panel(
          ui.editor(
            ElementKinds.poll.defaultConfig,
            (c) => out = c,
            locked: false,
          ),
        ),
      );
      expect(find.text('Write the question.'), findsOneWidget);
      await t.enterText(
        find.widgetWithText(TextField, 'Question'),
        'Best colour?',
      );
      await t.pump();
      expect(find.textContaining('Fill in every answer'), findsOneWidget);
      await t.tap(find.text('Add answer'));
      await t.pump();
      expect((out!['answers'] as List).length, 3);

      await t.pumpWidget(
        panel(ui.editor(_poll().config, (c) => out = c, locked: true)),
      );
      expect(
        find.textContaining('only its wording can change'),
        findsOneWidget,
      );
      expect(find.text('Add answer'), findsNothing);
      final remove = t.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.close).first,
      );
      expect(remove.onPressed, isNull);
    });

    testWidgets('controls: open starts the default timer; reset asks first', (
      t,
    ) async {
      final acts = <ElementOps>[];
      var e = _poll(timerSec: 30, state: const {});
      Widget build() => panel(
        elementKindUis['poll']!.controls(e, (
          change, {
          clockOps = const {},
          ops = ElementOps.none,
        }) {
          acts.add(ops);
          e = change(e);
        }, _tally),
      );
      await t.pumpWidget(build());
      expect(find.text('10 votes'), findsOneWidget);
      await t.tap(find.text('Reopen  (O)'));
      expect(acts.last, const ElementOps(timer: true, timerSec: 30));
      expect(e.open, isTrue);

      // Reveal is always there: filled with a tick once viewers see totals.
      expect(find.text('Reveal  (V)'), findsNothing);
      expect(find.text('Revealed'), findsOneWidget, reason: 'live results');

      await t.pumpWidget(build());
      await t.tap(find.text('Reset'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(TextButton, 'Reset').last);
      await t.pumpAndSettle();
      expect(acts.last.reset, isTrue);
    });

    testWidgets('Reveal turns into a filled Revealed, and back', (t) async {
      var e = _poll(results: 'reveal');
      Widget build() => panel(
        elementKindUis['poll']!.controls(e, (
          change, {
          clockOps = const {},
          ops = ElementOps.none,
        }) {
          e = change(e);
        }, _tally),
      );
      await t.pumpWidget(build());
      await t.tap(find.text('Reveal  (V)'));
      await t.pumpWidget(build());
      expect(e.state['revealed'], isTrue);
      expect(find.text('Revealed'), findsOneWidget);
      await t.tap(find.text('Revealed'));
      await t.pumpWidget(build());
      expect(find.text('Reveal  (V)'), findsOneWidget);
    });

    test('shortcuts: O, V, T', () {
      final keys = [for (final s in elementKindUis['poll']!.shortcuts) s.label];
      expect(keys, ['Open / close', 'Reveal / hide results', 'Start timer']);
      final hidden = _poll(results: 'reveal');
      final shown = pollReveal(hidden).change(hidden);
      expect(shown.state['revealed'], isTrue);
      expect(
        pollReveal(shown).change(shown).state['revealed'],
        isNull,
        reason: 'V again hides',
      );
      final voted = _poll(results: 'voted');
      expect(pollReveal(voted).change(voted).state['revealed'], isTrue);
      expect(
        pollReveal(_poll()).change(_poll()).state['revealed'],
        isNull,
        reason: 'live: always shown',
      );
      final timer = pollStartTimer(_poll(state: const {}));
      expect(timer.ops, const ElementOps(timer: true, timerSec: 60));
      expect(timer.change(_poll(state: const {})).open, isTrue);
    });

    test(
      'Studio Preview: pick several honours its limit; ratings lean to 4',
      () {
        final demo = StudioPreviewDemo(random: Random(3));
        addTearDown(demo.dispose);
        final several = _poll(type: 'several', maxPicks: 2);
        final rating = _poll(type: 'rating');
        demo.vote([several]);
        for (var i = 0; i < 40; i++) {
          demo.addVotes();
        }
        final t = demo.tallyOf('p1')!;
        expect(t.voters, 19);
        expect(t.votes, inInclusiveRange(19, 38));

        final demo2 = StudioPreviewDemo(random: Random(5));
        addTearDown(demo2.dispose);
        demo2.vote([rating]);
        for (var i = 0; i < 40; i++) {
          demo2.addVotes();
        }
        final avg = PollResults(
          PollConfig.fromJson(rating.config),
          demo2.tallyOf('p1')!,
        ).average!;
        expect(avg, inInclusiveRange(3.0, 4.6));

        // A reset (new round) starts the room over.
        demo.vote([
          several.copyWith(state: const {'open': true, 'round': 1}),
        ]);
        expect(demo.tallyOf('p1')!.people, 0);
      },
    );
  });

  group('Studio Preview as a viewer', () {
    test('your test vote joins the pretend totals and can change', () {
      final demo = StudioPreviewDemo(random: Random(1));
      addTearDown(demo.dispose);
      final e = _poll(type: 'several');
      demo.castVote(e, ['a1', 'a2']);
      expect(
        demo.tallyOf('p1'),
        const ElementTally({'a1': 1, 'a2': 1, 'a3': 0}, 1),
      );
      demo.castVote(e, ['a3'], previous: ['a1', 'a2']);
      expect(
        demo.tallyOf('p1'),
        const ElementTally({'a1': 0, 'a2': 0, 'a3': 1}, 1),
      );
      // A reset round starts from nothing.
      demo.castVote(e.copyWith(state: const {'open': true, 'round': 1}), [
        'a2',
      ]);
      expect(demo.tallyOf('p1')!.counts['a3'], 0);
    });

    testWidgets(
      'the host sees hidden totals, tagged; a viewer sees "Results soon"',
      (t) async {
        Widget at(ElementAudience a) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 640,
              height: 360,
              child: NileElementAngle(
                element: _poll(results: 'reveal'),
                interaction: ElementInteraction(tally: _tally, audience: a),
              ),
            ),
          ),
        );
        await t.pumpWidget(at(ElementAudience.staff));
        expect(find.text('60%'), findsOneWidget);
        expect(find.textContaining('Hidden from viewers'), findsOneWidget);
        await t.pumpWidget(at(ElementAudience.viewer));
        expect(find.text('60%'), findsNothing);
        expect(find.textContaining('Results soon'), findsOneWidget);
      },
    );
  });

  group('results page', () {
    testWidgets('answer text and people who voted', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ElementResults(
              elements: [_poll(type: 'several')],
              tallies: const {
                'p1': ElementTally({'a1': 4, 'a2': 3}, 5),
              },
            ),
          ),
        ),
      );
      expect(find.text('Red'), findsWidgets);
      expect(find.text('4 · 80%'), findsOneWidget);
      expect(find.textContaining('5 votes'), findsWidgets);
    });
  });

  testWidgets('"Poll is live" pill: vote or dismiss', (t) async {
    var voted = 0, dismissed = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PollLivePill(
            e: _poll(),
            onVote: () => voted++,
            onDismiss: () => dismissed++,
          ),
        ),
      ),
    );
    await t.tap(find.text('Poll is live'));
    await t.tap(find.byIcon(Icons.close));
    expect((voted, dismissed), (1, 1));
  });
}
