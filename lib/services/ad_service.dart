import 'event_service.dart';
import 'post_service.dart';
import 'supabase_client.dart';

/// A Currents video ad (docs/plans/currents.md, Phase 4): a self-uploaded ≤60s
/// video + headline + CTA served between Currents in the vertical player.
class CurrentAd {
  final String campaignId;
  final String videoUrl;
  final String? thumbUrl;
  final String headline;
  final String? body;
  final String clickUrl;
  final String advertiserName;
  final int durationMs;
  const CurrentAd({
    required this.campaignId,
    required this.videoUrl,
    this.thumbUrl,
    required this.headline,
    this.body,
    required this.clickUrl,
    required this.advertiserName,
    required this.durationMs,
  });
}

/// An event sponsorship creative for the Pre-Show lobby (0079): the single
/// active lobby campaign for an event — a full-bleed image or looping muted
/// video shown while the host is in Sound Check.
class LobbySponsorship {
  final String campaignId;
  final String kind; // 'image' | 'video'
  final String? imageUrl;
  final String? videoUrl;
  final String? thumbUrl;
  final int durationMs;
  final String headline;
  final String clickUrl;
  final String advertiserName;

  /// Accepted by the host's auto-accept rule rather than by hand (0098). Only
  /// ever shown to the host — to a viewer it's a disclaimer about a decision
  /// that wasn't theirs.
  final bool autoAccepted;
  const LobbySponsorship({
    required this.campaignId,
    required this.kind,
    this.imageUrl,
    this.videoUrl,
    this.thumbUrl,
    required this.durationMs,
    required this.headline,
    required this.clickUrl,
    required this.advertiserName,
    this.autoAccepted = false,
  });

  /// A `get_lobby_sponsorship` row. Video/thumb arrive as bucket-relative paths
  /// in `ad-videos` and become public URLs here.
  factory LobbySponsorship.fromRow(Map<String, dynamic> r) {
    final videoPath = r['video_path'] as String?;
    return LobbySponsorship(
      campaignId: r['campaign_id'] as String,
      kind: r['kind'] as String? ?? 'image',
      imageUrl: r['image_url'] as String?,
      videoUrl: videoPath != null
          ? supabase.storage.from('ad-videos').getPublicUrl(videoPath)
          : null,
      thumbUrl: r['thumb_path'] != null
          ? supabase.storage
                .from('ad-videos')
                .getPublicUrl(r['thumb_path'] as String)
          : null,
      durationMs: (r['duration_ms'] as num?)?.toInt() ?? 0,
      headline: r['headline'] as String? ?? '',
      clickUrl: r['click_url'] as String? ?? '',
      advertiserName: (r['advertiser_name'] as String?) ?? 'Sponsored',
      // Absent on a client talking to the pre-0098 RPC. Defaulting to false
      // matters: the label claims a decision the host didn't make.
      autoAccepted: r['auto_accepted'] as bool? ?? false,
    );
  }
}

/// One advertiser's bid to sponsor one of the caller's events
/// (`host_sponsorship_offers`, migration 0097).
///
/// [status] is either `pending_host` — Nile has screened the creative for
/// policy and the host now owns the brand-fit decision — or `payment_pending`,
/// where the accept charge is stuck at the advertiser's bank and there is
/// nothing for the host to do but wait.
class SponsorshipOffer {
  final String campaignId;
  final String eventId;
  final String eventTitle;
  final DateTime? scheduledAt;
  final String advertiserName;
  final int budgetCents;
  final int hostNetCents;
  final String status;
  final String kind; // 'image' | 'video'
  final String? imageUrl;
  final String? videoUrl;
  final String? thumbUrl;
  final int durationMs;
  final String headline;
  final String? body;
  final String clickUrl;
  final DateTime offerExpiresAt;

