import 'dart:io';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'pagination.dart';
import 'supabase_client.dart';

// ── Models ────────────────────────────────────────────────────────────────────

/// One creator's slot in the home-screen rail (get_currents_rail).
class CurrentRailEntry {
  final String userId;
  final String username;
  final String? avatarUrl;
  final bool isOfficial;
  final int currentCount;
  final DateTime latestCurrentAt;
  final bool hasUnwatched;
  final bool isFollowed;

  const CurrentRailEntry({
    required this.userId,
    required this.username,
    this.avatarUrl,
    this.isOfficial = false,
    required this.currentCount,
    required this.latestCurrentAt,
    required this.hasUnwatched,
    required this.isFollowed,
  });

  factory CurrentRailEntry.fromJson(Map<String, dynamic> j) => CurrentRailEntry(
        userId: j['user_id'] as String,
        username: j['username'] as String? ?? 'unknown',
        avatarUrl: j['avatar_url'] as String?,
        isOfficial: j['is_official'] as bool? ?? false,
        currentCount: (j['current_count'] as num).toInt(),
        latestCurrentAt: DateTime.parse(j['latest_current_at'] as String),
        hasUnwatched: j['has_unwatched'] as bool? ?? false,
        isFollowed: j['is_followed'] as bool? ?? false,
      );

  CurrentRailEntry copyWith({bool? hasUnwatched}) => CurrentRailEntry(
        userId: userId,
        username: username,
        avatarUrl: avatarUrl,
        isOfficial: isOfficial,
        currentCount: currentCount,
        latestCurrentAt: latestCurrentAt,
        hasUnwatched: hasUnwatched ?? this.hasUnwatched,
        isFollowed: isFollowed,
      );
}

/// One frame of an image-slideshow Current.
class CurrentImage {
  final String path;
  final int durationMs;
  final int position;
  const CurrentImage(
      {required this.path, required this.durationMs, this.position = 0});

  String get url => CurrentService.publicUrl(path);

  factory CurrentImage.fromJson(Map<String, dynamic> j) => CurrentImage(
        path: (j['path'] ?? j['image_path']) as String,
        durationMs: (j['duration_ms'] as num).toInt(),
        position: (j['position'] as num?)?.toInt() ?? 0,
      );
}

/// A ≤60s Current: either a video ([mediaType] 'video') or an image slideshow
/// ([mediaType] 'image', frames in [images]). (get_currents_feed / archive rows).
class Current {
  final String id;
  final String authorId;
  final String authorUsername;
  final String? authorAvatarUrl;
  final bool authorIsOfficial;
  final String mediaType;
  final String? videoPath;
  final List<CurrentImage> images;
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

