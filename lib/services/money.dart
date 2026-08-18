/// Currency formatting and the ticket cancellation policy, in one place.
///
/// P4 #37 of the 2026-08-16 platform review: every price in the app was
/// rendered as a bare `$`, and nothing anywhere told a buyer what currency
/// they were being charged in or whether a refund was possible. Both of those
/// have to be true *before* payment, not discoverable afterwards.
///
/// The server half lives in supabase/functions/_shared/money.ts and owns the
/// same two facts. Keep the window and the wording in step — Stripe prints the
/// server's copy above the pay button, and this file's copy is what the buyer
/// read on the way there.
library;

/// Plain price: `$12.00`. Use inside lists and totals where the currency is
/// already established by something nearby.
String nileMoney(int cents) => '\$${(cents / 100).toStringAsFixed(2)}';

/// Price with the currency stated: `$12.00 USD`. Use anywhere the next tap
/// could take money — buy buttons, tip sheets, confirmation dialogs.
String nileMoneyUsd(int cents) => '${nileMoney(cents)} USD';

/// Hours before an event starts during which a buyer can still cancel.
/// Mirrors TICKET_REFUND_WINDOW_HOURS in _shared/money.ts.
const int kTicketRefundWindowHours = 24;

/// One-line disclosure for the surface a buyer taps to pay.
const String kTicketRefundPolicyShort =
    'Charged in US dollars. Free cancellation up to '
    '$kTicketRefundWindowHours hours before the event starts.';

/// Whether [scheduledAt] is still far enough out to self-cancel. The server
/// re-checks this — treat it as "should I draw the button", never as the
/// authority.
///
/// [now] is injectable so the boundary can be asserted exactly; left null it
/// reads the clock. Comparing against a live `DateTime.now()` inside a test
/// loses microseconds to the call itself and turns "exactly 24 hours" into
/// "23:59:59.9", which is a flake, not a finding.
bool canCancelTicket({
  required DateTime? scheduledAt,
  required String eventStatus,
  DateTime? now,
}) {
  if (eventStatus != 'scheduled' || scheduledAt == null) return false;
  return scheduledAt.difference(now ?? DateTime.now()) >=
      const Duration(hours: kTicketRefundWindowHours);
}
