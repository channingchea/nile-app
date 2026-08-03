import 'pagination.dart';
import 'profile_service.dart' show UserProfile;
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

  // ── Liker lists ────────────────────────────────────────────────────────────

  /// Profiles of users who liked [postId], newest like first.
  /// Public — RLS allows anyone to read like rows.
  static Future<Paged<UserProfile>> getPostLikers(
    String postId, {
    String? cursor,
  }) => _pagedLikers(
    table: 'post_likes',
    column: 'post_id',
    fk: 'post_likes_user_id_fkey',
    value: postId,
    cursor: cursor,
  );

  /// Profiles of users who liked [eventId], newest like first.
  static Future<Paged<UserProfile>> getEventLikers(
    String eventId, {
    String? cursor,
  }) => _pagedLikers(
    table: 'event_likes',
    column: 'event_id',
    fk: 'event_likes_user_id_fkey',
    value: eventId,
    cursor: cursor,
  );

  /// Keyset-paged on `created_at` — [cursor] is the previous page's last
  /// like timestamp.
  static Future<Paged<UserProfile>> _pagedLikers({
    required String table,
    required String column,
    required String fk,
    required String value,
    String? cursor,
  }) async {
    var b = supabase
        .from(table)
        .select('created_at, profile:profiles!$fk(*)')
        .eq(column, value);
    if (cursor != null) b = b.lt('created_at', cursor);
    final rows = await b.order('created_at', ascending: false).limit(kPageSize);

    final list = rows as List;
    final items = <UserProfile>[];
    for (final r in list) {
      final p = r['profile'];
      // Defensive: a deleted profile leaves a dangling row until cascade runs.
      if (p is Map<String, dynamic>) items.add(UserProfile.fromMap(p));
    }
    final hasMore = list.length == kPageSize;
    final nextCursor = hasMore ? list.last['created_at'] as String : null;
    return Paged(items: items, hasMore: hasMore, nextCursor: nextCursor);
  }
}
