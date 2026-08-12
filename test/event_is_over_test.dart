// Beta testers found past events still saying "waiting for stream/host".
//
// Two causes: the auto_end_expired_events sweep only touched status = 'live',
// so a host no-show stayed 'scheduled' and an abandoned Sound Check stayed
// 'soundcheck' forever (fixed in migration 0084); and the app trusted the raw
// status, so it kept promising a stream even between sweeps. Event.isOver is
// the client-side guard — these lock in its contract.

import 'package:flutter_test/flutter_test.dart';

import 'package:nile_app/services/event_service.dart';

Event _event({
  required String status,
  Duration? scheduledIn,
  Duration? endsIn,
}) {
  final now = DateTime.now().toUtc();
  return Event.fromJson({
    'id': 'e1',
    'host_id': 'h1',
    'title': 'Test show',
    'status': status,
    'viewer_count': 0,
    'created_at': now.toIso8601String(),
    'scheduled_at': scheduledIn == null
        ? null
        : now.add(scheduledIn).toIso8601String(),
    'end_at': endsIn == null ? null : now.add(endsIn).toIso8601String(),
  });
}

void main() {
  const day = Duration(days: 1);
  const hour = Duration(hours: 1);

  test('host no-show: still scheduled, window long past', () {
    final e = _event(
      status: 'scheduled',
      scheduledIn: -day,
      endsIn: -day + const Duration(hours: 2),
    );
    expect(e.isOver, isTrue);
  });

  test('abandoned sound check counts as over', () {
    final e = _event(status: 'soundcheck', scheduledIn: -day, endsIn: -hour);
    expect(e.isOver, isTrue);
  });

  test('scheduled event still inside its window is not over', () {
    final e = _event(status: 'scheduled', scheduledIn: -hour, endsIn: hour);
    expect(e.isOver, isFalse);
  });

  test('upcoming event is not over', () {
    final e = _event(status: 'scheduled', scheduledIn: day, endsIn: day + hour);
    expect(e.isOver, isFalse);
  });

  test('a live stream is never over, even past its end_at', () {
    // The host running long must not be cut off client-side; the server-side
    // sweep owns that call.
    final e = _event(status: 'live', scheduledIn: -day, endsIn: -hour);
    expect(e.isOver, isFalse);
  });

  test('status ended is always over', () {
    final e = _event(status: 'ended', scheduledIn: day, endsIn: day + hour);
    expect(e.isOver, isTrue);
  });

  test('a draft is never over', () {
    final e = _event(status: 'draft', scheduledIn: -day, endsIn: -hour);
    expect(e.isOver, isFalse);
  });

  group('missing end_at falls back to the max stream length', () {
    test('past the 8h cap is over', () {
      final e = _event(status: 'scheduled', scheduledIn: const Duration(hours: -9));
      expect(e.isOver, isTrue);
    });

    test('inside the 8h cap is not', () {
      final e = _event(status: 'scheduled', scheduledIn: const Duration(hours: -7));
      expect(e.isOver, isFalse);
    });

    test('no scheduled_at either: undecidable, so not over', () {
      final e = _event(status: 'scheduled');
      expect(e.isOver, isFalse);
    });
  });
}