  const SponsorshipOffer({
    required this.campaignId,
    required this.eventId,
    required this.eventTitle,
    this.scheduledAt,
    required this.advertiserName,
    required this.budgetCents,
    required this.hostNetCents,
    required this.status,
    required this.kind,
    this.imageUrl,
    this.videoUrl,
    this.thumbUrl,
    required this.durationMs,
    required this.headline,
    this.body,
    required this.clickUrl,
    required this.offerExpiresAt,
  });

  /// The host can accept or decline. False for `payment_pending`, which renders
  /// read-only.
  bool get isActionable => status == 'pending_host';

  bool get isPaymentPending => status == 'payment_pending';

  /// Bare host of the click-through ("nikeshoes.com"), with any `www.` dropped.
  /// The host is deciding whose logo sits in front of their audience; a full
  /// tracking URL is something they'd have to parse to answer that.
  String? get clickDomain {
    final host = Uri.tryParse(clickUrl)?.host ?? '';
    if (host.isEmpty) return null;
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  Duration timeLeftFrom(DateTime now) => offerExpiresAt.difference(now);

  String expiresLabel({DateTime? now}) =>
      expiresLabelFor(offerExpiresAt, now: now);

  /// "2 days left" / "5 hours left" / "Expired". Coarse on purpose: a
  /// to-the-second countdown on a 48-hour fuse reads as pressure rather than
  /// information, and the offer is worth the same at 47h as at 3h.
  ///
  /// Static so the event page can label the soonest expiry across several
  /// offers without picking one of them to ask.
  static String expiresLabelFor(DateTime expiresAt, {DateTime? now}) {
    final left = expiresAt.difference(now ?? DateTime.now());
    if (left <= Duration.zero) return 'Expired';
    if (left.inDays >= 1) {
      return '${left.inDays} ${left.inDays == 1 ? 'day' : 'days'} left';
    }
    if (left.inHours >= 1) {
      return '${left.inHours} ${left.inHours == 1 ? 'hour' : 'hours'} left';
    }
    final mins = left.inMinutes < 1 ? 1 : left.inMinutes;
    return '$mins ${mins == 1 ? 'minute' : 'minutes'} left';
  }

  /// Under a day left. Drives the card's urgent colour — the point at which the
  /// `sponsorship_offer_expiring` nudge has also gone out.
  bool get isUrgent {
    final left = timeLeftFrom(DateTime.now());
    return left > Duration.zero && left < const Duration(hours: 24);
  }

  factory SponsorshipOffer.fromJson(Map<String, dynamic> j) {
    // Same bucket and the same public-URL construction as [LobbySponsorship] —
    // the creative a host approves here is byte-for-byte the one that plays in
    // the lobby.
    String? publicUrl(String? path) => path == null
        ? null
        : supabase.storage.from('ad-videos').getPublicUrl(path);
    return SponsorshipOffer(
      campaignId: j['campaign_id'] as String,
      eventId: j['event_id'] as String,
      eventTitle: j['event_title'] as String? ?? 'Untitled event',
      scheduledAt: j['scheduled_at'] != null
          ? DateTime.parse(j['scheduled_at'] as String)
          : null,
      advertiserName: (j['advertiser_name'] as String?) ?? 'A brand',
      budgetCents: (j['budget_cents'] as num?)?.toInt() ?? 0,
      hostNetCents: (j['host_net_cents'] as num?)?.toInt() ?? 0,
      status: j['status'] as String? ?? 'pending_host',
      kind: j['kind'] as String? ?? 'image',
      imageUrl: j['image_url'] as String?,
      videoUrl: publicUrl(j['video_path'] as String?),
      thumbUrl: publicUrl(j['thumb_path'] as String?),
      durationMs: (j['duration_ms'] as num?)?.toInt() ?? 0,
      headline: j['headline'] as String? ?? '',
      body: j['body'] as String?,
      clickUrl: j['click_url'] as String? ?? '',
      offerExpiresAt: DateTime.parse(j['offer_expires_at'] as String),
    );
  }

  /// Groups offers under the event they're bidding on, preserving the RPC's
  /// order (soonest event first, then highest amount). Competing offers on one
  /// event only make sense side by side — accepting one declines the rest.
  static List<SponsorshipOfferGroup> groupByEvent(
    List<SponsorshipOffer> offers,
  ) {
    final byEvent = <String, List<SponsorshipOffer>>{};
    for (final o in offers) {
      (byEvent[o.eventId] ??= <SponsorshipOffer>[]).add(o);
    }
    return [
      for (final entry in byEvent.entries)
        SponsorshipOfferGroup(
          eventId: entry.key,
          eventTitle: entry.value.first.eventTitle,
          scheduledAt: entry.value.first.scheduledAt,
          offers: entry.value,
        ),
    ];
  }
}

/// One event's competing offers — a section header plus its cards.
class SponsorshipOfferGroup {
  final String eventId;
  final String eventTitle;
  final DateTime? scheduledAt;
  final List<SponsorshipOffer> offers;
  const SponsorshipOfferGroup({
    required this.eventId,
    required this.eventTitle,
    this.scheduledAt,
    required this.offers,
  });
}

/// A starting number for the host's minimum ask (`suggest_sponsorship_price`,
/// migration 0097), plus the [basis] line that says where it came from.
///
/// Show [basis] verbatim. "4 past events" and "estimated from follower count"
/// are the difference between a measurement and a guess, and the host is
/// setting a price floor on the strength of it.
class PriceSuggestion {
  final int suggestedCents;
  final int lowCents;
  final int highCents;
  final String basis;
  const PriceSuggestion({
    required this.suggestedCents,
    required this.lowCents,
    required this.highCents,
    required this.basis,
  });
}

/// Platform bounds on a sponsorship offer, mirroring `app_config`. Config, not
/// constants, because retuning them is meant to be a row update rather than a
/// release.
typedef SponsorshipBounds = ({int minCents, int maxCents});

/// A standalone advertiser creative (Phase A-4): a self-uploaded image +
/// headline + body that opens an external [clickUrl], referencing no event/post.
class AdCreative {
  final String imageUrl;
  final String headline;
  final String body;
  final String clickUrl;
  final String advertiserName;
  const AdCreative({
    required this.imageUrl,
    required this.headline,
    required this.body,
    required this.clickUrl,
    required this.advertiserName,
  });
}

/// A sponsored feed item: the promoted [Event] or [Post] (host boost), or a
/// standalone [creative] (external advertiser), plus the [campaignId] used for
/// impression/click logging. Exactly one of [event]/[post]/[creative] is set.
class FeedAd {
  final String campaignId;
  final Event? event;
  final Post? post;
  final AdCreative? creative;
  const FeedAd({required this.campaignId, this.event, this.post, this.creative});
}

/// One campaign's lifetime performance (Phase A-3), as returned by the
/// get_boost_performance RPC. Spend/budget are cents; [ctr] is 0–1.
class BoostStats {
  final String campaignId;
  final String name;
  final String? eventId;
  final String status;
  final int budgetCents;
  final int spentCents;
  final DateTime startsAt;
  final DateTime endsAt;
  final int impressions;
  final int clicks;

