import 'dart:io';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'pagination.dart';
import 'supabase_client.dart';

// ── Models ────────────────────────────────────────────────────────────────────

/// One creator's slot in the home-screen rail (get_rapids_rail).
class RapidRailEntry {
  final String userId;
  final String username;
  final String? avatarUrl;
  final bool isOfficial;
  final int rapidCount;
  final DateTime latestRapidAt;
  final bool hasUnwatched;
  final bool isFollowed;

  const RapidRailEntry({
    required this.userId,
    required this.username,
    this.avatarUrl,
    this.isOfficial = false,
    required this.rapidCount,
    required this.latestRapidAt,
    required this.hasUnwatched,
    required this.isFollowed,
  });

  factory RapidRailEntry.fromJson(Map<String, dynamic> j) => RapidRailEntry(
        userId: j['user_id'] as String,
        username: j['username'] as String? ?? 'unknown',
        avatarUrl: j['avatar_url'] as String?,
        isOfficial: j['is_official'] as bool? ?? false,
        rapidCount: (j['rapid_count'] as num).toInt(),
        latestRapidAt: DateTime.parse(j['latest_rapid_at'] as String),
        hasUnwatched: j['has_unwatched'] as bool? ?? false,
        isFollowed: j['is_followed'] as bool? ?? false,
      );

  RapidRailEntry copyWith({bool? hasUnwatched}) => RapidRailEntry(
        userId: userId,
        username: username,
        avatarUrl: avatarUrl,
        isOfficial: isOfficial,
        rapidCount: rapidCount,
        latestRapidAt: latestRapidAt,
        hasUnwatched: hasUnwatched ?? this.hasUnwatched,
        isFollowed: isFollowed,
      );
}

/// A ≤60s video snippet (get_rapids_feed / archive rows).
class Rapid {
  final String id;
  final String authorId;
  final String authorUsername;
  final String? authorAvatarUrl;
  final bool authorIsOfficial;
  final String videoPath;
  final String? thumbPath;
  final String? caption;
  final int durationMs;
  final int likeCount;
  final int commentCount;
  final int viewCount;
  final DateTime createdAt;
  final DateTime? expiresAt; // only present on archive/own queries
  final bool likedByMe;
  final bool watchedByMe;
  final bool isFollowed;

  const Rapid({
    required this.id,
    required this.authorId,
    required this.authorUsername,
    this.authorAvatarUrl,
    this.authorIsOfficial = false,
    required this.videoPath,
    this.thumbPath,
    this.caption,
    required this.durationMs,
    this.likeCount = 0,
    this.commentCount = 0,
    this.viewCount = 0,
    required this.createdAt,
    this.expiresAt,
    this.likedByMe = false,
    this.watchedByMe = false,
    this.isFollowed = false,
  });

