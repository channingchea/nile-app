import 'package:flutter_test/flutter_test.dart';
import 'package:nile_app/services/live_elements.dart';
import 'package:nile_app/services/livekit_service.dart' show CameraSlot;
import 'package:nile_app/services/overlay_layout.dart';
import 'package:nile_app/services/show_control.dart';
import 'package:nile_app/services/studio_graphics.dart';
import 'package:nile_app/services/studio_layouts.dart';

const now = 1000000;

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
const slate = StudioGraphic(
  id: 'slate',
  kind: GraphicKind.slate,
  name: 'Starting soon',
  payload: {'title': 'Starting soon'},
);
const counterLib = StudioElement(id: 'ctr', kind: 'counter', name: 'Count');

final graphicsLib = {
  for (final g in [logo, lower, slate]) g.id: g,
};
final elementsLib = {counterLib.id: counterLib};

LiveGraphic build(StudioGraphic g, int? autoHide) => LiveGraphic(
  id: g.id,
  kind: g.kind,
  title: g.payload['title'] as String?,
  corner: g.payload['corner'] as String?,
  hideAt: autoHide != null && autoHide > 0 ? now + autoHide * 1000 : null,
);

LiveGraphic live(StudioGraphic g) => build(g, null);

ResolvedLayout resolve(
  StudioLayout l, {
  List<String> positions = const ['a', 'b', 'c'],
  GraphicsState graphics = GraphicsState.empty,
  List<LiveElement> elements = const [],
  OverlayLayout overlay = OverlayLayout.empty,
  ShowControl show = ShowControl.empty,
}) => resolveLayout(
  l,
  positions: positions,
  graphicsLibrary: graphicsLib,
  elementsLibrary: elementsLib,
  build: build,
  graphics: graphics,
  elements: elements,
  overlay: overlay,
  show: show,
  nowMs: now,
);

