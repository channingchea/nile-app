import 'net.dart';
import 'supabase_client.dart';

/// Server pricing constants (the `app_config` singleton), mirrored on-device so
/// the create flow can show the floor live without a round-trip per keystroke.
/// The server trigger (`enforce_event_pricing_limits`) is the real enforcement
/// — this is a courtesy copy, so [minTicketCentsFor] must stay in sync with the
/// SQL `compute_min_ticket_cents` (migration 0155).
class PricingConfig {
  final int minTicketCents;
  final int floorBaseCents;
  final int floorStepCents;
  final int floorStepMinutes;
  final int floorAssumedTickets;
  final int maxStreamMinutes;
  final int freeMaxStreamMinutes;
  final double creatorRevenueShare;

  const PricingConfig({
    required this.minTicketCents,
    required this.floorBaseCents,
    required this.floorStepCents,
    required this.floorStepMinutes,
    required this.floorAssumedTickets,
    required this.maxStreamMinutes,
    required this.freeMaxStreamMinutes,
    required this.creatorRevenueShare,
  });

  /// Used until the real config lands (and if the fetch ever fails). Matches
  /// the migration 0155/0156 defaults.
  static const PricingConfig fallback = PricingConfig(
    minTicketCents: 100,
    floorBaseCents: 300,
    floorStepCents: 100,
    floorStepMinutes: 30,
    floorAssumedTickets: 10,
    maxStreamMinutes: 480,
    freeMaxStreamMinutes: 120,
    creatorRevenueShare: 0.50,
  );

  factory PricingConfig.fromJson(Map<String, dynamic> j) {
    int int_(Object? v, int fb) => (v as num?)?.toInt() ?? fb;
    const f = PricingConfig.fallback;
    return PricingConfig(
      minTicketCents: int_(j['min_ticket_cents'], f.minTicketCents),
      floorBaseCents: int_(j['floor_base_cents'], f.floorBaseCents),
      floorStepCents: int_(j['floor_step_cents'], f.floorStepCents),
      floorStepMinutes: int_(j['floor_step_minutes'], f.floorStepMinutes),
      floorAssumedTickets: int_(
        j['floor_assumed_tickets'],
        f.floorAssumedTickets,
      ),
      maxStreamMinutes: int_(j['max_stream_minutes'], f.maxStreamMinutes),
      freeMaxStreamMinutes: int_(
        j['free_max_stream_minutes'],
        f.freeMaxStreamMinutes,
      ),
      creatorRevenueShare:
          double.tryParse('${j['creator_revenue_share']}') ??
          f.creatorRevenueShare,
    );
  }

  /// Ticket floor in cents: [floorBaseCents] for the first hour, plus
  /// [floorStepCents] for every [floorStepMinutes] (or part of one) after it.
  /// The same for any camera count or Studio mode. Never below
  /// [minTicketCents].
  int minTicketCentsFor({required int durationMinutes}) {
    final extra = durationMinutes > 60 ? durationMinutes - 60 : 0;
    final floor =
        floorBaseCents + floorStepCents * (extra / floorStepMinutes).ceil();
    return floor < minTicketCents ? minTicketCents : floor;
  }

  /// The floor in words, for the host: "$3 for the first hour, +$1 per extra
  /// 30 min".
  String get floorRule =>
      '${_dollars(floorBaseCents)} for the first hour, '
      '+${_dollars(floorStepCents)} per extra $floorStepMinutes min';

  static String _dollars(int cents) => cents % 100 == 0
      ? '\$${cents ~/ 100}'
      : '\$${(cents / 100).toStringAsFixed(2)}';

  /// What the host keeps from one ticket sold at [priceCents].
  int creatorEarningsCents(int priceCents) =>
      (priceCents * creatorRevenueShare).round();

  int get maxStreamHours => maxStreamMinutes ~/ 60;
  int get freeMaxStreamHours => freeMaxStreamMinutes ~/ 60;

  /// What a show with no ticket price gets (0156, and the livekit function).
  String get freeShowRule =>
      'Free shows run up to $freeMaxStreamHours hours in 480p and aren’t '
      'recorded.';
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
            'min_ticket_cents, floor_base_cents, floor_step_cents, '
            'floor_step_minutes, floor_assumed_tickets, max_stream_minutes, '
            'free_max_stream_minutes, creator_revenue_share',
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

  /// Maps the pricing trigger's codes to host-facing copy. Returns null
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
    if (s.contains('free_duration_exceeds_max')) {
      return 'Free shows are capped at ${current.freeMaxStreamHours} hours. '
          'Add a ticket price for longer shows.';
    }
    if (s.contains('duration_exceeds_max')) {
      return 'Streams are capped at ${current.maxStreamHours} hours.';
    }
    return null;
  }
}
