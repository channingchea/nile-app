// Grid replays (studio live elements, phase 6): the overlay timeline the
// recorder page reports, and drawing it over the right tiles.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nile_app/services/overlay_clock.dart';
import 'package:nile_app/services/replay_timeline.dart';
import 'package:nile_app/services/studio_graphics.dart';
import 'package:nile_app/widgets/nile_graphics_layer.dart';
import 'package:nile_app/widgets/replay_grid_overlay.dart';

const _start = 1800000000000;

Map<String, Object?> _meta({
  List<Map<String, Object?>> bySlotB = const [],
  bool angle = false,
}) => {
  'graphics': {
    'all': <Object?>[],
    'bySlot': {'b': bySlotB},
  },
  'elements': {
    'items': [
      if (angle)
        {
          'id': 'e1',
          'kind': 'counter',
          'name': 'Goals',
          'config': {'label': 'Goals', 'step': 1},
          'state': {'value': 3},
          'angle': true,
          'version': 1,
        },
    ],
  },
};

const _lt = {'id': 'lt', 'kind': 'lower_third', 'title': 'Jane'};

final _marks = <Object?>[
  {
    'o': 0,
    'k': 'start',
    'd': {'wall': _start},
  },
  {
    'o': 0,
    'k': 'tiles',
    'd': [
      {
        's': 'a',
        'el': null,
        'r': [0, 0.25, 0.5, 0.5],
      },
      {
        's': 'b',
        'el': null,
        'r': [0.5, 0.25, 0.5, 0.5],
      },
    ],
  },
  {'o': 0, 'k': 'meta', 'd': _meta()},
  {
    'o': 4000,
    'k': 'meta',
    'd': _meta(bySlotB: [_lt]),
  },
  {
    'o': 6000,
    'k': 'tally',
    'd': {
      'elementId': 'e1',
      'tally': {'up': 2, 'down': 1},
    },
  },
  {
    'o': 9000,
    'k': 'tiles',
    'd': [
      {
        's': null,
        'el': 'e1',
        'r': [0, 0, 1, 1],
      },
    ],
  },
  {'o': 9000, 'k': 'meta', 'd': _meta(angle: true)},
  {'o': 9500, 'k': 'bogus', 'd': {}},
  {'k': 'meta', 'd': {}},
];

void main() {
  group('ReplayTimeline', () {
    final t = ReplayTimeline.fromMarks(_marks);

    test('each moment gets the latest of everything', () {
      expect(t.startWall, _start);
      expect(t.wallAt(1500), _start + 1500);

      final early = t.frameAt(1000);
      expect(early.tiles.map((x) => x.slot), ['a', 'b']);
      expect(early.tiles.last.rect, const Rect.fromLTWH(0.5, 0.25, 0.5, 0.5));
      expect(early.graphics.forSlot('b'), isEmpty);
      expect(early.tallies, isEmpty);

      final mid = t.frameAt(7000);
      expect(mid.graphics.forSlot('b').single.title, 'Jane');
      expect(mid.graphics.forSlot('a'), isEmpty);
      expect(mid.tallies['e1'], {'up': 2, 'down': 1});

      final late = t.frameAt(9000);
      expect(late.tiles.single.elementId, 'e1');
      expect(late.elements.byId('e1')?.angle, isTrue);
    });

    test('before anything was reported, and with no marks at all', () {
      expect(ReplayTimeline.fromMarks(const []).isEmpty, isTrue);
      expect(ReplayTimeline.fromMarks(const []).frameAt(0).tiles, isEmpty);
      expect(ReplayTimeline.fromMarks(const []).wallAt(5), isNull);
    });
  });

  group('ReplayGridOverlay', () {
    Future<void> pump(WidgetTester tester, Widget child) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 1600, height: 900, child: child),
          ),
        ),
      );
    }

    testWidgets('a camera graphic lands on its own tile, nothing else', (
      tester,
    ) async {
      final frame = ReplayTimeline.fromMarks(_marks).frameAt(5000);
      await pump(tester, ReplayGridOverlay(frame: frame));
      expect(find.byType(NileGraphicsLayer), findsNWidgets(2));
      final jane = tester.getCenter(find.text('Jane'));
      // Tile b = right half, vertically centred band.
      expect(jane.dx, greaterThan(800));
      expect(jane.dy, inInclusiveRange(225, 675));
      // Nothing in a replay takes taps.
      expect(
        find.ancestor(
          of: find.byType(NileGraphicsLayer).first,
          matching: find.byType(IgnorePointer),
        ),
        findsWidgets,
      );
    });

    testWidgets('an element angle tile draws the element full size', (
      tester,
    ) async {
      await pump(
        tester,
        ReplayGridOverlay(
          frame: ReplayTimeline.fromMarks(_marks).frameAt(9100),
        ),
      );
      expect(find.byType(NileElementAngle), findsOneWidget);
      expect(find.byType(NileGraphicsLayer), findsNothing);
    });

    testWidgets('auto-hides follow the recording clock, not today', (
      tester,
    ) async {
      final graphics = [
        const LiveGraphic(
          id: 'gone',
          kind: GraphicKind.lowerThird,
          title: 'Gone',
          hideAt: _start + 1000,
        ),
        const LiveGraphic(
          id: 'up',
          kind: GraphicKind.banner,
          text: 'Up',
          hideAt: _start + 60000,
        ),
      ];
      await pump(
        tester,
        OverlayClock(
          now: () => _start + 5000,
          child: NileGraphicsLayer(graphics: graphics),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Gone'), findsNothing);
      expect(find.textContaining('Up'), findsWidgets);
    });
  });
}
