import 'event_service.dart';
import 'post_service.dart';
import 'supabase_client.dart';

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
    final events = (rows as List)
        .map((r) => Event.fromJson(r as Map<String, dynamic>))
        .toList();
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

  /// Logs an ad event. Insert-only (RLS mirrors the reports policy).
  /// Best-effort: a logging failure must never disrupt the feed.
  static Future<void> _log(String campaignId, String kind) async {
    try {
      await supabase.from('ad_events').insert({
        'campaign_id': campaignId,
        'viewer_id': supabase.auth.currentUser?.id,
        'kind': kind,
      });
    } catch (_) {}
  }

  static Future<void> logImpression(String campaignId) => _log(campaignId, 'impression');
  static Future<void> logClick(String campaignId) => _log(campaignId, 'click');

  /// A soft "not interested" signal for a sponsored card. Logged like any other
  /// ad event (insert-only); never bills or affects spend (tally_ad_spend counts
  /// only impressions/clicks). Best-effort.
  static Future<void> logNotInterested(String campaignId) =>
      _log(campaignId, 'not_interested');

  /// The calling host's boost campaigns with lifetime performance (Phase A-3),
  /// newest first. Scoped server-side to auth.uid()'s own campaigns.
  static Future<List<BoostStats>> boostPerformance() async {
    final rows = await supabase.rpc('get_boost_performance');
    return (rows as List)
        .map((r) => BoostStats.fromJson(r as Map<String, dynamic>))
        .toList();
  }
}
