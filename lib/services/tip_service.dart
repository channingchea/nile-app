import 'checkout_origin.dart';
import 'supabase_client.dart';

/// Live-show tips. Collected via a Stripe destination charge in the
/// create-tip-payment edge fn (atomic Connect split — host is paid at checkout).
/// The ledger lives in the `tips` table; this service creates checkout sessions,
/// confirms a completed tip (for the chat announcement), and reads host earnings.
class TipService {
  /// Preset tip amounts, in cents. Custom amounts are validated server-side.
  static const List<int> presetsCents = [200, 500, 1000, 2000];
  static const int minCents = 100;
  static const int maxCents = 50000;

  /// Creates a Stripe Checkout Session for a tip and returns the hosted URL to
  /// open in an external browser. [eventId] is the events PK. Throws with a
  /// message on failure (e.g. `host_not_payable` when the host has no payout
  /// account yet).
  static Future<String> createCheckoutUrl({
    required String eventId,
    required int amountCents,
  }) async {
    final response = await supabase.functions.invoke(
      'create-tip-payment',
      body: {
        'event_id': eventId,
        'amount_cents': amountCents,
        'origin': NileCheckoutOrigin.current,
      },
    );
    if (response.status != 200) {
      throw Exception((response.data as Map?)?['error'] ?? 'Payment error');
    }
    final url = (response.data as Map)['checkout_url'] as String?;
    if (url == null) throw Exception('No checkout URL returned');
    return url;
  }

  /// The current user's most recent paid tip for [eventId], created within the
  /// last few minutes — used after returning from checkout to confirm success
  /// before announcing it. Returns the amount in cents, or null if none.
  /// RLS (`tips_select_own`) scopes this to the tipper.
  static Future<int?> latestPaidTipCents(String eventId) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return null;
    final since = DateTime.now()
        .toUtc()
        .subtract(const Duration(minutes: 10))
        .toIso8601String();
    final rows = await supabase
        .from('tips')
        .select('amount_cents, created_at')
        .eq('event_id', eventId)
        .eq('tipper_id', uid)
        .eq('status', 'paid')
        .gte('created_at', since)
        .order('created_at', ascending: false)
        .limit(1);
    if ((rows as List).isEmpty) return null;
    return (rows.first['amount_cents'] as num).toInt();
  }

  /// Host tip earnings: gross, platform fee, net, and count of paid tips.
  /// RLS scopes this to tips the current user received.
  static Future<TipEarnings> hostEarnings() async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return const TipEarnings(grossCents: 0, feeCents: 0, count: 0);
    final rows = await supabase
        .from('tips')
        .select('amount_cents, fee_cents')
        .eq('host_id', uid)
        .eq('status', 'paid');
    var gross = 0, fee = 0, count = 0;
    for (final r in rows as List) {
      gross += (r['amount_cents'] as num).toInt();
      fee += (r['fee_cents'] as num?)?.toInt() ?? 0;
      count++;
    }
    return TipEarnings(grossCents: gross, feeCents: fee, count: count);
  }
}

class TipEarnings {
  final int grossCents;
  final int feeCents;
  final int count;

  const TipEarnings({
    required this.grossCents,
    required this.feeCents,
    required this.count,
  });

  int get netCents => grossCents - feeCents;
  bool get hasTips => count > 0;
}