  const Current({
    required this.id,
    required this.authorId,
    required this.authorUsername,
    this.authorAvatarUrl,
    this.authorIsOfficial = false,
    this.mediaType = 'video',
    this.videoPath,
    this.images = const [],
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

  bool get isImage => mediaType == 'image';
  String get videoUrl =>
      videoPath == null ? '' : CurrentService.publicUrl(videoPath!);
  String? get thumbUrl =>
      thumbPath == null ? null : CurrentService.publicUrl(thumbPath!);
  bool get expired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now().toUtc());

  Current copyWith({int? likeCount, int? commentCount, int? viewCount, bool? likedByMe, bool? watchedByMe}) =>
      Current(
        id: id,
        authorId: authorId,
        authorUsername: authorUsername,
        authorAvatarUrl: authorAvatarUrl,
        authorIsOfficial: authorIsOfficial,
        mediaType: mediaType,
        videoPath: videoPath,
        images: images,
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

  /// Parse the images list from either the feed's jsonb array or a nested
  /// current_images row list; result is ordered by position.
  static List<CurrentImage> _parseImages(Object? raw) {
    if (raw is! List) return const [];
    final list = raw
        .map((e) => CurrentImage.fromJson(e as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => a.position.compareTo(b.position));
    return list;
  }

  /// From a get_currents_feed row (flat profile columns).
  factory Current.fromFeedJson(Map<String, dynamic> j) => Current(
        id: j['id'] as String,
        authorId: j['user_id'] as String,
        authorUsername: j['username'] as String? ?? 'unknown',
        authorAvatarUrl: j['avatar_url'] as String?,
        authorIsOfficial: j['is_official'] as bool? ?? false,
        mediaType: j['media_type'] as String? ?? 'video',
        videoPath: j['video_path'] as String?,
        images: _parseImages(j['images']),
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

  /// From a plain currents table row with the author profile joined (archive).
  factory Current.fromRowJson(Map<String, dynamic> j) {
    final profile = (j['profiles'] as Map<String, dynamic>?) ?? {};
    return Current(
      id: j['id'] as String,
      authorId: j['user_id'] as String,
      authorUsername: profile['username'] as String? ?? 'unknown',
      authorAvatarUrl: profile['avatar_url'] as String?,
      authorIsOfficial: profile['is_official'] as bool? ?? false,
      mediaType: j['media_type'] as String? ?? 'video',
      videoPath: j['video_path'] as String?,
      images: _parseImages(j['current_images']),
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

/// Flat comment on a Current (mirrors [Comment] from post comments).
class CurrentComment {
  final String id;
  final String currentId;
  final String authorId;
  final String authorUsername;
  final String? authorAvatarUrl;
  final bool authorIsOfficial;
  final String body;
  final DateTime createdAt;

  const CurrentComment({
    required this.id,
    required this.currentId,
    required this.authorId,
    required this.authorUsername,
    this.authorAvatarUrl,
    this.authorIsOfficial = false,
    required this.body,
    required this.createdAt,
  });

  factory CurrentComment.fromJson(Map<String, dynamic> j) {
    final profile = (j['profiles'] as Map<String, dynamic>?) ?? {};
    return CurrentComment(
      id: j['id'] as String,
      currentId: j['current_id'] as String,
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

class CurrentService {
  static const int maxDurationMs = 60000;
  static const int maxCaption = 200;

  // Image-slideshow bounds.
  static const int minImageMs = 2000;
  static const int maxImageMs = 10000;
  static const int maxImages = 20;

  static String publicUrl(String path) =>
      supabase.storage.from('currents').getPublicUrl(path);

  /// Home-rail entries, followed → unwatched → newest.
  /// Best-effort: [] on failure so the home screen never breaks.
  static Future<List<CurrentRailEntry>> rail({int limit = 30}) async {
    try {
      final rows =
          await supabase.rpc('get_currents_rail', params: {'page_limit': limit});
      return (rows as List)
          .map((r) => CurrentRailEntry.fromJson(r as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// The playable feed, in rail order (oldest-first within each creator).
  static Future<List<Current>> feed({int limit = 200}) async {
    final rows =
        await supabase.rpc('get_currents_feed', params: {'page_limit': limit});
    return (rows as List)
        .map((r) => Current.fromFeedJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Upload the trimmed/compressed video + poster thumb, then insert the row.
  /// Storage first, row second — a failed insert leaves orphaned objects that
  /// the owner-delete policy lets us clean up on the spot.
  static Future<Current> create({
    required File video,
    Uint8List? thumbnail,
    String? caption,
    required int durationMs,
  }) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('CurrentService: no authenticated user');
    if (durationMs <= 0 || durationMs > maxDurationMs + 1000) {
      throw ArgumentError('A Current must be 60 seconds or shorter.');
    }

    final ts = DateTime.now().millisecondsSinceEpoch;
    final videoPath = '$uid/$ts.mp4';
    final thumbPath = thumbnail != null ? '$uid/$ts.jpg' : null;

    await supabase.storage.from('currents').upload(
          videoPath,
          video,
          fileOptions: const FileOptions(contentType: 'video/mp4', upsert: false),
        );
    if (thumbnail != null) {
      try {
        await supabase.storage.from('currents').uploadBinary(
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
          .from('currents')
          .insert({
            'user_id': uid,
            'video_path': videoPath,
            'thumb_path': ?thumbPath,
            if (caption != null && caption.trim().isNotEmpty)
              'caption': caption.trim(),
            'duration_ms': durationMs,
          })
          .select('*, profiles!currents_user_id_fkey(username, avatar_url, is_official)')
          .single();
      return Current.fromRowJson(row);
    } catch (e) {
      // Row insert failed — don't strand the uploaded objects.
      try {
        await supabase.storage.from('currents').remove([
          videoPath,
          ?thumbPath,
        ]);
      } catch (_) {}
      rethrow;
    }
  }

  /// Upload an image slideshow: each object first, then the current row, then the
  /// frame rows. Frames must each be 2–10s and total ≤60s. Cleans up uploaded
  /// objects if any step fails.
  static Future<Current> createImages({
    required List<({File file, int durationMs})> images,
    String? caption,
  }) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('CurrentService: no authenticated user');
    if (images.isEmpty) throw ArgumentError('Add at least one image.');
    if (images.length > maxImages) {
      throw ArgumentError('Up to $maxImages images per Current.');
    }
    final totalMs = images.fold<int>(0, (s, im) => s + im.durationMs);
    if (totalMs > maxDurationMs) {
      throw ArgumentError('Slideshow must be 60 seconds or shorter.');
    }

    final ts = DateTime.now().millisecondsSinceEpoch;
    final paths = <String>[];
    try {
      for (var i = 0; i < images.length; i++) {
        final p = '$uid/${ts}_$i.jpg';
        await supabase.storage.from('currents').upload(
              p,
              images[i].file,
              fileOptions:
                  const FileOptions(contentType: 'image/jpeg', upsert: false),
            );
        paths.add(p);
      }

      final inserted = await supabase
          .from('currents')
          .insert({
            'user_id': uid,
            'media_type': 'image',
            'thumb_path': paths.first,
            if (caption != null && caption.trim().isNotEmpty)
              'caption': caption.trim(),
            'duration_ms': totalMs,
          })
          .select('id')
          .single();
      final currentId = inserted['id'] as String;

      await supabase.from('current_images').insert([
        for (var i = 0; i < images.length; i++)
          {
            'current_id': currentId,
            'position': i,
            'image_path': paths[i],
            'duration_ms': images[i].durationMs,
          }
      ]);

      final full = await supabase
          .from('currents')
          .select(
              '*, current_images(image_path, duration_ms, position), profiles!currents_user_id_fkey(username, avatar_url, is_official)')
          .eq('id', currentId)
          .single();
      return Current.fromRowJson(full);
    } catch (e) {
      if (paths.isNotEmpty) {
        try {
          await supabase.storage.from('currents').remove(paths);
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// The caller's own Currents, newest first, including expired (archive).
  static Future<List<Current>> myArchive({int limit = 50}) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return [];
    final rows = await supabase
        .from('currents')
        .select(
            '*, current_images(image_path, duration_ms, position), profiles!currents_user_id_fkey(username, avatar_url, is_official)')
        .eq('user_id', uid)
        .order('created_at', ascending: false)
        .limit(limit);
    return (rows as List)
        .map((r) => Current.fromRowJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Delete an own Current: storage objects first, then the row (RLS enforces
  /// ownership on both).
  static Future<void> delete(Current current) async {
    final objects = <String>{
      if (current.videoPath != null) current.videoPath!,
      if (current.thumbPath != null) current.thumbPath!,
      for (final im in current.images) im.path,
    };
    try {
      if (objects.isNotEmpty) {
        await supabase.storage.from('currents').remove(objects.toList());
      }
    } catch (_) {
      // Objects may already be purged; the row delete is what matters.
    }
    await supabase.from('currents').delete().eq('id', current.id);
  }

  // ── Engagement ─────────────────────────────────────────────────────────────

  static Future<void> like(String currentId) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return;
    try {
      await supabase
          .from('current_likes')
          .insert({'user_id': uid, 'current_id': currentId});
    } on PostgrestException catch (e) {
      if (e.code != '23505') rethrow; // already liked — fine
    }
  }

  static Future<void> unlike(String currentId) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return;
    await supabase
        .from('current_likes')
        .delete()
        .match({'user_id': uid, 'current_id': currentId});
  }

  /// Marks the current watched for this viewer (dedup'd server-side; the count
  /// trigger fires only on first insert). Best-effort.
  static Future<void> logView(String currentId) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return;
    try {
      await supabase.from('current_views').upsert(
        {'viewer_id': uid, 'current_id': currentId},
        onConflict: 'viewer_id,current_id',
        ignoreDuplicates: true,
      );
    } catch (_) {}
  }

  // ── Comments ───────────────────────────────────────────────────────────────

  static const _commentSelect =
      '*, profiles!current_comments_user_id_fkey(username, avatar_url, is_official)';

  static Future<Paged<CurrentComment>> comments(
    String currentId, {
    String? cursor,
  }) async {
    var b = supabase
        .from('current_comments')
        .select(_commentSelect)
        .eq('current_id', currentId)
        .isFilter('removed_at', null);
    if (cursor != null) b = b.lt('created_at', cursor);
    final rows = await b.order('created_at', ascending: false).limit(kPageSize);
    final items = (rows as List)
        .map((r) => CurrentComment.fromJson(r as Map<String, dynamic>))
        .toList();
    final hasMore = items.length == kPageSize;
    return Paged(
      items: items,
      hasMore: hasMore,
      nextCursor: hasMore ? items.last.createdAt.toIso8601String() : null,
    );
  }

  static Future<CurrentComment> addComment({
    required String currentId,
    required String body,
  }) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('CurrentService: no authenticated user');
    final trimmed = body.trim();
    if (trimmed.isEmpty) throw ArgumentError('Comment cannot be empty.');
    final row = await supabase
        .from('current_comments')
        .insert({'current_id': currentId, 'user_id': uid, 'body': trimmed})
        .select(_commentSelect)
        .single();
    return CurrentComment.fromJson(row);
  }

  static Future<void> deleteComment(String commentId) async {
    await supabase.from('current_comments').delete().eq('id', commentId);
  }
}
