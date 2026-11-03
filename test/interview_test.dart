// Interview mode core (docs/plans/studio-modes.md, phases 2-5): the stage
// metadata, the layout maths shared with the replay recorder, guest rows and
// the green room column.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nile_app/services/backstage.dart';
import 'package:nile_app/services/interview.dart';
import 'package:nile_app/widgets/interview_green_room.dart';
import 'package:nile_app/widgets/interview_stage.dart';

/// Rect stores right/bottom, so width/height pick up float noise.
double _r4(double v) => (v * 10000).roundToDouble() / 10000;
List<List<double>> rects(List<StageSlot> s) => [
  for (final x in s)
    [_r4(x.rect.left), _r4(x.rect.top), _r4(x.rect.width), _r4(x.rect.height)],
];

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: child), debugShowCheckedModeBanner: false);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  group('stageSlots (same numbers as recorder/recorder_test.js)', () {
    test('empty, one, solo', () {
      expect(stageSlots(StageLayout.grid, 0), isEmpty);
      expect(rects(stageSlots(StageLayout.grid, 1)), [
        [0, 0, 1, 1],
      ]);
      final solo = stageSlots(StageLayout.solo, 3, focusIndex: 2);
      expect(solo.single.index, 2);
      expect(rects(solo), [
        [0, 0, 1, 1],
      ]);
    });

    test('side by side', () {
      expect(rects(stageSlots(StageLayout.side, 2)), [
        [0, 0, 0.495, 1],
        [0.505, 0, 0.495, 1],
      ]);
    });

    test('grid centres the last row', () {
      expect(rects(stageSlots(StageLayout.grid, 3)), [
        [0, 0, 0.495, 0.4911],
        [0.505, 0, 0.495, 0.4911],
        [0.2525, 0.5089, 0.495, 0.4911],
      ]);
    });

    test('spotlight features the focus', () {
      final s = stageSlots(StageLayout.spotlight, 3, focusIndex: 1);
      expect([for (final x in s) x.index], [1, 0, 2]);
      expect(rects(s), [
        [0, 0, 0.75, 1],
        [0.76, 0, 0.24, 0.4911],
        [0.76, 0.5089, 0.24, 0.4911],
      ]);
    });

    test('every layout stays in frame and shows everyone (bar Solo)', () {
      for (final l in StageLayout.values) {
        for (var n = 1; n <= kStageMax; n++) {
          final s = stageSlots(l, n);
          expect(s.length, l == StageLayout.solo ? 1 : n);
          for (final x in s) {
            expect(x.rect.left >= 0 && x.rect.top >= 0, isTrue);
            expect(x.rect.right <= 1.0001 && x.rect.bottom <= 1.0001, isTrue);
          }
          expect({for (final x in s) x.index}.length, s.length);
        }
      }
    });
  });

  group('StageState', () {
    test('reads room metadata, dropping junk', () {
      final s = StageState.fromRoomMetadata(
        '{"stage":{"ids":[{"id":"a","at":1},{"id":"a","at":2},{"id":3},'
        '{"id":"b","at":5000}],"layout":"spotlight","focus":"b",'
        '"content":"el:x"}}',
      );
      expect(s.ids, ['a', 'b']);
      expect(s.layout, StageLayout.spotlight);
      expect(s.focus, 'b');
      expect(s.content, 'el:x');
      expect(StageState.fromRoomMetadata('{}'), StageState.empty);
      expect(StageState.fromRoomMetadata('nope'), StageState.empty);
      expect(
        StageState.fromRoomMetadata('{"stage":{"layout":"pip","focus":"z"}}'),
        StageState.empty,
      );
    });

    test('countdowns and who is visible', () {
      const s = StageState(
        entries: [StageEntry('a', 0), StageEntry('b', 5000)],
        focus: 'b',
      );
      expect(s.visibleAt(1000), ['a']);
      expect(s.countdownFor('b', 1000), 4);
      expect(s.countdownFor('b', 4001), 1);
      expect(s.countdownFor('b', 5000), isNull);
      expect(s.countdownFor('a', 1000), isNull);
      expect(s.focusIndexIn(['a']), 0);
      expect(s.focusIndexIn(['a', 'b']), 1);
    });
  });

  test('guest identities and rows', () {
    expect(guestUserIdOf(guestIdentity('u1')), 'u1');
    expect(guestUserIdOf('studio-x'), isNull);
    final g = InterviewGuest.fromRow({
      'id': 'r1',
      'user_id': 'u1',
      'status': 'green_room',
      'title': 'Director',
      'profiles': {'username': 'ava', 'display_name': '', 'avatar_url': null},
    });
    expect(g.identity, 'guest-u1');
    expect(g.name, 'ava');
    expect(g.status, GuestStatus.greenRoom);
    expect(GuestStatus.fromWire('junk'), GuestStatus.invited);
    final meta = GuestMeta.fromJson({
      'role': 'guest',
      'userId': 'u1',
      'displayName': 'Ava',
      'status': 'on_stage',
    });
    expect(meta?.status, GuestStatus.onStage);
    expect(GuestMeta.fromJson({'role': 'camera', 'userId': 'u1'}), isNull);
  });

  test('only crew, the Studio and guests are behind the scenes', () {
    expect(kBackstageRoles, containsAll(['camera', 'studio', 'guest']));
    expect(kBackstageRoles.contains('viewer'), isFalse);
    expect(kBackstageRoles.contains('backstage'), isFalse);
  });

  group('green room column', () {
    GreenRoomEntry e(
      String id,
      GuestStatus s, {
      GreenRoomKind k = GreenRoomKind.guest,
    }) => GreenRoomEntry(identity: id, name: id, kind: k, status: s);

    testWidgets('sections, the 6 count, and Bring on / Send back', (t) async {
      final brought = <String>[], sent = <String>[];
      await t.binding.setSurfaceSize(const Size(232, 1400));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        _wrap(
          InterviewGreenRoomColumn(
            entries: [
              e('host', GuestStatus.onStage, k: GreenRoomKind.host),
              e('ava', GuestStatus.greenRoom),
              e('ben', GuestStatus.invited),
            ],
            actions: GreenRoomActions(
              onBringOn: (x) => brought.add(x.identity),
              onSendBack: (x) => sent.add(x.identity),
            ),
          ),
        ),
      );
      expect(t.takeException(), isNull);
      expect(find.text('ON STAGE 1/$kStageMax'), findsOneWidget);
      expect(find.text('WAITING'), findsOneWidget);
      expect(find.text('INVITED'), findsOneWidget);
      await t.tap(find.text('Bring on'));
      await t.tap(find.text('Send back'));
      expect(brought, ['ava']);
      expect(sent, ['host']);
    });

    testWidgets('link requests sit on top with Let in / Decline', (t) async {
      final admitted = <String>[], declined = <String>[];
      await t.binding.setSurfaceSize(const Size(232, 1400));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        _wrap(
          InterviewGreenRoomColumn(
            entries: [
              e('host', GuestStatus.onStage, k: GreenRoomKind.host),
              const GreenRoomEntry(
                identity: 'cy',
                name: 'Cy',
                title: '@cy',
                kind: GreenRoomKind.guest,
                status: GuestStatus.requested,
              ),
            ],
            actions: GreenRoomActions(
              onAdmit: (x) => admitted.add(x.identity),
              onDecline: (x) => declined.add(x.identity),
            ),
          ),
        ),
      );
      expect(t.takeException(), isNull);
      expect(find.text('ASKING TO JOIN 1'), findsOneWidget);
      expect(find.text('@cy · Asked to join'), findsOneWidget);
      expect(
        t.getTopLeft(find.text('ASKING TO JOIN 1')).dy,
        lessThan(t.getTopLeft(find.text('ON STAGE 1/$kStageMax')).dy),
      );
      expect(find.text('Bring on'), findsNothing);
      await t.tap(find.text('Let in'));
      await t.tap(find.text('Decline'));
      expect(admitted, ['cy']);
      expect(declined, ['cy']);
    });

    test('requested parses from the wire', () {
      expect(GuestStatus.fromWire('requested'), GuestStatus.requested);
    });

    testWidgets('a full stage disables Bring on', (t) async {
      final brought = <String>[];
      await t.binding.setSurfaceSize(const Size(232, 3000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        _wrap(
          InterviewGreenRoomColumn(
            entries: [
              for (var i = 0; i < kStageMax; i++) e('p$i', GuestStatus.onStage),
              e('ava', GuestStatus.greenRoom),
            ],
            actions: GreenRoomActions(
              onBringOn: (x) => brought.add(x.identity),
              onSendBack: (_) {},
            ),
          ),
        ),
      );
      await t.tap(find.text('Bring on'));
      expect(brought, isEmpty);
    });
  });

  testWidgets('stage view: name tags, countdown, no overflow in a small box', (
    t,
  ) async {
    await t.pumpWidget(
      _wrap(
        const SizedBox(
          width: 320,
          child: InterviewStageView(
            layout: StageLayout.grid,
            tiles: [
              StageTile(identity: 'a', name: 'Ava', title: 'Director'),
              StageTile(identity: 'b', name: 'Ben', countdown: 3),
              StageTile(identity: 'c', name: 'Cy', muted: true),
            ],
          ),
        ),
      ),
    );
    expect(t.takeException(), isNull);
    expect(find.text('Ava'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(formatStageTime(const Duration(minutes: 12, seconds: 4)), '12:04');
  });
}
