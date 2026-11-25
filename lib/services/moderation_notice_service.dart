import 'supabase_client.dart';

/// One moderation decision taken against the signed-in user — the statement of
/// reasons DSA Art. 17 requires (P3 #35). Written by `moderate-report`; RLS
/// lets you read only your own.
class ModerationNotice {
  final String id;
  final String action;
  final String targetType;

  /// The moderator's note, verbatim. Null when they didn't write one.
  final String? reason;
  final DateTime createdAt;

  const ModerationNotice({
    required this.id,
    required this.action,
    required this.targetType,
    required this.reason,
    required this.createdAt,
  });

  factory ModerationNotice.fromJson(Map<String, dynamic> j) => ModerationNotice(
    id: j['id'] as String,
    action: j['action'] as String,
    targetType: j['target_type'] as String,
    reason: j['reason'] as String?,
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  bool get isRemoval => action == 'remove_content';
  bool get isReversal => action == 'restore_content' || action == 'unsuspend_user';

  /// What the person reading this actually cares about, in their words.
  String get headline {
    final what = switch (targetType) {
      'post' => 'post',
      'comment' || 'current_comment' => 'comment',
      'event' => 'event',
      'current' => 'Current',
      'live_chat_message' => 'chat message',
      _ => 'account',
    };
    return switch (action) {
      'remove_content' => 'Your $what was removed',
      'restore_content' => 'Your $what was restored',
      'suspend_user' => 'Your account was suspended',
      'unsuspend_user' => 'Your account was reinstated',
      _ => 'A decision about your $what',
    };
  }
}

class ModerationNoticeService {
  /// Newest first. Returns [] when nothing has ever been actioned, which is
  /// the case for almost everyone.
  static Future<List<ModerationNotice>> mine({int limit = 50}) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return const [];
    final rows = await supabase
        .from('moderation_notices')
        .select('id, action, target_type, reason, created_at')
        .eq('user_id', uid)
        .order('created_at', ascending: false)
        .limit(limit);
    return (rows as List)
        .map((r) => ModerationNotice.fromJson(r as Map<String, dynamic>))
        .toList();
  }
}
