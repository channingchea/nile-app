import 'livekit_service.dart';
import 'realsync.dart' show ClockSample, bestClockSample;

/// This device's estimate of the server clock — what element clocks and the
/// overlay hold-back are read against (studio live elements). Measured with
/// the `clock` action, NTP-style, the first time something needs it; until
/// then (or if it fails) [now] is just the device clock.
abstract final class ServerClock {
  static int? _offsetMs;
  static Future<void>? _measuring;

  /// Device clock minus server clock, once measured.
  static int? get offsetMs => _offsetMs;

  /// Server ms now (device ms until measured).
  static int now() => DateTime.now().millisecondsSinceEpoch - (_offsetMs ?? 0);

  /// Server ms now, or null while unmeasured — for decisions that must not
  /// guess (hold-back).
  static int? nowIfKnown() => _offsetMs == null ? null : now();

  /// Measure once; later calls share the first.
  static Future<void> ensure() => _measuring ??= _measure();

  /// Measure again (a resync).
  static Future<void> remeasure() => _measuring = _measure();

  static Future<void> _measure() async {
    try {
      final samples = <ClockSample>[];
      for (var i = 0; i < 3; i++) {
        final sent = DateTime.now().millisecondsSinceEpoch;
        final server = await LivekitService.serverClock();
        samples.add(
          ClockSample(
            sentAt: sent,
            serverReceivedAt: server.receivedAt,
            serverSentAt: server.sentAt,
            receivedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
      _offsetMs = bestClockSample(samples)?.offsetMs ?? _offsetMs;
    } catch (_) {
      // Best effort: the device clock stands in, and the next ensure retries.
      _measuring = null;
    }
  }

  /// Tests: pretend a measurement happened (null = unmeasured).
  static void debugSetOffset(int? ms) {
    _offsetMs = ms;
    _measuring = ms == null ? null : Future.value();
  }
}
