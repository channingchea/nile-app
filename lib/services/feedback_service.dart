import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:supabase_flutter/supabase_flutter.dart';

import 'diagnostics.dart';
import 'error_log.dart';
import 'supabase_client.dart';

// ── Models ────────────────────────────────────────────────────────────────────

enum FeedbackKind { bug, feature }

extension FeedbackKindX on FeedbackKind {
  String get dbValue => name; // matches the feedback_kind enum
  String get label => this == FeedbackKind.bug ? 'Bug' : 'Idea';

  String get prompt => this == FeedbackKind.bug
      ? 'What went wrong? What were you doing right before it happened?'
      : 'What would you like Nile to do?';
}

enum FeedbackStatus { newly, triaged, inProgress, resolved, wontFix }

extension FeedbackStatusX on FeedbackStatus {
  String get dbValue => switch (this) {
        FeedbackStatus.newly => 'new',
        FeedbackStatus.inProgress => 'in_progress',
        FeedbackStatus.wontFix => 'wont_fix',
        _ => name,
      };

  String get label => switch (this) {
        FeedbackStatus.newly => 'Received',
        FeedbackStatus.triaged => 'Being looked at',
        FeedbackStatus.inProgress => 'Being worked on',
        FeedbackStatus.resolved => 'Resolved',
        FeedbackStatus.wontFix => 'Closed',
      };

  static FeedbackStatus parse(String raw) => switch (raw) {
        'triaged' => FeedbackStatus.triaged,
        'in_progress' => FeedbackStatus.inProgress,
        'resolved' => FeedbackStatus.resolved,
        'wont_fix' => FeedbackStatus.wontFix,
        _ => FeedbackStatus.newly,
      };
}

class FeedbackReport {
  final String id;
  final FeedbackKind kind;
  final String title;
  final String body;
  final FeedbackStatus status;
  final String? adminNote;
  final List<String> imagePaths;
  final DateTime createdAt;
  final DateTime? resolvedAt;

  const FeedbackReport({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.status,
    this.adminNote,
    this.imagePaths = const [],
    required this.createdAt,
    this.resolvedAt,
  });

  factory FeedbackReport.fromJson(Map<String, dynamic> j) => FeedbackReport(
        id: j['id'] as String,
        kind: j['kind'] == 'feature' ? FeedbackKind.feature : FeedbackKind.bug,
        title: j['title'] as String,
        body: j['body'] as String,
        status: FeedbackStatusX.parse(j['status'] as String),
        adminNote: j['admin_note'] as String?,
        imagePaths: ((j['image_paths'] as List?) ?? const [])
            .map((e) => e as String)
            .toList(),
        createdAt: DateTime.parse(j['created_at'] as String),
        resolvedAt: j['resolved_at'] != null
            ? DateTime.parse(j['resolved_at'] as String)
            : null,
      );
}

/// Thrown when the per-user hourly cap trips, so the form can say something
/// useful instead of surfacing a Postgres error.
class FeedbackRateLimited implements Exception {
  const FeedbackRateLimited();
  @override
  String toString() =>
      "You've sent a few reports in the last hour — try again shortly.";
}

// ── Service ───────────────────────────────────────────────────────────────────

class FeedbackService {
  static const int maxImages = 3;
  static const int maxTitle = 120;
  static const int maxBody = 4000;
  static const int minBody = 10;

  /// Objects live in a PRIVATE bucket — reads go through short-lived signed
  /// URLs, since a bug screenshot can contain a DM thread or payout figures.
  static const String _bucket = 'feedback';
  static const Duration _signedUrlTtl = Duration(minutes: 10);

  /// File a report. Uploads screenshots first so a failed insert can clean them
  /// up, mirroring CurrentService.create.
  static Future<FeedbackReport> submit({
    required FeedbackKind kind,
    required String title,
    required String body,
    List<Uint8List> images = const [],
    String source = 'settings',
    Size? screenSize,
  }) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('FeedbackService: no authenticated user');

    final cleanTitle = title.trim();
    final cleanBody = body.trim();
    if (cleanTitle.length < 3) {
      throw ArgumentError('Give it a short title.');
    }
    if (cleanBody.length < minBody) {
      throw ArgumentError('Add a bit more detail so it can be reproduced.');
    }
    if (images.length > maxImages) {
      throw ArgumentError('Up to $maxImages screenshots.');
    }

    final ts = DateTime.now().millisecondsSinceEpoch;
    final paths = <String>[];
    try {
      for (var i = 0; i < images.length; i++) {
        final p = '$uid/$ts/$i.jpg';
        await supabase.storage.from(_bucket).uploadBinary(
              p,
              images[i],
              fileOptions:
                  const FileOptions(contentType: 'image/jpeg', upsert: false),
            );
        paths.add(p);
      }

      final row = await supabase
          .from('feedback_reports')
          .insert({
            'reporter_id': uid,
            'kind': kind.dbValue,
            'title': cleanTitle.length > maxTitle
                ? cleanTitle.substring(0, maxTitle)
                : cleanTitle,
            'body': cleanBody.length > maxBody
                ? cleanBody.substring(0, maxBody)
                : cleanBody,
            'diagnostics': await Diagnostics.collect(screenSize: screenSize),
            'error_log': ErrorLog.snapshot(),
            'image_paths': paths,
            'source': source,
          })
          .select()
          .single();
      return FeedbackReport.fromJson(row);
    } catch (e) {
      if (paths.isNotEmpty) {
        try {
          await supabase.storage.from(_bucket).remove(paths);
        } catch (_) {}
      }
      if (e is PostgrestException &&
          (e.message.contains('feedback_rate_limited') ||
              (e.hint?.contains('Too many reports') ?? false))) {
        throw const FeedbackRateLimited();
      }
      rethrow;
    }
  }

  /// The caller's own reports, newest first (RLS scopes this to them).
  static Future<List<FeedbackReport>> mine({int limit = 50}) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return [];
    final rows = await supabase
        .from('feedback_reports')
        .select()
        .eq('reporter_id', uid)
        .order('created_at', ascending: false)
        .limit(limit);
    return (rows as List)
        .map((r) => FeedbackReport.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  static Future<FeedbackReport?> byId(String id) async {
    final row = await supabase
        .from('feedback_reports')
        .select()
        .eq('id', id)
        .maybeSingle();
    return row == null ? null : FeedbackReport.fromJson(row);
  }

  /// Signed URL for a screenshot. Private bucket, so there is no public form.
  static Future<String?> imageUrl(String path) async {
    try {
      return await supabase.storage
          .from(_bucket)
          .createSignedUrl(path, _signedUrlTtl.inSeconds);
    } catch (_) {
      return null;
    }
  }
}
