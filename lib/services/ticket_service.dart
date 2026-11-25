import 'checkout_origin.dart';
import 'event_service.dart';
import 'pagination.dart';
import 'supabase_client.dart';

// ── Model ─────────────────────────────────────────────────────────────────────

class Ticket {
  final String id;
  final String eventId;
  final String buyerId;
  final String stripePaymentIntentId;
  final int amountCents;
  final String status; // 'pending' | 'paid' | 'refunded'
  final DateTime createdAt;

  const Ticket({
    required this.id,
    required this.eventId,
    required this.buyerId,
    required this.stripePaymentIntentId,
    required this.amountCents,
    required this.status,
    required this.createdAt,
  });

  bool get isPaid => status == 'paid';

  factory Ticket.fromJson(Map<String, dynamic> j) => Ticket(
    id: j['id'] as String,
    eventId: j['event_id'] as String,
    buyerId: j['buyer_id'] as String,
    stripePaymentIntentId: j['stripe_payment_intent_id'] as String,
    amountCents: (j['amount_cents'] as num).toInt(),
    status: j['status'] as String,
    createdAt: DateTime.parse(j['created_at'] as String),
  );
}

/// A buyer's ticket paired with its event (for the My Tickets screen).
class MyTicket {
  final Ticket ticket;
  final Event? event;

  const MyTicket({required this.ticket, required this.event});

  factory MyTicket.fromJson(Map<String, dynamic> j) {
    final ev = j['events'] as Map<String, dynamic>?;
    return MyTicket(
      ticket: Ticket.fromJson(j),
      event: ev == null ? null : Event.fromJson(ev),
    );
  }
}

// ── Service ───────────────────────────────────────────────────────────────────

class TicketService {
  /// Returns true if the current user has a paid ticket for [eventId].
  static Future<bool> hasPurchased(String eventId) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return false;

    final rows = await supabase
        .from('tickets')
        .select('id')
        .eq('event_id', eventId)
        .eq('buyer_id', uid)
        .eq('status', 'paid')
        .limit(1);

