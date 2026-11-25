import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nile_app/services/film_sync.dart';
import 'package:nile_app/widgets/premiere_panel.dart';
import 'package:nile_app/widgets/premiere_widgets.dart';

const min = 60 * 1000;

void main() {
  group('the film clock', () {
    test('playing advances, paused holds, the end rolls into post-show', () {
      const f = FilmState(
        phase: FilmPhase.playing,
        pos: 10000,
        at: 1000,
        dur: 90 * min,
      );
      expect(f.nowAt(6000).pos, 15000);
      expect(f.nowAt(6000).showingFilm, isTrue);
      final end = f.nowAt(1000 + 90 * min);
      expect(end.phase, FilmPhase.ended);
      expect(end.pos, 90 * min);
      expect(segmentOf(f, 1000 + 90 * min), ShowSegment.postShow);
      expect(segmentOf(const FilmState(dur: 1), 0), ShowSegment.preShow);
      expect(segmentOf(f, 2000), ShowSegment.film);
    });

    test('an intermission resumes by itself', () {
      const f = FilmState(
        phase: FilmPhase.intermission,
        pos: 20 * min,
        until: 5 * min,
        dur: 90 * min,
      );
      expect(f.nowAt(4 * min).phase, FilmPhase.intermission);
      expect(f.nowAt(6 * min).phase, FilmPhase.playing);
      expect(f.nowAt(6 * min).pos, 21 * min);
      expect(f.nextChangeIn(4 * min), min);
    });

    test('reads room metadata the server writes', () {
      final f = FilmState.fromRoomMetadata(
        '{"mode":"premiere","film":{"state":"paused","pos":5,"at":9,'
        '"dur":100,"commentary":true,"pip":"br","startedAt":1}}',
      );
      expect(f.phase, FilmPhase.paused);
      expect(f.commentary, isTrue);
      expect(f.pip, PipCorner.br);
      expect(
        FilmState.fromRoomMetadata('{"film":{"state":"x"}}'),
        FilmState.none,
      );
      expect(FilmState.fromRoomMetadata(null), FilmState.none);
    });
  });

  group('drift', () {
    test('small drift is left alone, medium eased, large seeks', () {
      expect(syncStep(playerMs: 1000, targetMs: 1200), const SyncStep());
      expect(syncStep(playerMs: 2000, targetMs: 1000).rate, 0.95);
      expect(syncStep(playerMs: 1000, targetMs: 2000).rate, 1.05);
      expect(syncStep(playerMs: 0, targetMs: 5000).seekTo, 5000);
      expect(syncStep(playerMs: 9000, targetMs: 5000).seekTo, 5000);
    });

    test('commentary ducks the film to 30%', () {
      expect(filmVolume(commentary: false, muted: false), 1.0);
      expect(filmVolume(commentary: true, muted: false), 0.3);
      expect(filmVolume(commentary: true, muted: true), 0);
      expect(filmVolume(commentary: true, muted: false, duck: 50), 0.5);
      expect(filmVolume(commentary: false, muted: false, duck: 50), 1.0);
    });
  });

  test('the rehearsal transport follows the server rules', () {
    var f = const FilmState(dur: 3 * min);
    f = rehearseFilmControl(f, 'play', 1000);
    expect([f.phase, f.pos, f.startedAt], [FilmPhase.playing, 0, 1000]);
    f = rehearseFilmControl(f, 'pause', 11000);
    expect([f.phase, f.pos], [FilmPhase.paused, 10000]);
    f = rehearseFilmControl(f, 'resume', 20000);
    f = rehearseFilmControl(f, 'intermission', 30000, seconds: 60);
    expect([f.phase, f.pos, f.until], [FilmPhase.intermission, 20000, 90000]);
    f = rehearseFilmControl(f, 'hold', 40000, message: ' Back soon ');
    expect([f.phase, f.message], [FilmPhase.hold, 'Back soon']);
    f = rehearseFilmControl(f, 'commentary', 41000, on: true);
    f = rehearseFilmControl(f, 'pip', 41000, corner: 'tl');
    f = rehearseFilmControl(f, 'duck', 41000, percent: 55);
    expect([f.commentary, f.pip, f.duck], [true, PipCorner.tl, 55]);
    f = rehearseFilmControl(f, 'end', 50000);
    expect(
      [f.phase, f.endedAt, f.commentary, f.duck],
      [FilmPhase.ended, 50000, true, 55],
    );
    f = rehearseFilmControl(f, 'reset', 60000);
    expect([f.phase, f.startedAt], [FilmPhase.pre, null]);
    // Nonsense presses change nothing.
    expect(rehearseFilmControl(f, 'pause', 1), f);
    expect(rehearseFilmControl(f, 'end', 1), f);
  });

  testWidgets('the rehearsal film plays a stand-in, never the real stream', (
    tester,
  ) async {
    var now = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PremiereFilmStage(
            eventId: 'rehearsal',
            film: const FilmState(
              phase: FilmPhase.playing,
              pos: 0,
              at: 0,
              dur: 3 * min,
            ),
            now: () => now,
            protect: false,
            demo: (pos) =>
                DemoFilmPicture(positionMs: pos, durationMs: 3 * min),
          ),
        ),
      ),
    );
    expect(find.text('Demo film'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    now = 61000;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1:01 / 3:00'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'the panel offers Play before the film and the transport during it',
    (tester) async {
      final pressed = <String>[];
      Future<void> control(
        String a, {
        int? positionMs,
        int? seconds,
        String? message,
        bool? on,
        String? corner,
        int? percent,
      }) async => pressed.add(a);
      Widget panel(FilmState f) => MaterialApp(
        home: Scaffold(
          body: PremierePanel(
            film: f,
            now: () => 0,
            onControl: control,
            canPlay: true,
          ),
        ),
      );
      await tester.pumpWidget(panel(const FilmState(dur: 3 * min)));
      await tester.tap(find.text('Play film'));
      await tester.pump();
      expect(pressed, ['play']);
      await tester.pumpWidget(
        panel(const FilmState(phase: FilmPhase.playing, dur: 3 * min)),
      );
      expect(find.text('Pause'), findsOneWidget);
      expect(find.text('Intermission'), findsOneWidget);
      expect(find.text('Hold'), findsOneWidget);
      await tester.tap(find.text('Commentary'));
      await tester.pump();
      expect(pressed.last, 'commentary');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
