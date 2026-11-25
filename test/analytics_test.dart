import 'package:flutter_test/flutter_test.dart';
import 'package:nile_app/services/analytics.dart';

/// P4 #39. The valuable guarantees here are the negative ones: with no key
/// configured (every test run, and every local `flutter run`), analytics must
/// be completely inert and must never throw. A crash in telemetry taking the
/// app down would be a strictly worse outcome than having no telemetry.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('inert without a key, and every call is safe to make', () async {
    await NileAnalytics.init();
    expect(NileAnalytics.isEnabled, isFalse,
        reason: 'no POSTHOG_API_KEY is set in a test run');

    // None of these should throw, and none should need a caller-side guard.
    await NileAnalytics.identify('user-1');
    await NileAnalytics.capture(NileEvent.eventViewed, {'event_id': 'e1'});
    await NileAnalytics.capture(NileEvent.ticketConfirmed);
    await NileAnalytics.reset();
    await NileAnalytics.setOptOut(true);
    await NileAnalytics.setOptOut(false);
  });

  group('event vocabulary', () {
    test('wire names are snake_case and stable', () {
      // Renaming the Dart symbol must not silently rename the event and split
      // a funnel in the dashboard, so the strings are asserted explicitly.
      expect(NileEvent.eventViewed.name, 'event_viewed');
      expect(NileEvent.ticketCheckoutStarted.name, 'ticket_checkout_started');
      expect(NileEvent.ticketConfirmed.name, 'ticket_confirmed');
      expect(NileEvent.replayCheckoutStarted.name, 'replay_checkout_started');
      expect(NileEvent.streamJoined.name, 'stream_joined');
      expect(NileEvent.tipSent.name, 'tip_sent');
    });

    test('no two events share a wire name', () {
      final names = NileEvent.values.map((e) => e.name).toList();
      expect(names.toSet().length, names.length);
    });

    test('the funnel this exists for is present end to end', () {
      final names = NileEvent.values.map((e) => e.name).toSet();
      expect(
        names.containsAll(
            {'event_viewed', 'ticket_checkout_started', 'ticket_confirmed'}),
        isTrue,
        reason: 'view → checkout → confirmed is the whole point of #39',
      );
    });
  });
}