void main() {
  group('model', () {
    test('payload round-trips', () {
      const l = StudioLayout(
        name: 'Main',
        cameras: [
          LayoutCamera(
            items: [
              LayoutItem.graphic('lt', spot: LayoutSpot.bl, autoHide: 8),
              LayoutItem.element('ctr', hidden: true),
            ],
          ),
          LayoutCamera(onAir: false),
        ],
        angles: ['ctr'],
        defaultAngle: AngleRef.camera(2),
        order: [
          AngleRef.camera(2),
          AngleRef.camera(1),
          AngleRef.element('ctr'),
        ],
      );
      final back = StudioLayout.fromPayload(l.payload, name: 'Main');
      expect(back, l);
      expect(back.refs, {'lt', 'ctr'});
    });

    test('junk in the payload is dropped, not thrown', () {
      final l = StudioLayout.fromPayload({
        'cameras': [
          {
            'items': [
              {'g': 'x', 'spot': 'nowhere', 'autoHide': -3},
              {'nope': 1},
              7,
            ],
          },
          'junk',
        ],
        'defaultAngle': {'cam': 0},
        'order': [
          {'el': ''},
          {'cam': 1},
        ],
      }, name: 'x');
      expect(l.cameras.length, 2);
      expect(l.cameras[0].items, [const LayoutItem.graphic('x')]);
      expect(l.defaultAngle, isNull);
      expect(l.order, [const AngleRef.camera(1)]);
    });

    test('validation', () {
      expect(
        const StudioLayout(name: ' ', cameras: [LayoutCamera()]).error,
        isNotNull,
      );
      expect(const StudioLayout(name: 'A').error, isNotNull);
      expect(
        const StudioLayout(name: 'A', cameras: [LayoutCamera()]).error,
        isNull,
      );
      final huge = StudioLayout(
        name: 'Big',
        cameras: [
          LayoutCamera(
            items: [
              for (var i = 0; i < 400; i++)
                LayoutItem.graphic(
                  '00000000-0000-0000-0000-${'$i'.padLeft(12, '0')}',
                ),
            ],
          ),
        ],
      );
      expect(huge.error, 'This layout is too big to save.');
    });

    test('positions follow creation order, not display order', () {
      expect(
        positionsOf(const [
          CameraSlot(id: 'c', slotIndex: 3, label: 'C'),
          CameraSlot(id: 'a', slotIndex: 1, label: 'A'),
          CameraSlot(id: 'b', slotIndex: 2, label: 'B'),
        ]),
        ['a', 'b', 'c'],
      );
    });
  });

  group('resolve', () {
    test('items land on the camera at their position', () {
      const l = StudioLayout(
        name: 'L',
        cameras: [
          LayoutCamera(items: [LayoutItem.graphic('logo')]),
          LayoutCamera(
            items: [LayoutItem.graphic('lt', spot: LayoutSpot.tl)],
            onAir: false,
          ),
        ],
      );
      final r = resolve(l);
      expect(r.covered, ['a', 'b']);
      expect(r.graphics.forSlot('a', nowMs: now).map((g) => g.id), ['logo']);
      expect(r.graphics.forSlot('b', nowMs: now).map((g) => g.id), ['lt']);
      expect(r.graphics.forSlot('c', nowMs: now), isEmpty);
      expect(r.overlay.layersFor('b'), [
        const LayerEntry('lt', spot: LayoutSpot.tl),
      ]);
      expect(r.show.offAir, {'b'});
      expect(r.missing, isEmpty);
    });

    test('a graphic on every camera goes on as "All cameras"', () {
      const cam = LayoutCamera(items: [LayoutItem.graphic('logo')]);
      final r = resolve(
        const StudioLayout(name: 'L', cameras: [cam, cam]),
        positions: ['a', 'b'],
      );
      expect(r.graphics.targetsOf('logo'), const GraphicTargets.all());
    });

    test('extra cameras keep everything; covered cameras are replaced', () {
      final before = const GraphicsState()
          .withTargets(live(logo), const GraphicTargets.all())
          .withOn('c', live(lower));
      final r = resolve(
        const StudioLayout(
          name: 'L',
          cameras: [
            LayoutCamera(items: [LayoutItem.graphic('slate')]),
            LayoutCamera(),
          ],
        ),
        graphics: before,
        overlay: const OverlayLayout().withLayers('c', const [
          LayerEntry('lt', spot: LayoutSpot.tc),
        ]),
        show: const ShowControl(offAir: {'a', 'c'}),
      );
      expect(r.graphics.forSlot('a', nowMs: now).map((g) => g.id), ['slate']);
      expect(r.graphics.forSlot('b', nowMs: now), isEmpty);
      expect(r.graphics.forSlot('c', nowMs: now).map((g) => g.id).toSet(), {
        'logo',
        'lt',
      });
      expect(
        r.graphics.targetsOf('logo'),
        const GraphicTargets.all(except: {'a', 'b'}),
      );
      expect(r.overlay.layersFor('c'), [
        const LayerEntry('lt', spot: LayoutSpot.tc),
      ]);
      expect(r.show.offAir, {'c'});
    });

    test('a graphic gone from every camera comes off entirely', () {
      final r = resolve(
        const StudioLayout(
          name: 'L',
          cameras: [LayoutCamera(), LayoutCamera()],
        ),
        positions: ['a', 'b'],
        graphics: const GraphicsState().withTargets(
          live(logo),
          const GraphicTargets.all(),
        ),
      );
      expect(r.graphics.isEmpty, isTrue);
    });

    test('a graphic already up keeps its live value', () {
      final running = LiveGraphic(
        id: 'slate',
        kind: GraphicKind.slate,
        title: 'Starting soon',
        endsAt: now + 60000,
      );
      final r = resolve(
        const StudioLayout(
          name: 'L',
          cameras: [
            LayoutCamera(items: [LayoutItem.graphic('slate')]),
            LayoutCamera(items: [LayoutItem.graphic('slate')]),
          ],
        ),
        graphics: const GraphicsState().withOn('a', running),
      );
      for (final s in ['a', 'b']) {
        expect(r.graphics.forSlot(s, nowMs: now).single.endsAt, now + 60000);
      }
      expect(
        r.graphics.targetsOf('slate'),
        const GraphicTargets.only({'a', 'b'}),
      );
    });

    test('auto-hide override is used for a fresh graphic', () {
      final r = resolve(
        const StudioLayout(
          name: 'L',
          cameras: [
            LayoutCamera(items: [LayoutItem.graphic('lt', autoHide: 5)]),
          ],
        ),
      );
      expect(r.graphics.forSlot('a', nowMs: now).single.hideAt, now + 5000);
    });

    test('fewer cameras than the layout: the rest is skipped', () {
      const cam = LayoutCamera(items: [LayoutItem.graphic('logo')]);
      final r = resolve(
        const StudioLayout(name: 'L', cameras: [cam, cam, cam, cam]),
        positions: ['a', 'b'],
      );
      expect(r.covered, ['a', 'b']);
      expect(r.skippedCameras, 2);
    });

    test('deleted items are skipped and listed', () {
      final r = resolve(
        const StudioLayout(
          name: 'L',
          cameras: [
            LayoutCamera(
              items: [
                LayoutItem.graphic('gone'),
                LayoutItem.graphic('logo'),
                LayoutItem.element('gone-el'),
              ],
            ),
            LayoutCamera(items: [LayoutItem.graphic('gone')]),
          ],
          angles: ['gone-el'],
        ),
      );
      expect(r.graphics.forSlot('a', nowMs: now).map((g) => g.id), ['logo']);
      expect(r.overlay.layersFor('a'), [const LayerEntry('logo')]);
      expect(r.missing.length, 4);
      expect(r.missingCount, 2);
      expect(r.missing.last.camera, isNull);
    });

    test('a deleted library item still on air is not missing', () {
      const orphan = LiveGraphic(
        id: 'old',
        kind: GraphicKind.banner,
        text: 'Hi',
      );
      final r = resolve(
        const StudioLayout(
          name: 'L',
          cameras: [
            LayoutCamera(items: [LayoutItem.graphic('old')]),
            LayoutCamera(items: [LayoutItem.graphic('old')]),
          ],
        ),
        graphics: const GraphicsState().withOn('c', orphan),
      );
      expect(r.missing, isEmpty);
      expect(r.graphics.targetsOf('old'), const GraphicTargets.all());
    });

    test(
      'elements: live ones keep state, new ones start fresh, others come off',
      () {
        const poll = LiveElement(
          id: 'poll',
          kind: 'counter',
          name: 'Old',
          state: {'value': 7},
          targets: GraphicTargets.all(),
          angle: true,
        );
        final r = resolve(
          const StudioLayout(
            name: 'L',
            cameras: [
              LayoutCamera(
                items: [LayoutItem.element('ctr', spot: LayoutSpot.br)],
              ),
            ],
            angles: ['ctr'],
          ),
          elements: [poll],
          show: const ShowControl(offAir: {'el:poll'}, defaultSlot: 'el:poll'),
        );
        final byId = {for (final e in r.elements) e.id: e};
        expect(byId['ctr']!.targets, const GraphicTargets.only({'a'}));
        expect(byId['ctr']!.angle, isTrue);
        expect(byId['ctr']!.state, ElementKinds.counter.defaultState);
        expect(byId['poll']!.targets, const GraphicTargets.only({'b', 'c'}));
        expect(byId['poll']!.angle, isFalse);
        expect(byId['poll']!.state, {'value': 7});
        expect(r.show.offAir, isEmpty);
        // No default in the layout → the first on-air camera.
        expect(r.show.defaultSlot, isNull);
        expect(r.overlay.layersFor('a'), [
          const LayerEntry('ctr', spot: LayoutSpot.br),
        ]);
      },
    );

    test('an element already where the layout wants it is not resent', () {
      const ctr = LiveElement(
        id: 'ctr',
        kind: 'counter',
        name: 'Count',
        targets: GraphicTargets.only({'a'}),
      );
      final r = resolve(
        const StudioLayout(
          name: 'L',
          cameras: [
            LayoutCamera(items: [LayoutItem.element('ctr')]),
          ],
        ),
        elements: [ctr],
      );
      expect(r.elements, isEmpty);
    });

    test('default angle and order map positions to slots', () {
      final r = resolve(
        const StudioLayout(
          name: 'L',
          cameras: [LayoutCamera(), LayoutCamera()],
          angles: ['ctr'],
          defaultAngle: AngleRef.camera(2),
          order: [
            AngleRef.element('ctr'),
            AngleRef.camera(2),
            AngleRef.camera(9),
          ],
        ),
        show: const ShowControl(slotOrder: ['c', 'a', 'b'], defaultSlot: 'c'),
      );
      expect(r.show.defaultSlot, 'b');
      expect(r.show.slotOrder, ['el:ctr', 'b', 'c', 'a']);
    });

    test('a default the show can’t meet keeps the current one', () {
      final r = resolve(
        const StudioLayout(
          name: 'L',
          cameras: [LayoutCamera()],
          defaultAngle: AngleRef.camera(5),
        ),
        show: const ShowControl(defaultSlot: 'c'),
      );
      expect(r.show.defaultSlot, 'c');
      expect(r.show.slotOrder, isEmpty);
    });
  });

  group('snapshot', () {
    test('save current look → apply restores the same show', () {
      final graphics = const GraphicsState()
          .withTargets(live(logo), const GraphicTargets.all(except: {'c'}))
          .withOn('b', live(lower))
          .withOn(
            'c',
            const LiveGraphic(
              id: 'chat:1',
              kind: GraphicKind.chat,
              title: 'sam',
              text: 'hi',
            ),
          );
      const ctr = LiveElement(
        id: 'ctr',
        kind: 'counter',
        name: 'Count',
        targets: GraphicTargets.only({'a', 'c'}),
        angle: true,
      );
      final overlay = const OverlayLayout().withLayers('a', const [
        LayerEntry('logo', spot: LayoutSpot.tl, hidden: true),
        LayerEntry('ctr', spot: LayoutSpot.bc),
      ]);
      const show = ShowControl(
        offAir: {'b'},
        defaultSlot: 'el:ctr',
        slotOrder: ['c', 'el:ctr', 'a', 'b'],
      );
      final snap = snapshotLayout(
        name: 'Now',
        positions: const ['a', 'b', 'c'],
        libraryGraphics: graphicsLib.keys.toSet(),
        libraryElements: elementsLib.keys.toSet(),
        graphics: graphics,
        elements: const [ctr],
        overlay: overlay,
        show: show,
        nowMs: now,
      );
      expect(snap.leftOut, ['sam']);
      final l = snap.layout;
      expect(l.cameras.length, 3);
      expect(l.cameras[0].items, const [
        LayoutItem.graphic('logo', spot: LayoutSpot.tl, hidden: true),
        LayoutItem.element('ctr', spot: LayoutSpot.bc),
      ]);
      expect(l.cameras[1].onAir, isFalse);
      expect(l.defaultAngle, const AngleRef.element('ctr'));
      expect(l.order.first, const AngleRef.camera(3));

      // Applied to an empty show with the same cameras.
      final r = resolve(l);
      for (final s in ['a', 'b']) {
        expect(
          r.graphics.forSlot(s, nowMs: now).map((g) => g.id).toSet(),
          graphics.forSlot(s, nowMs: now).map((g) => g.id).toSet(),
        );
      }
      expect(r.graphics.forSlot('c', nowMs: now), isEmpty); // chat left out
      expect(r.elements.single.targets, ctr.targets);
      expect(r.elements.single.angle, isTrue);
      expect(r.show.offAir, show.offAir);
      expect(r.show.defaultSlot, show.defaultSlot);
      expect(r.show.slotOrder, show.slotOrder);
      expect(r.overlay.layersFor('a'), overlay.layersFor('a'));
    });

    test('reordering cameras does not shift positions', () {
      final graphics = const GraphicsState().withOn('a', live(lower));
      final first = snapshotLayout(
        name: 'x',
        positions: const ['a', 'b'],
        libraryGraphics: {'lt'},
        libraryElements: const {},
        graphics: graphics,
        show: const ShowControl(slotOrder: ['b', 'a']),
      ).layout;
      // Camera 1 is still slot a, though it is shown second.
      expect(first.cameras[0].items, const [LayoutItem.graphic('lt')]);
      final r = resolve(first, positions: const ['a', 'b']);
      expect(r.graphics.targetsOf('lt'), const GraphicTargets.only({'a'}));
      expect(r.show.slotOrder, ['b', 'a']);
    });

    test('expired graphics are not saved', () {
      final graphics = const GraphicsState().withOn(
        'a',
        LiveGraphic(id: 'lt', kind: GraphicKind.lowerThird, hideAt: now - 1),
      );
      final l = snapshotLayout(
        name: 'x',
        positions: const ['a'],
        libraryGraphics: {'lt'},
        libraryElements: const {},
        graphics: graphics,
        nowMs: now,
      ).layout;
      expect(l.cameras.single.items, isEmpty);
    });
  });
}