  const BoostStats({
    required this.campaignId,
    required this.name,
    required this.eventId,
    required this.status,
    required this.budgetCents,
    required this.spentCents,
    required this.startsAt,
    required this.endsAt,
    required this.impressions,
    required this.clicks,
  });

  double get ctr => impressions == 0 ? 0 : clicks / impressions;

  factory BoostStats.fromJson(Map<String, dynamic> j) => BoostStats(
        campaignId: j['campaign_id'] as String,
        name: j['name'] as String,
        eventId: j['event_id'] as String?,
        status: j['status'] as String,
        budgetCents: (j['budget_cents'] as num).toInt(),
        spentCents: (j['spent_cents'] as num).toInt(),
        startsAt: DateTime.parse(j['starts_at'] as String),
        endsAt: DateTime.parse(j['ends_at'] as String),
        impressions: (j['impressions'] as num).toInt(),
        clicks: (j['clicks'] as num).toInt(),
      );
}

/// Serves and logs in-feed sponsored content (Phase A-1). Mirrors the
/// recommend_* pattern in [SearchService]: the get_feed_ads RPC returns the
/// campaign + target ids, and we hydrate the existing event/post card payloads.
class AdService {
  /// Active campaigns to inject for the current viewer, in serving order.
  ///
  /// Serving order is a fresh weighted draw on every call (migration 0115), not
  /// a stable ranking — it used to be "newest five", which meant the sixth
  /// advertiser to buy a boost never appeared at all. Don't cache these or
  /// assume two calls agree.
  ///
  /// Best-effort: returns [] on any failure so the feed never breaks.
  static Future<List<FeedAd>> feedAds({int limit = 5}) async {
    try {
      final rows = await supabase.rpc('get_feed_ads', params: {'page_limit': limit});
      final list = (rows as List).cast<Map<String, dynamic>>();
      if (list.isEmpty) return [];

      final eventIds = <String, String>{}; // event_id -> campaign_id
      final postIds = <String, String>{}; // post_id  -> campaign_id
      for (final r in list) {
        final campaign = r['campaign_id'] as String;
        if (r['event_id'] != null) eventIds[r['event_id'] as String] = campaign;
        if (r['post_id'] != null) postIds[r['post_id'] as String] = campaign;
      }

      final (events, posts) = await (
        _hydrateEvents(eventIds.keys.toList()),
        _hydratePosts(postIds.keys.toList()),
      ).wait;

      final byEvent = {for (final e in events) e.id: e};
      final byPost = {for (final p in posts) p.id: p};

      // Preserve the RPC's serving order.
      final ads = <FeedAd>[];
      for (final r in list) {
        final campaign = r['campaign_id'] as String;
        if (r['event_id'] != null) {
          final e = byEvent[r['event_id'] as String];
          if (e != null) ads.add(FeedAd(campaignId: campaign, event: e));
        } else if (r['post_id'] != null) {
          final p = byPost[r['post_id'] as String];
          if (p != null) ads.add(FeedAd(campaignId: campaign, post: p));
        } else if (r['image_url'] != null) {
          ads.add(FeedAd(
            campaignId: campaign,
            creative: AdCreative(
              imageUrl: r['image_url'] as String,
              headline: r['headline'] as String,
              body: r['body'] as String,
              clickUrl: r['click_url'] as String,
              advertiserName: (r['advertiser_name'] as String?) ?? 'Sponsored',
            ),
          ));
        }
      }
      return ads;
    } catch (_) {
      return [];
    }
  }

