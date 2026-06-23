import 'event_service.dart';
import 'post_service.dart';
import 'supabase_client.dart';

/// A sponsored feed item: the promoted [Event] or [Post] plus the
/// [campaignId] used for impression/click logging. Exactly one of
/// [event]/[post] is non-null.
class FeedAd {
  final String campaignId;
  final Event? event;
  final Post? post;
  const FeedAd({required this.campaignId, this.event, this.post});
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
        if (r['event_id'] != null) {
          final e = byEvent[r['event_id'] as String];
          if (e != null) ads.add(FeedAd(campaignId: r['campaign_id'] as String, event: e));
        } else if (r['post_id'] != null) {
          final p = byPost[r['post_id'] as String];
          if (p != null) ads.add(FeedAd(campaignId: r['campaign_id'] as String, post: p));
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
        .select('*, profiles!events_host_id_fkey(username, avatar_url)')
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
        .select('*, profiles!posts_user_id_fkey(username, avatar_url)')
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
}
