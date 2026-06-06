import 'supabase_client.dart';

/// The current user's per-type notification toggles. Missing row = all enabled.
class NotificationPreferences {
  final bool postLike;
  final bool postComment;
  final bool follow;
  final bool eventStarting;
  final bool eventLive;
  final bool eventEnded;
  final bool operatorAssigned;

  const NotificationPreferences({
    this.postLike = true,
    this.postComment = true,
    this.follow = true,
    this.eventStarting = true,
    this.eventLive = true,
    this.eventEnded = true,
    this.operatorAssigned = true,
  });

  factory NotificationPreferences.fromJson(Map<String, dynamic> j) =>
      NotificationPreferences(
        postLike: j['post_like'] as bool? ?? true,
        postComment: j['post_comment'] as bool? ?? true,
        follow: j['follow'] as bool? ?? true,
        eventStarting: j['event_starting'] as bool? ?? true,
        eventLive: j['event_live'] as bool? ?? true,
        eventEnded: j['event_ended'] as bool? ?? true,
        operatorAssigned: j['operator_assigned'] as bool? ?? true,
      );

  NotificationPreferences copyWith({
    bool? postLike,
    bool? postComment,
    bool? follow,
    bool? eventStarting,
    bool? eventLive,
    bool? eventEnded,
    bool? operatorAssigned,
  }) =>
      NotificationPreferences(
        postLike: postLike ?? this.postLike,
        postComment: postComment ?? this.postComment,
        follow: follow ?? this.follow,
        eventStarting: eventStarting ?? this.eventStarting,
        eventLive: eventLive ?? this.eventLive,
        eventEnded: eventEnded ?? this.eventEnded,
        operatorAssigned: operatorAssigned ?? this.operatorAssigned,
      );

  Map<String, dynamic> toColumns() => {
        'post_like': postLike,
        'post_comment': postComment,
        'follow': follow,
        'event_starting': eventStarting,
        'event_live': eventLive,
        'event_ended': eventEnded,
        'operator_assigned': operatorAssigned,
      };
}

class NotificationPreferencesService {
  /// Fetch the current user's preferences. Returns all-on defaults if no row.
  static Future<NotificationPreferences> get() async {
    final uid = _requireUid();
    final row = await supabase
        .from('notification_preferences')
        .select()
        .eq('user_id', uid)
        .maybeSingle();
    return row == null
        ? const NotificationPreferences()
        : NotificationPreferences.fromJson(row);
  }

  /// Upsert the full preference set for the current user.
  static Future<void> save(NotificationPreferences prefs) async {
    final uid = _requireUid();
    await supabase.from('notification_preferences').upsert({
      'user_id': uid,
      ...prefs.toColumns(),
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  static String _requireUid() {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) {
      throw StateError('NotificationPreferencesService: no authenticated user');
    }
    return uid;
  }
}
