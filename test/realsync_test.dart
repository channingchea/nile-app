// RealSync (Studio master host, phase 7): the arithmetic and the control loop.
// The native side can't run in a unit test — its guards are the launch
// self-tests (packages/nile_realsync) and the macOS probes in its tool/.

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
    test('Studio lag is relative to the most current camera', () {
      final lag = relativeLagMs({'cam-a': 140.0, 'cam-b': 260.0, 'cam-c': 240.4});
      expect(lag, {'cam-a': 0, 'cam-b': 120, 'cam-c': 100});
      expect(relativeLagMs(const {}), isEmpty);
    });
  });

  group('7d correction — every stream on screen', () {
    final t0 = DateTime(2026, 10, 17);

    GroupSyncEngine feed(Map<String, double> ages, {int times = 3}) {
      final e = GroupSyncEngine()..retain(ages.keys.toSet());
      for (var i = 0; i < times; i++) {
        ages.forEach((id, age) => e.add(id, age, at: t0));
      }
      return e;
    }

    test('all cameras and the sound meet the oldest stream', () {
      final e = feed({'cam-a': 100, 'cam-b': 250, 'audio': 180});
      expect(e.solve(now: t0), isTrue);
      expect(e.targetMs, {'cam-a': 150, 'audio': 70}); // cam-b is the oldest
      expect(e.settling, isFalse);
    });

    test('nobody is held more than 1 s; the straggler is left behind', () {
      final e = feed({'cam-a': 100, 'audio': 120, 'cam-far': 1600});
      e.solve(now: t0);
      expect(e.targetMs, {'cam-a': 1000, 'audio': 980}); // cam-far: not held
    });

    test('inside the dead-band nothing moves', () {
      final e = feed({'cam-a': 100, 'audio': 130});
      expect(e.solve(now: t0), isFalse);
      expect(e.targetMs, isEmpty);
    });

    test('a single stream has nothing to line up with', () {
      final e = feed({'audio': 100});
      expect(e.solve(now: t0), isFalse);
    });

    test('feedback: applied delays are part of the next readings', () {
      final e = feed({'cam-a': 100, 'audio': 300});
      e.solve(now: t0);
      e.delayMs['cam-a'] = 200; // ramped in, and it took effect
      for (var i = 0; i < 5; i++) {
        e.add('cam-a', 300, at: t0);
        e.add('audio', 300, at: t0);
      }
      expect(e.solve(now: t0), isFalse);
      expect(e.targetMs['cam-a'], 200);
    });

    test('a new camera settles on its own without blocking the rest', () {
      final e = feed({'cam-a': 100, 'audio': 300});
      e.solve(now: t0);
      e.retain({'cam-a', 'audio', 'cam-new'});
      e.add('cam-new', 500, at: t0); // only one reading so far
      expect(e.settling, isTrue);
      e.solve(now: t0);
      expect(e.targetMs.containsKey('cam-new'), isFalse);
      e
        ..add('cam-new', 500, at: t0)
        ..add('cam-new', 500, at: t0);
      e.solve(now: t0);
      expect(e.targetMs, {'cam-a': 400, 'audio': 200});
    });

    test('a feed that stops reporting stops counting', () {
      final e = feed({'cam-a': 100, 'audio': 200, 'cam-paused': 900});
      e.add('cam-a', 100, at: t0.add(const Duration(seconds: 6)));
      e.add('audio', 200, at: t0.add(const Duration(seconds: 6)));
      e.solve(now: t0.add(const Duration(seconds: 6)));
      expect(e.targetMs, {'cam-a': 100});
    });

    test('dropped streams are reported so their delays get cleared', () {
      final e = feed({'cam-a': 100, 'audio': 300});
      e.solve(now: t0);
      e.step();
      expect(e.retain({'audio'}), {'cam-a'});
      expect(e.delayMs.containsKey('cam-a'), isFalse);
    });

    test('ramps in 50 ms steps', () {
      final e = GroupSyncEngine()..targetMs['cam-a'] = 120;
      expect(e.step(), {'cam-a'});
      expect(e.delayMs['cam-a'], 50);
      e
        ..step()
        ..step();
      expect(e.delayMs['cam-a'], 120);
      expect(e.step(), isEmpty);
    });

    test('garbage readings are ignored', () {
      final e = GroupSyncEngine()..retain({'cam-a'});
      e
        ..add('cam-a', double.nan, at: t0)
        ..add('cam-a', 60000, at: t0);
      expect(e.settling, isFalse); // nothing recorded
    });

    test('restart re-measures but keeps delays; clear drops them', () {
      final e = feed({'cam-a': 100, 'audio': 300});
      e
        ..solve(now: t0)
        ..step()
        ..restart();
      expect(e.delayMs['cam-a'], 50);
      expect(e.solve(now: t0), isFalse); // no readings yet
      e.clear();
      expect(e.delayMs, isEmpty);
      expect(e.targetMs, isEmpty);
    });

    test('the cap is 1 s', () => expect(realSyncCapMs, 1000));
  });
}
