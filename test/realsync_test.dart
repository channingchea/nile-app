// RealSync (Studio master host, phase 7): the arithmetic and the control loop.
// The native hook itself can't run in a unit test — its guard is the launch
// self-test (packages/nile_realsync) and the phase 7a hardware rig.

import 'package:flutter_test/flutter_test.dart';

import 'package:nile_app/services/realsync.dart';

void main() {
  group('7b clock alignment', () {
    test('offset and round trip exclude the server’s own processing time', () {
      // Device is 500 ms ahead; 40 ms each way; server spent 200 ms on auth.
      const s = ClockSample(
        sentAt: 10500,
        serverReceivedAt: 10040,
        serverSentAt: 10240,
        receivedAt: 10780,
      );
      expect(s.rttMs, 80);
      expect(s.offsetMs, 500);
    });

    test('the quickest ping wins', () {
      const slow = ClockSample(sentAt: 0, serverReceivedAt: 300, serverSentAt: 300, receivedAt: 400);
      const fast = ClockSample(sentAt: 0, serverReceivedAt: 20, serverSentAt: 20, receivedAt: 40);
      expect(bestClockSample([slow, fast, slow]), same(fast));
      expect(bestClockSample(const []), isNull);
    });
  });

  group('7c measurement', () {
    test('drift puts both senders on one clock', () {
      // Camera clock runs 300 ms fast; once corrected the picture is 120 ms
      // ahead of the sound.
      expect(
        driftMs(
          videoPlayoutMs: 1420,
          cameraOffsetMs: 300,
          audioPlayoutMs: 1000,
          audioOffsetMs: 0,
        ),
        120,
      );
    });

    test('Studio lag is relative to the most current camera', () {
      final lag = relativeLagMs({
        'cam-a': (playout: 5000.0, offset: 0),
        'cam-b': (playout: 4880.0, offset: 0),
        'cam-c': (playout: 5100.0, offset: 200), // fast clock, actually 4900
      });
      expect(lag, {'cam-a': 0, 'cam-b': 120, 'cam-c': 100});
      expect(relativeLagMs(const {}), isEmpty);
    });
  });

  group('7d correction', () {
    test('a new angle converges on three readings, then needs five', () {
      final e = SyncEngine();
      expect(e.addDrift(200), isFalse);
      expect(e.addDrift(220), isFalse);
      expect(e.addDrift(210), isTrue);
      expect(e.targetVideoMs, 210);
      expect(e.targetAudioMs, 0);
      expect(e.settling, isFalse);
      for (var i = 0; i < 4; i++) {
        expect(e.addDrift(80), isFalse);
      }
      expect(e.addDrift(80), isTrue);
    });

    test('inside the dead-band nothing moves', () {
      final e = SyncEngine();
      for (final d in [30.0, -20.0, 35.0]) {
        e.addDrift(d);
      }
      expect(e.targetVideoMs, 0);
      expect(e.targetAudioMs, 0);
    });

    test('audio ahead holds the audio back instead', () {
      final e = SyncEngine();
      for (final d in [-300.0, -310.0, -290.0]) {
        e.addDrift(d);
      }
      expect(e.targetAudioMs, 300);
      expect(e.targetVideoMs, 0);
    });

    test('capped at 1.5 s and garbage ignored', () {
      final e = SyncEngine();
      expect(e.addDrift(double.nan), isFalse);
      expect(e.addDrift(60000), isFalse);
      for (final d in [4000.0, 4000.0, 4000.0]) {
        e.addDrift(d);
      }
      expect(e.targetVideoMs, 1500);
    });

    test('ramps in 50 ms steps', () {
      final e = SyncEngine()..targetVideoMs = 120;
      expect(e.step().video, isTrue);
      expect(e.videoDelayMs, 50);
      e.step();
      e.step();
      expect(e.videoDelayMs, 120);
      expect(e.step().video, isFalse);
    });

    test('feedback: what is already applied counts toward the next target', () {
      final e = SyncEngine()
        ..videoDelayMs = 200
        ..targetVideoMs = 200
        ..addDrift(1)
        ..addDrift(1)
        ..addDrift(1); // settle on "in step"
      // The buffer was already deeper than 200 ms; picture still 100 ms ahead.
      for (var i = 0; i < 5; i++) {
        e.addDrift(100);
      }
      expect(e.targetVideoMs, 300);
    });

    test('switching from video-held to audio-held swaps sides', () {
      final e = SyncEngine()
        ..videoDelayMs = 100
        ..addDrift(1)
        ..addDrift(1)
        ..addDrift(1);
      for (var i = 0; i < 5; i++) {
        e.addDrift(-250); // now the audio is 250 ms ahead even with 100 on video
      }
      expect(e.targetVideoMs, 0);
      expect(e.targetAudioMs, 150);
    });

    test('restart keeps the audio, clear drops everything', () {
      final e = SyncEngine()
        ..videoDelayMs = 100
        ..audioDelayMs = 80
        ..targetAudioMs = 80;
      e.restart();
      expect(e.videoDelayMs, 0);
      expect(e.audioDelayMs, 80);
      expect(e.settling, isTrue);
      e.clear();
      expect(e.audioDelayMs, 0);
      expect(e.targetAudioMs, 0);
    });
  });
}
