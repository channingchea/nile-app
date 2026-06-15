import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'like_service.dart';
import 'pagination.dart';
import 'repost_service.dart';
import 'supabase_client.dart';

// ── Model ─────────────────────────────────────────────────────────────────────

class Post {
  final String id;
  final String authorId; // maps to posts.user_id
  final String authorUsername;
  final String? authorAvatarUrl;
  final String? content; // maps to posts.content (the caption/body)
  final String? imageUrl;
  final int likeCount;
  final int commentCount;
  final int repostCount;
  final String? eventId; // optional link to an event
  final DateTime createdAt;
  final DateTime? updatedAt;

  /// Transient — populated client-side by [PostService] after a feed fetch.
  final bool likedByMe;
  final bool repostedByMe;

  /// Transient — set when this row entered the feed via someone's repost,
  /// so the card can render a "↻ reposted by @user" header.
  final String? repostedByUsername;

  const Post({
    required this.id,
    required this.authorId,
    required this.authorUsername,
    this.authorAvatarUrl,
    this.content,
    this.imageUrl,
    this.likeCount = 0,
    this.commentCount = 0,
    this.repostCount = 0,
    this.eventId,
    required this.createdAt,
    this.updatedAt,
    this.likedByMe = false,
    this.repostedByMe = false,
    this.repostedByUsername,
  });

  /// Convenience getter — caller-friendly alias for `content`.
  String? get caption => content;

  bool get hasImage => imageUrl != null && imageUrl!.isNotEmpty;
  bool get hasCaption => content != null && content!.trim().isNotEmpty;

  Post copyWith({
    int? likeCount,
    int? commentCount,
    int? repostCount,
    bool? likedByMe,
    bool? repostedByMe,
    String? repostedByUsername,
  }) {
    return Post(
      id: id,
      authorId: authorId,
      authorUsername: authorUsername,
      authorAvatarUrl: authorAvatarUrl,
      content: content,
      imageUrl: imageUrl,
      likeCount: likeCount ?? this.likeCount,
      commentCount: commentCount ?? this.commentCount,
      repostCount: repostCount ?? this.repostCount,
      eventId: eventId,
      createdAt: createdAt,
      updatedAt: updatedAt,
      likedByMe: likedByMe ?? this.likedByMe,
      repostedByMe: repostedByMe ?? this.repostedByMe,
      repostedByUsername: repostedByUsername ?? this.repostedByUsername,
    );
  }

  factory Post.fromJson(
    Map<String, dynamic> json, {
    String? repostedByUsername,
  }) {
    final profile = (json['profiles'] as Map<String, dynamic>?) ?? {};
    return Post(
      id: json['id'] as String,
      authorId: json['user_id'] as String,
      authorUsername: profile['username'] as String? ?? 'unknown',
      authorAvatarUrl: profile['avatar_url'] as String?,
      content: json['content'] as String?,
      imageUrl: json['image_url'] as String?,
      likeCount: (json['like_count'] as num?)?.toInt() ?? 0,
      commentCount: (json['comment_count'] as num?)?.toInt() ?? 0,
      repostCount: (json['repost_count'] as num?)?.toInt() ?? 0,
      eventId: json['event_id'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : null,
      repostedByUsername: repostedByUsername,
    );
  }
}

// ── Service ───────────────────────────────────────────────────────────────────

class PostService {
  static const _postSelect =
      '*, profiles!posts_user_id_fkey(username, avatar_url)';

  /// Posts from followed authors, newest first. Keyset-paged by created_at
  /// via [cursor] (the previous page's last created_at).
  static Future<Paged<Post>> getFeed(
    List<String> followingIds, {
    String? cursor,
  }) async {
    if (followingIds.isEmpty) return Paged.empty();
    var b = supabase
        .from('posts')
        .select(_postSelect)
        .inFilter('user_id', followingIds);
    if (cursor != null) b = b.lt('created_at', cursor);
    final rows = await b.order('created_at', ascending: false).limit(kPageSize);
    return _page(rows as List);
  }

  /// Reposts made by [reposterIds] (e.g. the people the current user follows),
  /// newest-repost-first, each hydrated as the original [Post] with
  /// [Post.repostedByUsername] set. Loaded once per feed load and interleaved
  /// client-side (like recommendations) — not part of the post keyset, since a
  /// repost sorts by its own time, not the original post's created_at.
  static Future<List<({Post post, DateTime repostedAt})>> getRepostsFeed(
    List<String> reposterIds, {
    int limit = kPageSize,
  }) async {
    if (reposterIds.isEmpty) return const [];
    final rows = await supabase
        .from('reposts')
        .select(
          'created_at, reposter:profiles!reposts_user_id_fkey(username), '
          'post:posts!reposts_post_id_fkey($_postSelect)',
        )
        .inFilter('user_id', reposterIds)
        .order('created_at', ascending: false)
        .limit(limit);
    return _fromReposts(rows as List);
  }