    return (rows as List).isNotEmpty;
  }

  /// Calls the Edge Function to create a Stripe Checkout Session.
  /// Returns the hosted checkout URL to open in a browser. Price and title are
  /// read server-side from the event — the client can't set them.
  /// [kind] is 'live' (default) or 'replay' (Phase 2 VOD purchase).
  static Future<String> createCheckoutUrl({
    required String eventId,
    String kind = 'live',
  }) async {
    final response = await supabase.functions.invoke(
      'create-payment-intent',
      body: {
        'event_id': eventId,
        'kind': kind,
        'origin': NileCheckoutOrigin.current,
      },
    );

    if (response.status != 200) {
      final msg = (response.data as Map?)?['error'] ?? 'Payment error';
      throw Exception(msg);
    }

    final url = (response.data as Map)['checkout_url'] as String?;
    if (url == null) throw Exception('No checkout URL returned');
    return url;
  }

  /// Returns remaining ticket count: null = unlimited, 0 = sold out, N = available.
  static Future<int?> ticketsRemaining(String eventId) async {
    final result = await supabase.rpc(
      'tickets_remaining',
      params: {'p_event_id': eventId},
    );
    return result as int?;
  }

  /// Tickets for the current user (any status) with the full event joined,
  /// newest first. Keyset-paged by created_at via [cursor]. RLS
  /// `tickets_select_own` scopes this to the current buyer.
  static Future<Paged<MyTicket>> myTickets({String? cursor}) async {
    var b = supabase
        .from('tickets')
        .select(
          '*, events!tickets_event_id_fkey('
          '*, profiles!events_host_id_fkey(username, avatar_url, is_official))',
        );
    if (cursor != null) b = b.lt('created_at', cursor);
    final rows = await b.order('created_at', ascending: false).limit(kPageSize);

    final raw = (rows as List)
        .map((r) => MyTicket.fromJson(r as Map<String, dynamic>))
        .toList();
    // hasMore / cursor based on the raw page so paging stays correct even
    // when event-less tickets are filtered out.
    final hasMore = raw.length == kPageSize;
    final nextCursor = hasMore
        ? raw.last.ticket.createdAt.toIso8601String()
        : null;
    final items = raw.where((t) => t.event != null).toList();
    return Paged(items: items, hasMore: hasMore, nextCursor: nextCursor);
  }

  /// Gross, net and head-count for one event's paid tickets, across every page.
  ///
  /// The Attendee list used to sum the loaded page and label it "revenue",
  /// which was gross — while the Payouts screen showed net. Same sales, two
  /// numbers, no explanation on either screen. This is host-only (migration
  /// 0094 checks host_id server-side).
  static Future<({int grossCents, int netCents, int feeCents, int paidCount})>
  eventTotals(String eventId) async {
    final rows = await supabase.rpc(
      'host_event_ticket_totals',
      params: {'p_event_id': eventId},
    );
    final list = rows as List;
    if (list.isEmpty) {
      return (grossCents: 0, netCents: 0, feeCents: 0, paidCount: 0);
    }
    final r = list.first as Map<String, dynamic>;
    return (
      grossCents: (r['gross_cents'] as num?)?.toInt() ?? 0,
      netCents: (r['net_cents'] as num?)?.toInt() ?? 0,
      feeCents: (r['fee_cents'] as num?)?.toInt() ?? 0,
      paidCount: (r['paid_count'] as num?)?.toInt() ?? 0,
    );
  }

  /// Attendees for [eventId] with buyer profiles joined, newest first.
  /// Keyset-paged by created_at via [cursor]. Includes paid and refunded
  /// tickets (pending hidden). RLS (`tickets_select_host`) restricts to host.
  static Future<Paged<Attendee>> attendees(
    String eventId, {
    String? cursor,
  }) async {
    var b = supabase
        .from('tickets')
        .select(
          'id, amount_cents, created_at, status, '
          'profiles!tickets_buyer_id_fkey(id, username, avatar_url)',
        )
        .eq('event_id', eventId)
        .inFilter('status', ['paid', 'refunded', 'disputed']);
    if (cursor != null) b = b.lt('created_at', cursor);
    final rows = await b.order('created_at', ascending: false).limit(kPageSize);

    final items = (rows as List)
        .map((r) => Attendee.fromJson(r as Map<String, dynamic>))
        .toList();
    final hasMore = items.length == kPageSize;
    return Paged(
      items: items,
      hasMore: hasMore,
      nextCursor: hasMore ? items.last.purchasedAt.toIso8601String() : null,
    );
  }

  /// Refund a single ticket. The Edge Function authorizes the caller as either
  /// the event host (any time) or the buyer (only inside the disclosed
  /// cancellation window — see services/money.dart), then issues the Stripe
  /// refund; the ticket flips to 'refunded' (optimistically server-side,
  /// confirmed by webhook).
  ///
  /// Throws with the server's own message when the window has closed, so
  /// callers can surface it verbatim rather than inventing their own wording.
  static Future<void> refund(String ticketId) async {
    final response = await supabase.functions.invoke(
      'refund-ticket',
      body: {'ticket_id': ticketId},
    );
    if (response.status != 200) {
      throw Exception((response.data as Map?)?['error'] ?? 'Refund failed');
    }
  }
}

// ── Attendee model ──────────────────────────────────────────────────────────────

class Attendee {
  final String ticketId;
  final String buyerId;
  final String username;
  final String? avatarUrl;
  final int amountCents;
  final String status; // 'paid' | 'refunded' | 'disputed'
  final DateTime purchasedAt;

  const Attendee({
    required this.ticketId,
    required this.buyerId,
    required this.username,
    required this.avatarUrl,
    required this.amountCents,
    required this.status,
    required this.purchasedAt,
  });

  bool get isRefunded => status == 'refunded';

  /// A chargeback: the buyer's bank pulled the money back. Access is revoked
  /// exactly like a refund, but the host can't refund it again and it isn't
  /// their decision — so it reads differently on screen.
  bool get isDisputed => status == 'disputed';

  /// Not a live entitlement any more, whichever way it ended. Head-counts,
  /// revenue, and the refund action all key on this rather than on 'refunded'.
  bool get isVoid => status != 'paid';

  /// True once the buyer deleted their account: migration 0118 nulls
  /// `tickets.buyer_id` and the profile join comes back empty, while the sale
  /// itself stays on the host's books.
  bool get isDeletedBuyer => buyerId.isEmpty;

  factory Attendee.fromJson(Map<String, dynamic> j) {
    final p = (j['profiles'] as Map<String, dynamic>?) ?? const {};
    return Attendee(
      ticketId: j['id'] as String,
      buyerId: p['id'] as String? ?? '',
      username: p['username'] as String? ?? 'deleted account',
      avatarUrl: p['avatar_url'] as String?,
      amountCents: (j['amount_cents'] as num).toInt(),
      status: j['status'] as String? ?? 'paid',
      purchasedAt: DateTime.parse(j['created_at'] as String),
    );
  }
}
