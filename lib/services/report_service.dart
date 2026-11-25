import 'supabase_client.dart';

enum ReportTargetType {
  user,
  post,
  event,
  comment,
  ad,
  current,
  currentComment,
  liveChatMessage,
}

extension ReportTargetTypeX on ReportTargetType {
  /// Matches the report_target_type Postgres enum (0066 adds the current
  /// values, 0108 the live-chat one).
  ///
  /// Every multi-word value needs its own arm — the `_ => name` fallback yields
  /// Dart camelCase, which the enum cast rejects.
  String get dbValue => switch (this) {
    ReportTargetType.currentComment => 'current_comment',
    ReportTargetType.liveChatMessage => 'live_chat_message',
    _ => name,
  };
}

enum ReportReason {
  spam,
  harassment,
  hateSpeech,
  nudity,
  violence,
  selfHarm,
  other,
}

extension ReportReasonX on ReportReason {
  /// Matches the report_reason Postgres enum.
  String get dbValue => switch (this) {
    ReportReason.spam => 'spam',
    ReportReason.harassment => 'harassment',
    ReportReason.hateSpeech => 'hate_speech',
    ReportReason.nudity => 'nudity',
    ReportReason.violence => 'violence',
    ReportReason.selfHarm => 'self_harm',
    ReportReason.other => 'other',
  };

  String get label => switch (this) {
    ReportReason.spam => 'Spam',
    ReportReason.harassment => 'Harassment or bullying',
    ReportReason.hateSpeech => 'Hate speech',
    ReportReason.nudity => 'Nudity or sexual content',
    ReportReason.violence => 'Violence',
    ReportReason.selfHarm => 'Self-harm',
    ReportReason.other => 'Other',
  };
}

class ReportService {
  /// File a report. Insert-only; reviewed manually in Supabase.
  static Future<void> submit({
    required ReportTargetType targetType,
    required String targetId,
    required ReportReason reason,
    String? note,
  }) async {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) throw StateError('ReportService: no authenticated user');
    await supabase.from('reports').insert({
      'reporter_id': myId,
      'target_type': targetType.dbValue,
      'target_id': targetId,
      'reason': reason.dbValue,
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
    });
  }
}
