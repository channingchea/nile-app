import 'package:flutter_test/flutter_test.dart';
import 'package:nile_app/services/money.dart';

/// The cancellation window is a promise printed above Stripe's pay button
/// (_shared/money.ts) and enforced in refund-ticket. This guards the client
/// half — the predicate that decides whether the "Cancel ticket" button is
/// drawn at all. Drawing it late is worse than not drawing it: the buyer taps,
/// the server refuses, and we look like we moved the goalposts.
void main() {
  // A fixed clock, so "exactly 24 hours" means exactly 24 hours rather than
  // 24 hours minus however long the test took to reach the assertion.
  final now = DateTime.utc(2026, 8, 18, 12);
  DateTime inHours(num h) => now.add(Duration(minutes: (h * 60).round()));

  bool can(DateTime? at, String status) =>
      canCancelTicket(scheduledAt: at, eventStatus: status, now: now);

  group('canCancelTicket', () {
    test('well inside the window', () {
      expect(can(inHours(72), 'scheduled'), isTrue);
    });

    test('exactly at the boundary still qualifies', () {
      expect(can(inHours(kTicketRefundWindowHours), 'scheduled'), isTrue);
    });

    test('a minute inside the cutoff does not', () {
      expect(
        can(now.add(const Duration(hours: kTicketRefundWindowHours, minutes: -1)),
            'scheduled'),
        isFalse,
      );
    });

    test('an event already past its start does not', () {
      expect(can(inHours(-1), 'scheduled'), isFalse);
    });

    // Status beats the clock: a host who opens soundcheck early has begun
    // delivering, whatever scheduled_at still says.
    for (final s in ['soundcheck', 'live', 'ended', 'cancelled', 'draft']) {
      test('status "$s" is never self-cancellable', () {
        expect(can(inHours(72), s), isFalse);
      });
    }

    test('no scheduled start, no self-cancel', () {
      expect(can(null, 'scheduled'), isFalse);
    });

    test('defaults to the wall clock when no now is given', () {
      expect(
        canCancelTicket(
          scheduledAt: DateTime.now().add(const Duration(days: 7)),
          eventStatus: 'scheduled',
        ),
        isTrue,
      );
    });
  });

  group('currency is always stated where money moves', () {
    test('nileMoney is the bare figure', () {
      expect(nileMoney(1200), '\$12.00');
      expect(nileMoney(0), '\$0.00');
      expect(nileMoney(1), '\$0.01');
    });

    test('nileMoneyUsd names the currency', () {
      expect(nileMoneyUsd(1200), '\$12.00 USD');
    });

    test('the disclosure quotes the same window the code enforces', () {
      expect(
        kTicketRefundPolicyShort,
        contains('$kTicketRefundWindowHours hours'),
      );
      expect(kTicketRefundPolicyShort, contains('US dollars'));
    });
  });
}
