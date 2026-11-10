import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nile_app/router.dart';
import 'package:nile_app/services/film_sync.dart';
import 'package:nile_app/services/studio_graphics.dart';
import 'package:nile_app/services/studio_prefs.dart';
import 'package:nile_app/widgets/nile_studio.dart';
import 'package:nile_app/widgets/premiere_panel.dart';

/// The Studio audit of 2026-11-09: one mirror rule, the host's mic button,
/// the film's level under commentary, guest names that give the host's lower
/// third back, and guest links that survive sign-in.
void main() {
  group('mirrorSelfView', () {
    test('follows the saved choice', () {
      expect(mirrorSelfView(preference: true), isTrue);
      expect(mirrorSelfView(preference: false), isFalse);
    });

    test('never flips a rear camera', () {
      expect(mirrorSelfView(preference: true, rearCamera: true), isFalse);
    });
  });

  group('guest name over the host lower third', () {
    const host = LiveGraphic(
      id: 'lt-host',
      kind: GraphicKind.lowerThird,
      title: 'Channing',
    );
    final start = const GraphicsState().withOn(null, host);
    const now = 1000;
    const guest = LiveGraphic(
      id: 'guest-name:u1',
      kind: GraphicKind.lowerThird,
      title: 'Ada',
      hideAt: now + 8000,
    );

    test('covers it, then gives it back once the name runs out', () {
      final r = start.withCover(guest);
      expect(r.covered?.id, 'lt-host');
      expect(r.state.forSlot(null, nowMs: now).single.id, 'guest-name:u1');
      // Still up: nothing changes.
      expect(r.state.withRestored(host, now + 100), r.state);
      final back = r.state.withRestored(host, now + 9000);
      expect(back.forSlot(null, nowMs: now + 9000).single.id, 'lt-host');
    });

    test('stays down when the host put something else up meanwhile', () {
      const other = LiveGraphic(
        id: 'lt-other',
        kind: GraphicKind.lowerThird,
        title: 'Sponsor read',
      );
      final s = start.withCover(guest).state.withOn(null, other);
      expect(s.withRestored(host, now + 9000), s);
    });

    test('covering nothing restores nothing', () {
      expect(const GraphicsState().withCover(guest).covered, isNull);
    });
  });

  group('GuestLinkHold', () {
    test('keeps a guest link through sign-in and hands it back once', () {
      final h = GuestLinkHold();
      expect(h.check(ready: false, loc: '/g/abc', gateScreen: false), isNull);
      expect(h.check(ready: false, loc: '/login', gateScreen: true), isNull);
      expect(h.link, '/g/abc');
      expect(h.check(ready: true, loc: '/login', gateScreen: true), '/g/abc');
      expect(h.check(ready: true, loc: '/login', gateScreen: true), isNull);
    });

    test('ignores other links and clears once the guest is there', () {
      final h = GuestLinkHold();
      h.check(ready: false, loc: '/event/1', gateScreen: false);
      expect(h.link, isNull);
      h.check(ready: false, loc: '/g/abc', gateScreen: false);
      h.check(ready: true, loc: '/g/abc', gateScreen: false);
      expect(h.link, isNull);
    });
  });

  test('the film level under commentary is the host’s choice', () {
    final f = FilmState.fromJson({
      'state': 'playing',
      'pos': 0,
      'at': 0,
      'dur': 100,
      'commentary': true,
      'duck': 70,
    })!;
    expect(f.duck, 70);
    expect(
      filmVolume(commentary: f.commentary, muted: false, duck: f.duck),
      0.7,
    );
    expect(FilmState.fromJson({...f.toWireForTest(), 'duck': 300})!.duck, 100);
  });

  testWidgets('the panel shows the level slider only under commentary', (
    tester,
  ) async {
    Future<void> control(
      String a, {
      int? positionMs,
      int? seconds,
      String? message,
      bool? on,
      String? corner,
      int? percent,
    }) async {}
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
    await tester.pumpWidget(panel(const FilmState(dur: 60000)));
    expect(find.text('Film under your voice'), findsNothing);
    await tester.pumpWidget(
      panel(const FilmState(dur: 60000, commentary: true, duck: 45)),
    );
    expect(find.text('Film under your voice'), findsOneWidget);
    expect(find.text('45%'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the control bar mic button says what viewers hear', (
    tester,
  ) async {
    var taps = 0;
    Widget bar({required String status, required bool muted}) => MaterialApp(
      home: Scaffold(
        body: NileStudioControlBar(
          isLive: true,
          isHost: true,
          isMasterAudio: true,
          videoEnabled: true,
          onLeave: () {},
          micStatus: status,
          micMuted: muted,
          micOnAir: !muted,
          onToggleMic: () => taps++,
        ),
      ),
    );
    await tester.pumpWidget(bar(status: 'Mic live', muted: false));
    await tester.tap(find.text('Mic live'));
    expect(taps, 1);
    await tester.pumpWidget(bar(status: 'Muted', muted: true));
    expect(find.byIcon(Icons.mic_off), findsOneWidget);
    await tester.pumpWidget(
      bar(status: 'Muted while the film plays', muted: false),
    );
    expect(find.text('Muted while the film plays'), findsOneWidget);
  });
}

extension on FilmState {
  Map<String, Object?> toWireForTest() => {
    'state': phase.name,
    'pos': pos,
    'at': at,
    'dur': dur,
    'commentary': commentary,
  };
}
