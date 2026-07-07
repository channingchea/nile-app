import 'supabase_client.dart';

/// Stripe Connect account status for the current host, as reported live by
/// the `stripe-connect` Edge Function.
class PayoutStatus {
  final bool connected;
  final bool chargesEnabled;
  final bool payoutsEnabled;
  final bool detailsSubmitted;
  final String? dashboardUrl;

  const PayoutStatus({
    required this.connected,
    required this.chargesEnabled,
    required this.payoutsEnabled,
    required this.detailsSubmitted,
    this.dashboardUrl,
  });

  /// Fully onboarded and able to receive payouts.
  bool get isActive => connected && chargesEnabled && payoutsEnabled;

  /// Account exists but onboarding is incomplete (or under review).
  bool get isPending => connected && !isActive;

  factory PayoutStatus.fromJson(Map<String, dynamic> j) => PayoutStatus(
    connected: j['connected'] as bool? ?? false,
    chargesEnabled: j['charges_enabled'] as bool? ?? false,
    payoutsEnabled: j['payouts_enabled'] as bool? ?? false,
    detailsSubmitted: j['details_submitted'] as bool? ?? false,
    dashboardUrl: j['dashboard_url'] as String?,
  );
}

class PayoutService {
  /// Current Connect account status for the signed-in host.
  static Future<PayoutStatus> status() async {
    final response = await supabase.functions.invoke(
      'stripe-connect',
      body: {'action': 'status'},
    );
    if (response.status != 200) {
      throw Exception((response.data as Map?)?['error'] ?? 'Status error');
    }
    return PayoutStatus.fromJson(response.data as Map<String, dynamic>);
  }

  /// Begins (or resumes) Connect onboarding; returns a hosted onboarding URL.
  static Future<String> startOnboarding() async {
    final response = await supabase.functions.invoke(
      'stripe-connect',
      body: {'action': 'onboard'},
    );
    if (response.status != 200) {
      throw Exception((response.data as Map?)?['error'] ?? 'Onboarding error');
    }
    final url = (response.data as Map)['url'] as String?;
    if (url == null) throw Exception('No onboarding URL returned');
    return url;
  }

  /// Ticket + replay earnings (net of the platform share) for the signed-in
  /// host, via the `host_ticket_earnings()` RPC.
  static Future<TicketEarnings> ticketEarnings() async {
    final rows = await supabase.rpc('host_ticket_earnings');
    final list = rows as List;
    if (list.isEmpty) return TicketEarnings.empty;
    return TicketEarnings.fromRow(list.first as Map<String, dynamic>);
  }
}

/// Host ticket/replay earnings. Net = gross minus the platform application fee
/// frozen per split ticket; fallback (un-onboarded) sales count toward gross
/// but net 0 until manually transferred.
class TicketEarnings {
  final int lifetimeNetCents;
  final int monthNetCents;
  final int lifetimeGrossCents;
  final int monthGrossCents;
  final int count;

  const TicketEarnings({
    required this.lifetimeNetCents,
    required this.monthNetCents,
    required this.lifetimeGrossCents,
    required this.monthGrossCents,
    required this.count,
  });

  static const empty = TicketEarnings(
    lifetimeNetCents: 0,
    monthNetCents: 0,
    lifetimeGrossCents: 0,
    monthGrossCents: 0,
    count: 0,
  );

  bool get hasSales => count > 0;

  factory TicketEarnings.fromRow(Map<String, dynamic> r) => TicketEarnings(
    lifetimeNetCents: (r['lifetime_net_cents'] as num?)?.toInt() ?? 0,
    monthNetCents: (r['month_net_cents'] as num?)?.toInt() ?? 0,
    lifetimeGrossCents: (r['lifetime_gross_cents'] as num?)?.toInt() ?? 0,
    monthGrossCents: (r['month_gross_cents'] as num?)?.toInt() ?? 0,
    count: (r['ticket_count'] as num?)?.toInt() ?? 0,
  );
}