  static Future<List<Event>> _hydrateEvents(List<String> ids) async {
    if (ids.isEmpty) return [];
    final rows = await supabase
        .from('events')
        .select('*, profiles!events_host_id_fkey(username, avatar_url, is_official)')
        .inFilter('id', ids);
    // A 14-day boost on a show that ended on day 3 kept rendering — and kept
    // billing the host for impressions on it. Dropping the card here stops the
    // impression, since nothing is shown to record.
    final events = EventService.dropOver(
      (rows as List).map((r) => Event.fromJson(r as Map<String, dynamic>)),
    );
    return EventService.hydrateLikes(events);
  }

  static Future<List<Post>> _hydratePosts(List<String> ids) async {
    if (ids.isEmpty) return [];
    final rows = await supabase
        .from('posts')
        .select('*, profiles!posts_user_id_fkey(username, avatar_url, is_official)')
        .inFilter('id', ids);
    final posts = (rows as List)
        .map((r) => Post.fromJson(r as Map<String, dynamic>))
        .toList();
    return PostService.hydrateLikes(posts);
  }

  /// Logs an ad event through `log_ad_event` (migration 0114). Clients no
  /// longer have INSERT on `ad_events` at all — the old policy let any caller
  /// name any campaign, and the anon key alone was enough to write, so every
  /// impression and click number an advertiser saw was forgeable.
  ///
  /// The RPC decides whether the caller could plausibly have seen this ad and
  /// returns a status instead of raising; it silently declines a click with no
  /// impression behind it, a viewer past the daily frequency cap, a campaign
  /// that is no longer serving, and a repeat within the same hour.
  ///
  /// Best-effort: a logging failure must never disrupt the feed.
  static Future<void> _log(String campaignId, String kind) async {
    try {
      await supabase.rpc(
        'log_ad_event',
        params: {'p_campaign_id': campaignId, 'p_kind': kind},
      );
    } catch (_) {}
  }