  /// Maps repost rows (with joined post + reposter) to (post, repostedAt) pairs.
  /// Skips rows whose original post was deleted (join yields null).
  static List<({Post post, DateTime repostedAt})> _fromReposts(List rows) {
    final out = <({Post post, DateTime repostedAt})>[];
    for (final r in rows) {
      final m = r as Map<String, dynamic>;
      final post = m['post'] as Map<String, dynamic>?;
      if (post == null) continue;
      final reposter = (m['reposter'] as Map<String, dynamic>?) ?? {};
      out.add((
        post: Post.fromJson(
          post,
          repostedByUsername: reposter['username'] as String?,
        ),
        repostedAt: DateTime.parse(m['created_at'] as String),
      ));
    }
    return out;
  }

  /// All posts globally, newest first (for Discover). Keyset-paged.
  static Future<Paged<Post>> getDiscover({String? cursor}) async {
    var b = supabase.from('posts').select(_postSelect);
    if (cursor != null) b = b.lt('created_at', cursor);
    final rows = await b.order('created_at', ascending: false).limit(kPageSize);
    return _page(rows as List);
  }

  /// All posts by one author, newest first (profile screen). Keyset-paged.
  static Future<Paged<Post>> getByAuthor(
    String authorId, {
    String? cursor,
    int limit = kPageSize,
  }) async {
    var b = supabase.from('posts').select(_postSelect).eq('user_id', authorId);
    if (cursor != null) b = b.lt('created_at', cursor);
    final rows = await b.order('created_at', ascending: false).limit(limit);
    return _page(rows as List, pageSize: limit);
  }

  static Paged<Post> _page(List rows, {int pageSize = kPageSize}) {
    final items = rows
        .map((r) => Post.fromJson(r as Map<String, dynamic>))
        .toList();
    final hasMore = items.length == pageSize;
    return Paged(
      items: items,
      hasMore: hasMore,
      nextCursor: hasMore ? items.last.createdAt.toIso8601String() : null,
    );
  }

  /// Insert a new post and return the hydrated row.
  static Future<Post> create({
    String? content,
    String? imageUrl,
    String? eventId,
  }) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('PostService: no authenticated user');

    final body = content?.trim();
    final hasBody = body != null && body.isNotEmpty;
    final hasImage = imageUrl != null && imageUrl.isNotEmpty;
    if (!hasBody && !hasImage) {
      throw ArgumentError('Post must have content or an image.');
    }

    final row = await supabase
        .from('posts')
        .insert({
          'user_id': uid,
          'content': body ?? '',
          if (hasImage) 'image_url': imageUrl,
          'event_id': ?eventId,
        })
        .select(_postSelect)
        .single();

    return Post.fromJson(row);
  }

  /// Update mutable fields on a post. Only the current user's posts (RLS).
  static Future<Post> update({
    required String postId,
    String? content,
    String? imageUrl,
    bool clearImage = false,
  }) async {
    final updates = <String, dynamic>{
      'content': ?content,
      'image_url': ?imageUrl,
      if (clearImage) 'image_url': null,
    };
    final row = await supabase
        .from('posts')
        .update(updates)
        .eq('id', postId)
        .select(_postSelect)
        .single();
    return Post.fromJson(row);
  }

  /// Delete a post owned by the current user. RLS enforces ownership.
  static Future<void> delete(String postId) async {
    await supabase.from('posts').delete().eq('id', postId);
  }

  /// Fetch a single post by id (with author profile joined).
  static Future<Post?> fetchById(String postId) async {
    final rows = await supabase
        .from('posts')
        .select(_postSelect)
        .eq('id', postId)
        .limit(1);
    final list = rows as List;
    return list.isEmpty
        ? null
        : Post.fromJson(list.first as Map<String, dynamic>);
  }

  /// Populates the [Post.likedByMe] flag for every post in [posts] in one
  /// round-trip. Returns a new list with the flag set; original is untouched.
  static Future<List<Post>> hydrateLikes(List<Post> posts) async {
    if (posts.isEmpty) return posts;
    final liked = await LikeService.getLikedPostIds(
      posts.map((p) => p.id).toList(),
    );
    return posts
        .map((p) => p.copyWith(likedByMe: liked.contains(p.id)))
        .toList();
  }

  /// Sets [Post.repostedByMe] for every post in one round-trip.
  static Future<List<Post>> hydrateReposts(List<Post> posts) async {
    if (posts.isEmpty) return posts;
    final reposted = await RepostService.getRepostedPostIds(
      posts.map((p) => p.id).toList(),
    );
    return posts
        .map((p) => p.copyWith(repostedByMe: reposted.contains(p.id)))
        .toList();
  }

  /// Upload an image to the `posts` bucket and return its public URL.
  /// Stored at `{userId}/{timestamp}.jpg` — folder-per-user lets RLS
  /// scope deletes to the owner.
  static Future<String> uploadImageBytes(Uint8List bytes) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('PostService: no authenticated user');

    final filename = '${DateTime.now().millisecondsSinceEpoch}.jpg';
    final path = '$uid/$filename';
    await supabase.storage
        .from('posts')
        .uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: false,
          ),
        );
    return supabase.storage.from('posts').getPublicUrl(path);
  }
}