  String get videoUrl => RapidService.publicUrl(videoPath);
  String? get thumbUrl =>
      thumbPath == null ? null : RapidService.publicUrl(thumbPath!);
  bool get expired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now().toUtc());

  Rapid copyWith({int? likeCount, int? commentCount, int? viewCount, bool? likedByMe, bool? watchedByMe}) =>
      Rapid(
        id: id,
        authorId: authorId,
        authorUsername: authorUsername,
        authorAvatarUrl: authorAvatarUrl,
        authorIsOfficial: authorIsOfficial,
        videoPath: videoPath,
        thumbPath: thumbPath,
        caption: caption,
        durationMs: durationMs,
        likeCount: likeCount ?? this.likeCount,
        commentCount: commentCount ?? this.commentCount,
        viewCount: viewCount ?? this.viewCount,
        createdAt: createdAt,
        expiresAt: expiresAt,
        likedByMe: likedByMe ?? this.likedByMe,
        watchedByMe: watchedByMe ?? this.watchedByMe,
        isFollowed: isFollowed,
      );

  /// From a get_rapids_feed row (flat profile columns).
  factory Rapid.fromFeedJson(Map<String, dynamic> j) => Rapid(
        id: j['id'] as String,
        authorId: j['user_id'] as String,
        authorUsername: j['username'] as String? ?? 'unknown',
        authorAvatarUrl: j['avatar_url'] as String?,
        authorIsOfficial: j['is_official'] as bool? ?? false,
        videoPath: j['video_path'] as String,
        thumbPath: j['thumb_path'] as String?,
        caption: j['caption'] as String?,
        durationMs: (j['duration_ms'] as num).toInt(),
        likeCount: (j['like_count'] as num?)?.toInt() ?? 0,
        commentCount: (j['comment_count'] as num?)?.toInt() ?? 0,
        viewCount: (j['view_count'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.parse(j['created_at'] as String),
        likedByMe: j['liked_by_me'] as bool? ?? false,
        watchedByMe: j['watched_by_me'] as bool? ?? false,
        isFollowed: j['is_followed'] as bool? ?? false,
      );

  /// From a plain rapids table row with the author profile joined (archive).
  factory Rapid.fromRowJson(Map<String, dynamic> j) {
    final profile = (j['profiles'] as Map<String, dynamic>?) ?? {};
    return Rapid(
      id: j['id'] as String,
      authorId: j['user_id'] as String,
      authorUsername: profile['username'] as String? ?? 'unknown',
      authorAvatarUrl: profile['avatar_url'] as String?,
      authorIsOfficial: profile['is_official'] as bool? ?? false,
      videoPath: j['video_path'] as String,
      thumbPath: j['thumb_path'] as String?,
      caption: j['caption'] as String?,
      durationMs: (j['duration_ms'] as num).toInt(),
      likeCount: (j['like_count'] as num?)?.toInt() ?? 0,
      commentCount: (j['comment_count'] as num?)?.toInt() ?? 0,
      viewCount: (j['view_count'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.parse(j['created_at'] as String),
      expiresAt: j['expires_at'] != null
          ? DateTime.parse(j['expires_at'] as String)
          : null,
    );
  }
}

/// Flat comment on a Rapid (mirrors [Comment] from post comments).
class RapidComment {
  final String id;
  final String rapidId;
  final String authorId;
  final String authorUsername;
  final String? authorAvatarUrl;
  final bool authorIsOfficial;
  final String body;
  final DateTime createdAt;

  const RapidComment({
    required this.id,
    required this.rapidId,
    required this.authorId,
    required this.authorUsername,
    this.authorAvatarUrl,
    this.authorIsOfficial = false,
    required this.body,
    required this.createdAt,
  });

  factory RapidComment.fromJson(Map<String, dynamic> j) {
    final profile = (j['profiles'] as Map<String, dynamic>?) ?? {};
    return RapidComment(
      id: j['id'] as String,
      rapidId: j['rapid_id'] as String,
      authorId: j['user_id'] as String,
      authorUsername: profile['username'] as String? ?? 'unknown',
      authorAvatarUrl: profile['avatar_url'] as String?,
      authorIsOfficial: profile['is_official'] as bool? ?? false,
      body: j['body'] as String,
      createdAt: DateTime.parse(j['created_at'] as String),
    );
  }
}

// ── Service ───────────────────────────────────────────────────────────────────

class RapidService {
  static const int maxDurationMs = 60000;
  static const int maxCaption = 200;

  static String publicUrl(String path) =>
      supabase.storage.from('rapids').getPublicUrl(path);

  /// Home-rail entries, followed → unwatched → newest.
  /// Best-effort: [] on failure so the home screen never breaks.
  static Future<List<RapidRailEntry>> rail({int limit = 30}) async {
    try {
      final rows =
          await supabase.rpc('get_rapids_rail', params: {'page_limit': limit});
      return (rows as List)
          .map((r) => RapidRailEntry.fromJson(r as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// The playable feed, in rail order (oldest-first within each creator).
  static Future<List<Rapid>> feed({int limit = 200}) async {
    final rows =
        await supabase.rpc('get_rapids_feed', params: {'page_limit': limit});
    return (rows as List)
        .map((r) => Rapid.fromFeedJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Upload the trimmed/compressed video + poster thumb, then insert the row.
  /// Storage first, row second — a failed insert leaves orphaned objects that
  /// the owner-delete policy lets us clean up on the spot.
  static Future<Rapid> create({
    required File video,
    Uint8List? thumbnail,
    String? caption,
    required int durationMs,
  }) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('RapidService: no authenticated user');
    if (durationMs <= 0 || durationMs > maxDurationMs + 1000) {
      throw ArgumentError('Rapid must be 60 seconds or shorter.');
    }

    final ts = DateTime.now().millisecondsSinceEpoch;
    final videoPath = '$uid/$ts.mp4';
    final thumbPath = thumbnail != null ? '$uid/$ts.jpg' : null;

    await supabase.storage.from('rapids').upload(
          videoPath,
          video,
          fileOptions: const FileOptions(contentType: 'video/mp4', upsert: false),
        );
    if (thumbnail != null) {
      try {
        await supabase.storage.from('rapids').uploadBinary(
              thumbPath!,
              thumbnail,
              fileOptions:
                  const FileOptions(contentType: 'image/jpeg', upsert: false),
            );
      } catch (_) {
        // Thumb is cosmetic — the row can live without it.
      }
    }

    try {
      final row = await supabase
          .from('rapids')
          .insert({
            'user_id': uid,
            'video_path': videoPath,
            'thumb_path': ?thumbPath,
            if (caption != null && caption.trim().isNotEmpty)
              'caption': caption.trim(),
            'duration_ms': durationMs,
          })
          .select('*, profiles!rapids_user_id_fkey(username, avatar_url, is_official)')
          .single();
      return Rapid.fromRowJson(row);
    } catch (e) {
      // Row insert failed — don't strand the uploaded objects.
      try {
        await supabase.storage.from('rapids').remove([
          videoPath,
          ?thumbPath,
        ]);
      } catch (_) {}
      rethrow;
    }
  }

  /// The caller's own Rapids, newest first, including expired (archive).
  static Future<List<Rapid>> myArchive({int limit = 50}) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return [];
    final rows = await supabase
        .from('rapids')
        .select('*, profiles!rapids_user_id_fkey(username, avatar_url, is_official)')
        .eq('user_id', uid)
        .order('created_at', ascending: false)
        .limit(limit);
    return (rows as List)
        .map((r) => Rapid.fromRowJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Delete an own Rapid: storage objects first, then the row (RLS enforces
  /// ownership on both).
  static Future<void> delete(Rapid rapid) async {
    try {
      await supabase.storage.from('rapids').remove([
        rapid.videoPath,
        ?rapid.thumbPath,
      ]);
    } catch (_) {
      // Object may already be purged; the row delete is what matters.
    }
    await supabase.from('rapids').delete().eq('id', rapid.id);
  }

  // ── Engagement ─────────────────────────────────────────────────────────────

  static Future<void> like(String rapidId) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return;
    try {
      await supabase
          .from('rapid_likes')
          .insert({'user_id': uid, 'rapid_id': rapidId});
    } on PostgrestException catch (e) {
      if (e.code != '23505') rethrow; // already liked — fine
    }
  }

  static Future<void> unlike(String rapidId) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return;
    await supabase
        .from('rapid_likes')
        .delete()
        .match({'user_id': uid, 'rapid_id': rapidId});
  }

  /// Marks the rapid watched for this viewer (dedup'd server-side; the count
  /// trigger fires only on first insert). Best-effort.
  static Future<void> logView(String rapidId) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return;
    try {
      await supabase.from('rapid_views').upsert(
        {'viewer_id': uid, 'rapid_id': rapidId},
        onConflict: 'viewer_id,rapid_id',
        ignoreDuplicates: true,
      );
    } catch (_) {}
  }

  // ── Comments ───────────────────────────────────────────────────────────────

  static const _commentSelect =
      '*, profiles!rapid_comments_user_id_fkey(username, avatar_url, is_official)';

  static Future<Paged<RapidComment>> comments(
    String rapidId, {
    String? cursor,
  }) async {
    var b = supabase
        .from('rapid_comments')
        .select(_commentSelect)
        .eq('rapid_id', rapidId)
        .isFilter('removed_at', null);
    if (cursor != null) b = b.lt('created_at', cursor);
    final rows = await b.order('created_at', ascending: false).limit(kPageSize);
    final items = (rows as List)
        .map((r) => RapidComment.fromJson(r as Map<String, dynamic>))
        .toList();
    final hasMore = items.length == kPageSize;
    return Paged(
      items: items,
      hasMore: hasMore,
      nextCursor: hasMore ? items.last.createdAt.toIso8601String() : null,
    );
  }

  static Future<RapidComment> addComment({
    required String rapidId,
    required String body,
  }) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('RapidService: no authenticated user');
    final trimmed = body.trim();
    if (trimmed.isEmpty) throw ArgumentError('Comment cannot be empty.');
    final row = await supabase
        .from('rapid_comments')
        .insert({'rapid_id': rapidId, 'user_id': uid, 'body': trimmed})
        .select(_commentSelect)
        .single();
    return RapidComment.fromJson(row);
  }

  static Future<void> deleteComment(String commentId) async {
    await supabase.from('rapid_comments').delete().eq('id', commentId);
  }
}