  static Future<void> logImpression(String campaignId) => _log(campaignId, 'impression');
  static Future<void> logClick(String campaignId) => _log(campaignId, 'click');

  /// The active sponsorship for an event's Pre-Show lobby, if any (0079
  /// get_lobby_sponsorship). Best-effort: null on any failure so the lobby
  /// falls back to the event cover.
  static Future<LobbySponsorship?> lobbySponsorship(String eventId) async {
    try {
      final rows = await supabase
          .rpc('get_lobby_sponsorship', params: {'p_event_id': eventId});
      final list = (rows as List).cast<Map<String, dynamic>>();
      if (list.isEmpty) return null;
      return LobbySponsorship.fromRow(list.first);
    } catch (_) {
      return null;
    }
  }

  /// A soft "not interested" signal for a sponsored card. Logged like any other
  /// ad event; never bills or affects spend (tally_ad_spend counts only
  /// impressions). Unlike an impression it is still accepted for a campaign
  /// that has stopped serving — otherwise "don't show me this again" would fail
  /// silently on a paused ad and come back the moment it resumed.
  /// Best-effort.
  static Future<void> logNotInterested(String campaignId) =>
      _log(campaignId, 'not_interested');

  /// Active Currents video-ad campaigns for this viewer, in serving order.
  /// Mirrors [feedAds]: the get_currents_ads RPC returns campaign + creative
  /// columns; video/thumb paths live in the ad-videos bucket (0068).
  /// Best-effort: [] on any failure so the player never breaks.
  static Future<List<CurrentAd>> currentsAds({int limit = 5}) async {
    try {
      final rows =
          await supabase.rpc('get_currents_ads', params: {'page_limit': limit});
      final ads = <CurrentAd>[];
      for (final r in (rows as List).cast<Map<String, dynamic>>()) {
        final videoPath = r['video_path'] as String?;
        if (videoPath == null) continue;
        ads.add(CurrentAd(
          campaignId: r['campaign_id'] as String,
          videoUrl:
              supabase.storage.from('ad-videos').getPublicUrl(videoPath),
          thumbUrl: r['thumb_path'] != null
              ? supabase.storage
                  .from('ad-videos')
                  .getPublicUrl(r['thumb_path'] as String)
              : null,
          headline: r['headline'] as String? ?? '',
          body: r['body'] as String?,
          clickUrl: r['click_url'] as String? ?? '',
          advertiserName: (r['advertiser_name'] as String?) ?? 'Sponsored',
          durationMs: (r['duration_ms'] as num?)?.toInt() ?? 0,
        ));
      }
      return ads;
    } catch (_) {
      return [];
    }
  }

  /// Server-tunable ad cadence for the Currents player: one ad slot after every
  /// Nth Current. Falls back to 5 on any failure.
  static Future<int> currentsAdFrequency() async {
    try {
      final rows = await supabase
          .from('app_config')
          .select('currents_ad_frequency')
          .eq('id', 1)
          .limit(1);
      final v = (rows as List).isEmpty
          ? null
          : (rows.first['currents_ad_frequency'] as num?)?.toInt();
      return (v == null || v < 1) ? 5 : v;
    } catch (_) {
      return 5;
    }
  }

