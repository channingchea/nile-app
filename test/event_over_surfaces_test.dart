// Group D of the 2026-08-11 lifecycle review: "over" was half-applied. The
// event page and cards used Event.isOver; the viewer screen, five feed queries,
// the calendar export and several labels still keyed off raw status, so a
// no-showed event stayed searchable, recommended, promoted, exportable, and
// openable in a live viewer.
//
// These lock the shared rules those sites now route through.

import 'package:flutter_test/flutter_test.dart';

import 'package:nile_app/services/calendar_ics.dart';
import 'package:nile_app/services/event_service.dart';
import 'package:nile_app/widgets/nile_context_rail.dart';

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

  group('Event.isOverAt matches Event.isOver', () {
    // The viewer screen holds a raw events row, not an Event. If these two ever
    // disagree, the whole bug class is back.
    for (final status in ['scheduled', 'soundcheck', 'live', 'ended', 'draft']) {
      test('$status, window long past', () {
        final e = _event(status: status, scheduledIn: -day, endsIn: -hour);
        expect(
          Event.isOverAt(
            status: e.status,
            scheduledAt: e.scheduledAt,
            endAt: e.endAt,
          ),
          e.isOver,
        );
      });
    }
  });

  group('isWatchable — the affirmative gate for "come in now"', () {
    test('live is watchable', () {
      expect(_event(status: 'live', scheduledIn: -hour, endsIn: hour).isWatchable, isTrue);
    });

    test('sound check inside the window is watchable', () {
      expect(_event(status: 'soundcheck', scheduledIn: -hour, endsIn: hour).isWatchable, isTrue);
    });

    test('abandoned sound check is NOT watchable', () {
      // The D1/D2 bug: this opened a live viewer and rendered a lobby.
      expect(_event(status: 'soundcheck', scheduledIn: -day, endsIn: -hour).isWatchable, isFalse);
    });

    test('scheduled is not watchable even inside its window', () {
      expect(_event(status: 'scheduled', scheduledIn: -hour, endsIn: hour).isWatchable, isFalse);
    });

    test('ended is not watchable', () {
      expect(_event(status: 'ended', scheduledIn: -day, endsIn: -hour).isWatchable, isFalse);
    });
  });

  group('EventService.dropOver — the one filter every feed uses', () {
    test('keeps upcoming and live, drops ended and no-shows', () {
      final upcoming = _event(status: 'scheduled', scheduledIn: day, endsIn: day + hour);
      final live = _event(status: 'live', scheduledIn: -hour, endsIn: hour);
      final ended = _event(status: 'ended', scheduledIn: -day, endsIn: -hour);
      final noShow = _event(status: 'scheduled', scheduledIn: -day, endsIn: -hour);
      final abandoned = _event(status: 'soundcheck', scheduledIn: -day, endsIn: -hour);

      final kept = EventService.dropOver([upcoming, live, ended, noShow, abandoned]);
      expect(kept, hasLength(2));
      expect(kept.map((e) => e.status), containsAll(['scheduled', 'live']));
    });
  });

  group('CalendarIcs.canAdd', () {
    test('an upcoming event can be added', () {
      expect(CalendarIcs.canAdd(_event(status: 'scheduled', scheduledIn: day, endsIn: day + hour)), isTrue);
    });

    test('a past no-show cannot', () {
      expect(CalendarIcs.canAdd(_event(status: 'scheduled', scheduledIn: -day, endsIn: -hour)), isFalse);
    });

    test('a draft cannot, even with a future date', () {
      expect(CalendarIcs.canAdd(_event(status: 'draft', scheduledIn: day, endsIn: day + hour)), isFalse);
    });

    test('an event with no date cannot', () {
      expect(CalendarIcs.canAdd(_event(status: 'scheduled')), isFalse);
    });
  });

  group('nileWhen no longer says "Starting now" for the distant past', () {
    test('a few minutes past still reads as now', () {
      expect(nileWhen(DateTime.now().subtract(const Duration(minutes: 3))), 'Starting now');
    });

    test('three days ago does not', () {
      final label = nileWhen(DateTime.now().subtract(const Duration(days: 3)));
      expect(label, isNot('Starting now'));
    });

    test('yesterday is named as yesterday', () {
      final label = nileWhen(DateTime.now().subtract(const Duration(days: 1)));
      expect(label, startsWith('Yesterday'));
    });

    test('the future is unchanged', () {
      // +1s of slack: inMinutes truncates, so a bare 25-minute offset has
      // already decayed to 24m by the time the call runs.
      final label = nileWhen(
        DateTime.now().add(const Duration(minutes: 25, seconds: 1)),
      );
      expect(label, 'in 25m');
    });
  });
}
