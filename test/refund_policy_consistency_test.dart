// Guards the ticket cancellation window against cross-language drift.
//
// The 24-hour window is written down in three places that no compiler
// compares:
//
//   1. lib/services/money.dart          — decides whether the app DRAWS the
//                                          "Cancel ticket" button
//   2. supabase/functions/_shared/money.ts
//                                        — the sentence Stripe prints above
//                                          the pay button, and the number
//                                          refund-ticket ENFORCES
//   3. nile-website/src/pages/terms.astro — the published policy
//
// If they drift, the failure is not a crash: it's the app offering a refund
// the server then refuses, or terms promising a window nothing implements.
// That's the same shape as the share-domain bug (see
// share_domain_consistency_test.dart), which also lived in four files nothing
// compared — so it gets the same treatment.
//
// These tests read the sibling files off disk. No network, no build step.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nile_app/services/money.dart';

void main() {
  final serverMoney =
      File('supabase/functions/_shared/money.ts').readAsStringSync();

  group('cancellation window', () {
    test('the Dart client and the Deno server agree on the number', () {
      final m = RegExp(r'TICKET_REFUND_WINDOW_HOURS\s*=\s*(\d+)')
          .firstMatch(serverMoney);
      expect(m, isNotNull,
          reason: 'TICKET_REFUND_WINDOW_HOURS vanished from _shared/money.ts');
      expect(int.parse(m!.group(1)!), kTicketRefundWindowHours);
    });

    test('the server sentence quotes that same number', () {
      // It is built by interpolation today; assert the rendered intent rather
      // than the expression, so switching to a literal still passes and a
      // wrong literal still fails.
      expect(
        serverMoney.contains(r'${TICKET_REFUND_WINDOW_HOURS} hours') ||
            serverMoney.contains('$kTicketRefundWindowHours hours'),
        isTrue,
        reason: 'the policy text must quote the window it enforces',
      );
    });

    test('the client disclosure quotes it too', () {
      expect(kTicketRefundPolicyShort, contains('$kTicketRefundWindowHours hours'));
    });
  });

  group('published terms', () {
    // Skipped rather than failed when the sibling repo isn't checked out —
    // CI clones one repo at a time, and a red build for a missing sibling
    // teaches people to ignore the suite.
    final terms = File('../nile-website/src/pages/terms.astro');

    test('say the same window as the code', () {
      if (!terms.existsSync()) {
        markTestSkipped('nile-website not checked out beside nile_app');
        return;
      }
      final text = terms.readAsStringSync();
      expect(text, contains('$kTicketRefundWindowHours hours before'));
      // And the sentence the server change contradicted must be gone.
      expect(
        text.contains('Ticket purchases are final.'),
        isFalse,
        reason: 'the pre-#37 wording promised the opposite of what ships',
      );
    });

    test('state the currency, since prices are USD-only', () {
      if (!terms.existsSync()) {
        markTestSkipped('nile-website not checked out beside nile_app');
        return;
      }
      expect(terms.readAsStringSync(), contains('US dollars (USD)'));
    });
  });
}