  /// The calling host's boost campaigns with lifetime performance (Phase A-3),
  /// newest first. Scoped server-side to auth.uid()'s own campaigns.
  static Future<List<BoostStats>> boostPerformance() async {
    final rows = await supabase.rpc('get_boost_performance');
    return (rows as List)
        .map((r) => BoostStats.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  // ── Host-approved sponsorships (0096/0097) ──────────────────────────────────

  /// Every open offer on the caller's events, soonest event first then highest
  /// amount. SECURITY DEFINER server-side — RLS hides `ad_campaigns` from hosts.
  ///
  /// Throws, unlike the best-effort feed methods above. This is the one screen
  /// where a swallowed error would show "no offers" to a host who has money on
  /// a 48-hour fuse, and they would never know to look again.
  static Future<List<SponsorshipOffer>> hostOffers() async {
    final rows = await supabase.rpc('host_sponsorship_offers');
    return (rows as List)
        .map((r) => SponsorshipOffer.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Unexpired offers awaiting the host's decision. Best-effort: this feeds a
  /// badge, and a badge that fails is better silent than loud.
  static Future<int> hostOfferCount() async {
    try {
      final v = await supabase.rpc('host_sponsorship_offer_count');
      return (v as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Accept or decline an offer. Accepting charges the advertiser's saved card
  /// immediately and locks the event, so the server does the work; [note] is
  /// the host's comment, which the advertiser sees either way.
  static Future<void> respondToOffer({
    required String campaignId,
    required bool accept,
    String? note,
  }) async {
    final response = await supabase.functions.invoke(
      'respond-sponsorship-offer',
      body: {
        'campaign_id': campaignId,
        'accept': accept,
        if (note != null && note.isNotEmpty) 'note': note,
      },
    );
    if (response.status != 200) {
      // The failures worth reading are the advertiser's bank declining and the
      // offer having expired under the host — both need the server's words.
      throw Exception(
        (response.data as Map?)?['error'] ?? "Couldn't send your response",
      );
    }
  }

  /// A suggested minimum ask for [eventId]. Best-effort: null on failure, and
  /// the field falls back to the platform floor rather than blocking the form.
  static Future<PriceSuggestion?> suggestSponsorshipPrice(
    String eventId,
  ) async {
    try {
      final rows = await supabase.rpc(
        'suggest_sponsorship_price',
        params: {'p_event_id': eventId},
      );
      final list = (rows as List).cast<Map<String, dynamic>>();
      if (list.isEmpty) return null;
      final r = list.first;
      final suggested = (r['suggested_cents'] as num?)?.toInt();
      final basis = r['basis'] as String?;
      if (suggested == null || basis == null) return null;
      return PriceSuggestion(
        suggestedCents: suggested,
        lowCents: (r['low_cents'] as num?)?.toInt() ?? suggested,
        highCents: (r['high_cents'] as num?)?.toInt() ?? suggested,
        basis: basis,
      );
    } catch (_) {
      return null;
    }
  }

  /// Platform floor/ceiling for an offer amount, for client-side validation.
  /// Falls back to the shipped config values so the form still validates
  /// offline; the server rejects anything outside them regardless.
  static Future<SponsorshipBounds> sponsorshipBounds() async {
    const fallback = (minCents: 2500, maxCents: 250000);
    try {
      final rows = await supabase
          .from('app_config')
          .select('sponsorship_min_offer_cents, sponsorship_max_offer_cents')
          .eq('id', 1)
          .limit(1);
      if (rows.isEmpty) return fallback;
      final r = rows.first;
      return (
        minCents:
            (r['sponsorship_min_offer_cents'] as num?)?.toInt() ??
            fallback.minCents,
        maxCents:
            (r['sponsorship_max_offer_cents'] as num?)?.toInt() ??
            fallback.maxCents,
      );
    } catch (_) {
      return fallback;
    }
  }
}
