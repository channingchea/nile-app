import 'supabase_client.dart';

/// Likes for both posts and events. Counters are maintained by SQL triggers,
/// so callers only need to insert/delete the like row.
class LikeService {
  // ── Posts ──────────────────────────────────────────────────────────────────

  static Future<void> likePost(String postId) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('LikeService: no authenticated user');
    await supabase.from('post_likes').upsert({
      'user_id': uid,
      'post_id': postId,
    });
  }

  static Future<void> unlikePost(String postId) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('LikeService: no authenticated user');
    await supabase
        .from('post_likes')
        .delete()
        .eq('user_id', uid)
        .eq('post_id', postId);
  }

  /// Returns the subset of [postIds] the current user has liked.
  static Future<Set<String>> getLikedPostIds(List<String> postIds) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null || postIds.isEmpty) return <String>{};
    final rows = await supabase
        .from('post_likes')
        .select('post_id')
        .eq('user_id', uid)
        .inFilter('post_id', postIds);
    return (rows as List).map((r) => r['post_id'] as String).toSet();
  }

  // ── Events ─────────────────────────────────────────────────────────────────

  static Future<void> likeEvent(String eventId) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('LikeService: no authenticated user');
    await supabase.from('event_likes').upsert({
      'user_id': uid,
      'event_id': eventId,
    });
  }

  static Future<void> unlikeEvent(String eventId) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('LikeService: no authenticated user');
    await supabase
        .from('event_likes')
        .delete()
        .eq('user_id', uid)
        .eq('event_id', eventId);
  }

  static Future<Set<String>> getLikedEventIds(List<String> eventIds) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null || eventIds.isEmpty) return <String>{};
    final rows = await supabase
        .from('event_likes')
        .select('event_id')
        .eq('user_id', uid)
        .inFilter('event_id', eventIds);
    return (rows as List).map((r) => r['event_id'] as String).toSet();
  }
}
