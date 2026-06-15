import 'pagination.dart';
import 'supabase_client.dart';

// ── Model ─────────────────────────────────────────────────────────────────────

class Comment {
  final String id;
  final String postId;
  final String authorId;
  final String authorUsername;
  final String? authorAvatarUrl;
  final String body;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Comment({
    required this.id,
    required this.postId,
    required this.authorId,
    required this.authorUsername,
    this.authorAvatarUrl,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Comment.fromJson(Map<String, dynamic> json) {
    final profile = (json['profiles'] as Map<String, dynamic>?) ?? {};
    return Comment(
      id: json['id'] as String,
      postId: json['post_id'] as String,
      authorId: json['user_id'] as String,
      authorUsername: profile['username'] as String? ?? 'unknown',
      authorAvatarUrl: profile['avatar_url'] as String?,
      body: json['body'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }
}

// ── Service ───────────────────────────────────────────────────────────────────

class CommentService {
  static const _select =
      '*, profiles!post_comments_user_id_fkey(username, avatar_url)';

  /// Comments on a post, newest first. Keyset-paged by created_at via [cursor].
  static Future<Paged<Comment>> listForPost(
    String postId, {
    String? cursor,
  }) async {
    var b = supabase
        .from('post_comments')
        .select(_select)
        .eq('post_id', postId);
    if (cursor != null) b = b.lt('created_at', cursor);
    final rows = await b.order('created_at', ascending: false).limit(kPageSize);
    final items = (rows as List)
        .map((r) => Comment.fromJson(r as Map<String, dynamic>))
        .toList();
    final hasMore = items.length == kPageSize;
    return Paged(
      items: items,
      hasMore: hasMore,
      nextCursor: hasMore ? items.last.createdAt.toIso8601String() : null,
    );
  }

  static Future<Comment> create({
    required String postId,
    required String body,
  }) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('CommentService: no authenticated user');
    final trimmed = body.trim();
    if (trimmed.isEmpty) throw ArgumentError('Comment cannot be empty.');

    final row = await supabase
        .from('post_comments')
        .insert({'post_id': postId, 'user_id': uid, 'body': trimmed})
        .select(_select)
        .single();

    return Comment.fromJson(row);
  }

  static Future<void> delete(String commentId) async {
    await supabase.from('post_comments').delete().eq('id', commentId);
  }
}
