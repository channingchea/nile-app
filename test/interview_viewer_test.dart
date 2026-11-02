// Interview viewers (docs/plans/studio-modes.md, phase 5): what a ticket
// holder pulls, sees and can tap on an Interview show.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nile_app/services/interview.dart';
import 'package:nile_app/services/interview_viewer.dart';
import 'package:nile_app/widgets/stage_profile_sheet.dart';

StageState _stage(List<(String, int)> ids, {String? content}) =>
    StageState.fromJson({
      'ids': [
        for (final (id, at) in ids) {'id': id, 'at': at},
      ],
      'layout': 'grid',
      'content': ?content,
    });

const _roles = <String, String?>{
  'guest-a': 'guest',
  'guest-b': 'guest',
  'cam-1': 'camera',
  'studio-1': 'studio',
  'audio-1': 'master-audio',
  'backstage-e': 'backstage',
};

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: child), debugShowCheckedModeBanner: false);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  group('content angle', () {
    test('parses a screen share and an element angle', () {
      expect(
        ContentAngle.parse('guest-a#share'),
        const ContentAngle.share('guest-a'),
      );
      expect(
        ContentAngle.parse('el:poll1'),
        const ContentAngle.element('poll1'),
      );
      for (final bad in [null, '', '#share', 'el:', 'guest-a']) {
        expect(ContentAngle.parse(bad), isNull, reason: '$bad');
      }
    });

    test('angle list: stage alone, or stage + content', () {
      expect(interviewAngles(null), [null]);
      expect(interviewAngles('guest-a#share'), [
        null,
        const ContentAngle.share('guest-a'),
      ]);
      expect(interviewAngles('el:x', hasElement: (_) => true), [
        null,
        const ContentAngle.element('x'),
      ]);
      // The element was taken off: only the stage is offered.
      expect(interviewAngles('el:x', hasElement: (_) => false), [null]);
    });
  });

  group('stage lineup + countdowns', () {
    final stage = _stage([
      ('guest-a', 1000),
      ('cam-1', 0),
      ('guest-b', 5000),
      ('backstage-e', 0),
      ('gone', 0),
    ]);

    test('only those whose countdown ran out and who are in the room', () {
      expect(stageLineup(stage, 999, present: _roles), ['cam-1']);
      expect(stageLineup(stage, 1000, present: _roles), ['guest-a', 'cam-1']);
      expect(stageLineup(stage, 6000, present: _roles), [
        'guest-a',
        'cam-1',
        'guest-b',
      ]);
    });

    test('wakes at the next countdown, then not at all', () {
      expect(nextStageReveal(stage, 0), 1000);
      expect(nextStageReveal(stage, 1000), 4000);
      expect(nextStageReveal(stage, 5000), isNull);
      expect(nextStageReveal(StageState.empty, 0), isNull);
    });
  });

  group('stageFeeds', () {
    final stage = _stage([
      ('guest-a', 0),
      ('cam-1', 0),
      ('studio-1', 0),
      ('guest-b', 9000), // still counting down
      ('backstage-e', 0),
    ]);
    List<String> visible(int now) => stageLineup(stage, now, present: _roles);

    test('video for everyone on stage, countdowns included', () {
      final f = stageFeeds(
        stage: stage,
        visible: visible(0),
        roles: _roles,
        masterAudio: 'audio-1',
      );
      expect(f.video, {'guest-a', 'cam-1', 'studio-1', 'guest-b'});
      expect(f.share, isNull);
    });

    test('audio: master + visible guests; crew phones stay silent', () {
      final f = stageFeeds(
        stage: stage,
        visible: visible(0),
        roles: _roles,
        masterAudio: 'audio-1',
      );
      expect(f.audio, {'audio-1', 'guest-a'});
      final later = stageFeeds(
        stage: stage,
        visible: visible(9000),
        roles: _roles,
        masterAudio: 'audio-1',
      );
      expect(later.audio, {'audio-1', 'guest-a', 'guest-b'});
    });

    test('a crew phone carrying the master audio is heard', () {
      final f = stageFeeds(
        stage: stage,
        visible: visible(0),
        roles: _roles,
        masterAudio: 'cam-1',
      );
      expect(f.audio, {'cam-1', 'guest-a'});
    });

    test('muted viewer: no audio, video unchanged', () {
      final f = stageFeeds(
        stage: stage,
        visible: visible(0),
        roles: _roles,
        masterAudio: 'audio-1',
        audioOn: false,
      );
      expect(f.audio, isEmpty);
      expect(f.video, isNotEmpty);
    });

    test('never the backstage connection, even if listed', () {
      final f = stageFeeds(
        stage: _stage([('backstage-e', 0)], content: 'backstage-e#share'),
        visible: const ['backstage-e'],
        roles: _roles,
        masterAudio: 'backstage-e',
      );
      expect(f.video, isEmpty);
      expect(f.audio, isEmpty);
      expect(f.share, isNull);
    });

    test('the content share is pulled; an element angle pulls nothing', () {
      expect(
        stageFeeds(
          stage: _stage([('guest-a', 0)], content: 'guest-a#share'),
          visible: const ['guest-a'],
          roles: _roles,
        ).share,
        'guest-a',
      );
      expect(
        stageFeeds(
          stage: _stage([('guest-a', 0)], content: 'el:x'),
          visible: const ['guest-a'],
          roles: _roles,
        ).share,
        isNull,
      );
    });
  });

  group('stagePersonOf', () {
    test('a guest is their own profile', () {
      final p = stagePersonOf('guest-u1', {
        'role': 'guest',
        'userId': 'u1',
        'displayName': 'Ada',
        'username': 'ada',
        'title': 'Producer',
      });
      expect(p.kind, StagePersonKind.guest);
      expect(
        (p.name, p.username, p.title, p.userId),
        ('Ada', 'ada', 'Producer', 'u1'),
      );
      expect(p.hasProfile, isTrue);
    });

    test('the Studio is the host', () {
      final p = stagePersonOf(
        'studio-1',
        {'role': 'studio'},
        hostId: 'h1',
        hostName: 'Hosty',
        hostUsername: 'hosty',
      );
      expect(p.kind, StagePersonKind.host);
      expect((p.name, p.userId, p.title), ('Hosty', 'h1', 'Host'));
    });

    test('a crew phone has its camera name and no profile', () {
      final p = stagePersonOf('cam-1', {
        'role': 'camera',
        'cameraName': 'Wide',
      });
      expect(
        (p.kind, p.name, p.hasProfile),
        (StagePersonKind.crew, 'Wide', false),
      );
      expect(stagePersonOf('cam-2', {'role': 'camera'}).name, 'Camera');
    });
  });

  group('avatar strip + profile sheet', () {
    const guest = StagePerson(
      identity: 'guest-u1',
      kind: StagePersonKind.guest,
      name: 'Ada',
      title: 'Producer',
      userId: 'u1',
      username: 'ada',
    );
    const crew = StagePerson(
      identity: 'cam-1',
      kind: StagePersonKind.crew,
      name: 'Wide',
    );

    testWidgets('lists everyone; only people with a profile are tappable', (
      tester,
    ) async {
      final tapped = <String>[];
      await tester.pumpWidget(
        _wrap(
          StagePeopleStrip(
            people: const [guest, crew],
            onTap: (p) => tapped.add(p.identity),
          ),
        ),
      );
      expect(find.text('Ada'), findsOneWidget);
      expect(find.text('Producer'), findsOneWidget);
      expect(find.text('Wide'), findsOneWidget);
      await tester.tap(find.text('Wide'));
      await tester.tap(find.text('Ada'));
      expect(tapped, ['guest-u1']);
    });

    testWidgets('side column fits a narrow rail', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 110,
            child: StagePeopleStrip(
              people: const [guest, crew],
              onTap: (_) {},
              vertical: true,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('follow, then view profile', (tester) async {
      final follows = <bool>[];
      var viewed = false;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showStageProfileSheet(
                context,
                person: guest,
                isFollowing: () async => false,
                onFollow: (f) async => follows.add(f),
                onViewProfile: () => viewed = true,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('@ada'), findsOneWidget);
      await tester.tap(find.text('Follow'));
      await tester.pump();
      expect(follows, [true]);
      expect(find.text('Following'), findsOneWidget);
      await tester.tap(find.text('View profile'));
      await tester.pumpAndSettle();
      expect(viewed, isTrue);
      // The sheet closes; the show underneath is still there.
      expect(find.text('@ada'), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('no follow button when following isn\'t possible', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(StageProfileSheet(person: guest, onViewProfile: () {})),
      );
      expect(find.text('Follow'), findsNothing);
      expect(find.text('View profile'), findsOneWidget);
    });
  });
}
