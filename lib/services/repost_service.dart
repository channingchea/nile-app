import 'supabase_client.dart';

/// Pointer reposts: a repost is a lightweight row referencing the original post.
/// The `posts.repost_count` counter is maintained by SQL triggers, so callers
/// only insert/delete the repost row. Mirrors [LikeService].
class RepostService {
  static String _uid() {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('RepostService: no authenticated user');
    return uid;
  }

  static Future<void> repost(String postId) async {
    await supabase.from('reposts').upsert({
      'user_id': _uid(),
      'post_id': postId,
    });
  }

  static Future<void> unrepost(String postId) async {
    await supabase
        .from('reposts')
        .delete()
        .eq('user_id', _uid())
        .eq('post_id', postId);
  }

  /// Returns the subset of [postIds] the current user has reposted.
  static Future<Set<String>> getRepostedPostIds(List<String> postIds) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null || postIds.isEmpty) return <String>{};
    final rows = await supabase
        .from('reposts')
        .select('post_id')
        .eq('user_id', uid)
        .inFilter('post_id', postIds);
    return (rows as List).map((r) => r['post_id'] as String).toSet();
  }
}
