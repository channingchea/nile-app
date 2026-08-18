import 'package:flutter_test/flutter_test.dart';
import 'package:nile_app/services/notification_preferences_service.dart';

/// P4 #38. Two things worth pinning down here.
///
/// The tip toggle: the column has always existed and always been honoured
/// server-side, so the only bug was that nothing read or wrote it from the
/// client. A round-trip test is exactly the check that was missing.
///
/// Quiet hours: null means OFF, not midnight. Conflating the two would make a
/// 00:00–00:00 window that silences everything, which is the worst possible
/// failure for a comfort feature.
void main() {
  group('tip_received round-trips', () {
    test('defaults on, like every other type', () {
      expect(const NotificationPreferences().tipReceived, isTrue);
    });

    test('reads the column', () {
      final p = NotificationPreferences.fromJson({'tip_received': false});
      expect(p.tipReceived, isFalse);
    });

    test('writes the column', () {
      final p = const NotificationPreferences().copyWith(tipReceived: false);
      expect(p.toColumns()['tip_received'], isFalse);
    });

    test('a missing column is treated as on, not off', () {
      expect(NotificationPreferences.fromJson({}).tipReceived, isTrue);
    });
  });

  group('quiet hours', () {
    test('absent means off, not midnight', () {
      final p = NotificationPreferences.fromJson({});
      expect(p.quietHoursOn, isFalse);
      expect(p.quietHoursStartMinutes, isNull);
      expect(p.toColumns()['quiet_hours_start'], isNull);
    });

    test('parses a postgres time', () {
      final p = NotificationPreferences.fromJson({
        'quiet_hours_start': '22:00:00',
        'quiet_hours_end': '07:30:00',
      });
      expect(p.quietHoursOn, isTrue);
      expect(p.quietHoursStartMinutes, 22 * 60);
      expect(p.quietHoursEndMinutes, 7 * 60 + 30);
    });

    test('serialises back to a postgres time, zero-padded', () {
      final p = const NotificationPreferences()
          .copyWith(quietHoursStartMinutes: 9 * 60 + 5, quietHoursEndMinutes: 0);
      expect(p.toColumns()['quiet_hours_start'], '09:05:00');
      expect(p.toColumns()['quiet_hours_end'], '00:00:00');
    });

    test('midnight is a real value, distinct from off', () {
      final p = NotificationPreferences.fromJson({
        'quiet_hours_start': '00:00:00',
        'quiet_hours_end': '06:00:00',
      });
      expect(p.quietHoursStartMinutes, 0);
      expect(p.quietHoursOn, isTrue);
    });

    test('clearing needs the explicit flag — copyWith cannot pass null', () {
      final on = const NotificationPreferences()
          .copyWith(quietHoursStartMinutes: 1320, quietHoursEndMinutes: 420);
      expect(on.quietHoursOn, isTrue);
      expect(on.copyWith(clearQuietHours: true).quietHoursOn, isFalse);
      // ...and a normal copyWith must not clear it by accident.
      expect(on.copyWith(postLike: false).quietHoursOn, isTrue);
    });

    test('garbage in the column is off rather than a crash', () {
      for (final v in ['', 'nonsense', '25', 42]) {
        final p = NotificationPreferences.fromJson({'quiet_hours_start': v});
        expect(p.quietHoursStartMinutes, isNull, reason: 'input: $v');
      }
    });
  });
}
