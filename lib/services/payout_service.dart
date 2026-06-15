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
}
