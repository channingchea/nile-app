import 'net.dart';
import 'supabase_client.dart';

/// Server pricing constants (the `app_config` singleton), mirrored on-device so
/// the create flow can show the floor live without a round-trip per keystroke.
/// The server trigger from migration 0078 is the real enforcement — this is a
/// courtesy copy, so [minTicketCentsFor] must stay in sync with the SQL
/// `compute_min_ticket_cents`.
class PricingConfig {
  final int minTicketCents;
  final double egressCentsPerViewerHour;
  final double ingestCentsPerCamHour;
  final double stripePct;
  final int stripeFixedCents;
  final int floorAssumedTickets;
  final int maxStreamMinutes;
  final double creatorRevenueShare;

  const PricingConfig({
    required this.minTicketCents,
    required this.egressCentsPerViewerHour,
    required this.ingestCentsPerCamHour,
    required this.stripePct,
    required this.stripeFixedCents,
    required this.floorAssumedTickets,
    required this.maxStreamMinutes,
    required this.creatorRevenueShare,
  });

  /// Used until the real config lands (and if the fetch ever fails). Matches
  /// the migration 0078 defaults.
  static const PricingConfig fallback = PricingConfig(
    minTicketCents: 100,
    egressCentsPerViewerHour: 27,
    ingestCentsPerCamHour: 40,
    stripePct: 0.029,
    stripeFixedCents: 30,
    floorAssumedTickets: 10,
    maxStreamMinutes: 480,
    creatorRevenueShare: 0.50,
  );

  factory PricingConfig.fromJson(Map<String, dynamic> j) {
    double num_(Object? v, double fb) =>
        v == null ? fb : double.tryParse(v.toString()) ?? fb;
    int int_(Object? v, int fb) => (v as num?)?.toInt() ?? fb;
    const f = PricingConfig.fallback;
    return PricingConfig(
      minTicketCents: int_(j['min_ticket_cents'], f.minTicketCents),
      egressCentsPerViewerHour: num_(
        j['egress_cents_per_viewer_hour'],
        f.egressCentsPerViewerHour,
      ),
      ingestCentsPerCamHour: num_(
        j['ingest_cents_per_cam_hour'],
        f.ingestCentsPerCamHour,
      ),
      stripePct: num_(j['stripe_pct'], f.stripePct),
      stripeFixedCents: int_(j['stripe_fixed_cents'], f.stripeFixedCents),
      floorAssumedTickets: int_(
        j['floor_assumed_tickets'],
        f.floorAssumedTickets,
      ),
      maxStreamMinutes: int_(j['max_stream_minutes'], f.maxStreamMinutes),
      creatorRevenueShare: num_(
        j['creator_revenue_share'],
        f.creatorRevenueShare,
      ),
    );
  }

  /// Break-even ticket floor in cents. Worst case per ticket: one viewer who
  /// watches the whole show, plus this ticket's share of ingest across the
  /// assumed buyer count, plus Stripe's fixed fee — all of which has to come
  /// out of the platform's slice. Rounded up to 50c, never below
  /// [minTicketCents].
  int minTicketCentsFor({
    required int durationMinutes,
    required int cameraCount,
  }) {
    final hours = (durationMinutes < 1 ? 1 : durationMinutes) / 60.0;
    final cams = cameraCount < 1 ? 1 : cameraCount;
    final cost =
        stripeFixedCents +
        egressCentsPerViewerHour * hours +
        (ingestCentsPerCamHour * cams * hours) / floorAssumedTickets;
    final margin = (1 - creatorRevenueShare) - stripePct;
    if (margin <= 0) return minTicketCents;
    final floor = ((cost / margin) / 50.0).ceil() * 50;
    return floor < minTicketCents ? minTicketCents : floor;
  }

  /// What the host keeps from one ticket sold at [priceCents].
  int creatorEarningsCents(int priceCents) =>
      (priceCents * creatorRevenueShare).round();

  int get maxStreamHours => maxStreamMinutes ~/ 60;
}

/// Loads and caches [PricingConfig]. The cache lives for the app session —
/// these constants change about as often as the revenue split does.
class PricingService {
  static PricingConfig? _cached;

  /// Best known config right now; the fallback until [load] resolves.
  static PricingConfig get current => _cached ?? PricingConfig.fallback;

  /// Fetch once, then serve from memory. Fails **open** to the fallback so a
  /// config hiccup can never block event creation — the server trigger still
  /// enforces the real numbers.
  static Future<PricingConfig> load() async {
    if (_cached != null) return _cached!;
    try {
      final rows = await supabase
          .from('app_config')
          .select(
            'min_ticket_cents, egress_cents_per_viewer_hour, '
            'ingest_cents_per_cam_hour, stripe_pct, stripe_fixed_cents, '
            'floor_assumed_tickets, max_stream_minutes, creator_revenue_share',
          )
          .eq('id', 1)
          .limit(1)
          .timeout(kNetTimeout);
      if (rows.isNotEmpty) {
        _cached = PricingConfig.fromJson(rows.first);
      }
    } catch (_) {
      /* keep the fallback */
    }
    return current;
  }

  /// Maps the migration-0078 trigger codes to host-facing copy. Returns null
  /// for anything else so callers can fall back to their generic message.
  static String? friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('multicam_requires_ticket')) {
      return 'Multi-camera streams need a ticket price. Drop to one camera to '
          'stream free, or set a price.';
    }
    if (s.contains('price_below_minimum')) {
      return 'That price is below the minimum for this event. Raise the price '
          'or shorten the stream.';
    }
    if (s.contains('duration_exceeds_max')) {
      return 'Streams are capped at ${current.maxStreamHours} hours.';
    }
    return null;
  }
}
