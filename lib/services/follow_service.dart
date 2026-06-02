import 'package:supabase_flutter/supabase_flutter.dart';
import 'pagination.dart';
import 'profile_service.dart';
import 'supabase_client.dart';

/// Manages follow / unfollow operations and social-graph queries.
///
/// All methods require an authenticated user and will throw if the
/// current session is absent.
class FollowService {
  // ─── Follow / Unfollow ────────────────────────────────────────────────────

  /// Follow [targetUserId]. No-ops silently if already following.
  static Future<void> follow(String targetUserId) async {
    final myId = _requireUid();
    try {
      await supabase.from('follows').insert({
        'follower_id': myId,
        'following_id': targetUserId,
      });
    } on PostgrestException catch (e) {
      // 23505 = unique_violation — already following, nothing to do.
      if (e.code != '23505') rethrow;
    }
  }

  /// Unfollow [targetUserId]. No-ops silently if not following.
  static Future<void> unfollow(String targetUserId) async {
    final myId = _requireUid();
    await supabase
        .from('follows')
        .delete()
        .eq('follower_id', myId)
        .eq('following_id', targetUserId);
  }

  // ─── Query ────────────────────────────────────────────────────────────────

  /// Returns true if the signed-in user currently follows [targetUserId].
  static Future<bool> isFollowing(String targetUserId) async {
    final myId = _requireUid();
    final data = await supabase
        .from('follows')
        .select('follower_id')
        .eq('follower_id', myId)
        .eq('following_id', targetUserId)
        .maybeSingle();
    return data != null;
  }

  /// Returns the list of user IDs that the signed-in user follows.
  ///
  /// Used by Phase 4 to build the home feed query:
  /// `select * from posts where author_id = any(:followingIds)`
  static Future<List<String>> getFollowingIds() async {
    final myId = _requireUid();
    final rows = await supabase
        .from('follows')
        .select('following_id')
        .eq('follower_id', myId);

    return (rows as List)
        .map((r) => r['following_id'] as String)
        .toList();
  }

  // ─── Lists ────────────────────────────────────────────────────────────────

  /// Profiles of users who follow [userId], newest follow first.
  /// Keyset-paged on follows.created_at via [cursor].
  static Future<Paged<UserProfile>> getFollowers(String userId,
          {String? cursor}) =>
      _pagedFollows(
        column: 'following_id',
        value: userId,
        profileJoin: 'profile:profiles!follower_id(*)',
        cursor: cursor,
      );

  /// Profiles of users that [userId] follows, newest follow first.
  /// Keyset-paged on follows.created_at via [cursor].
  static Future<Paged<UserProfile>> getFollowing(String userId,
          {String? cursor}) =>
      _pagedFollows(
        column: 'follower_id',
        value: userId,
        profileJoin: 'profile:profiles!following_id(*)',
        cursor: cursor,
      );

  static Future<Paged<UserProfile>> _pagedFollows({
    required String column,
    required String value,
    required String profileJoin,
    String? cursor,
  }) async {
    var b = supabase
        .from('follows')
        .select('created_at, $profileJoin')
        .eq(column, value);
    if (cursor != null) b = b.lt('created_at', cursor);
    final rows =
        await b.order('created_at', ascending: false).limit(kPageSize);

    final list = rows as List;
    final items = list
        .map((r) => UserProfile.fromMap(r['profile'] as Map<String, dynamic>))
        .toList();
    final hasMore = list.length == kPageSize;
    final nextCursor =
        hasMore ? list.last['created_at'] as String : null;
    return Paged(items: items, hasMore: hasMore, nextCursor: nextCursor);
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  static String _requireUid() {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('FollowService: no authenticated user');
    return uid;
  }
}
