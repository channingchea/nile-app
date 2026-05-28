import 'package:supabase_flutter/supabase_flutter.dart';
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

  /// Returns profiles of users who follow [userId].
  static Future<List<Map<String, dynamic>>> getFollowers(String userId) async {
    final rows = await supabase
        .from('follows')
        .select('profile:profiles!follower_id(*)')
        .eq('following_id', userId);
    return (rows as List)
        .map((r) => r['profile'] as Map<String, dynamic>)
        .toList();
  }

  /// Returns profiles of users that [userId] follows.
  static Future<List<Map<String, dynamic>>> getFollowing(String userId) async {
    final rows = await supabase
        .from('follows')
        .select('profile:profiles!following_id(*)')
        .eq('follower_id', userId);
    return (rows as List)
        .map((r) => r['profile'] as Map<String, dynamic>)
        .toList();
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  static String _requireUid() {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('FollowService: no authenticated user');
    return uid;
  }
}
