import 'supabase_client.dart';

/// Lightweight profile shape for the Blocked accounts list.
class BlockedProfile {
  final String id;
  final String username;
  final String displayName;
  final String? avatarUrl;
  const BlockedProfile({
    required this.id,
    required this.username,
    required this.displayName,
    this.avatarUrl,
  });
  factory BlockedProfile.fromMap(Map<String, dynamic> m) => BlockedProfile(
    id: m['id'] as String,
    username: m['username'] as String,
    displayName: (m['display_name'] as String?) ?? m['username'] as String,
    avatarUrl: m['avatar_url'] as String?,
  );
}

/// Blocking is bidirectional: if A blocks B, neither sees the other anywhere.
/// RLS on posts/events/comments/follows is the security floor; the cached
/// [blockedIds] set lets discover/search filter client-side for performance.
class BlockService {
  /// Block [targetUserId]. Server trigger also purges follow edges both ways.
  static Future<void> block(String targetUserId) async {
    final myId = _requireUid();
    await supabase.from('blocks').upsert({
      'blocker_id': myId,
      'blocked_id': targetUserId,
    }, onConflict: 'blocker_id,blocked_id');
  }

  static Future<void> unblock(String targetUserId) async {
    final myId = _requireUid();
    await supabase
        .from('blocks')
        .delete()
        .eq('blocker_id', myId)
        .eq('blocked_id', targetUserId);
  }

  /// True if the current user has blocked [targetUserId] (one direction —
  /// the row the current user owns and can read under RLS).
  static Future<bool> isBlocked(String targetUserId) async {
    final myId = _requireUid();
    final row = await supabase
        .from('blocks')
        .select('blocked_id')
        .eq('blocker_id', myId)
        .eq('blocked_id', targetUserId)
        .maybeSingle();
    return row != null;
  }

  /// Ids the current user has blocked. Use to guard discover/search queries,
  /// e.g. `.not('user_id', 'in', '(${ids.join(",")})')` when non-empty.
  static Future<List<String>> blockedIds() async {
    final myId = _requireUid();
    final rows = await supabase
        .from('blocks')
        .select('blocked_id')
        .eq('blocker_id', myId);
    return (rows as List).map((r) => r['blocked_id'] as String).toList();
  }

  /// Minimal profile rows (id, username, display_name, avatar_url) for the
  /// users the current user has blocked. For the "Blocked accounts" screen.
  static Future<List<BlockedProfile>> blockedProfiles() async {
    final ids = await blockedIds();
    if (ids.isEmpty) return [];
    final rows = await supabase
        .from('profiles')
        .select('id, username, display_name, avatar_url')
        .inFilter('id', ids);
    return (rows as List)
        .map((r) => BlockedProfile.fromMap(r as Map<String, dynamic>))
        .toList();
  }

  static String _requireUid() {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('BlockService: no authenticated user');
    return uid;
  }
}
