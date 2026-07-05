import 'pagination.dart';
import 'supabase_client.dart';

// ── Model ─────────────────────────────────────────────────────────────────────

enum NotificationType {
  postLike,
  postComment,
  follow,
  eventStarting,
  eventLive,
  eventEnded,
  operatorAssigned,
  newMessage,
  messageReaction,
  replayReady,
  soundcheckOpen,
  replayPricePrompt,
}

class AppNotification {
  final String id;
  final String recipientId;
  final String actorId;
  final String actorUsername;
  final String? actorAvatarUrl;
  final NotificationType type;
  final String?
  entityId; // post_id for post_like / post_comment; event_id for event_starting; null for follow
  final DateTime? readAt;
  final DateTime createdAt;

  const AppNotification({
    required this.id,
    required this.recipientId,
    required this.actorId,
    required this.actorUsername,
    this.actorAvatarUrl,
    required this.type,
    this.entityId,
    this.readAt,
    required this.createdAt,
  });

  bool get isRead => readAt != null;

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    final profile = (json['actor'] as Map<String, dynamic>?) ?? {};
    return AppNotification(
      id: json['id'] as String,
      recipientId: json['recipient_id'] as String,
      actorId: json['actor_id'] as String,
      actorUsername: profile['username'] as String? ?? 'someone',
      actorAvatarUrl: profile['avatar_url'] as String?,
      type: _parseType(json['type'] as String),
      entityId: json['entity_id'] as String?,
      readAt: json['read_at'] != null
          ? DateTime.parse(json['read_at'] as String)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  static NotificationType _parseType(String raw) => switch (raw) {
    'post_like' => NotificationType.postLike,
    'post_comment' => NotificationType.postComment,
    'event_starting' => NotificationType.eventStarting,
    'event_live' => NotificationType.eventLive,
    'event_ended' => NotificationType.eventEnded,
    'operator_assigned' => NotificationType.operatorAssigned,
    'new_message' => NotificationType.newMessage,
    'message_reaction' => NotificationType.messageReaction,
    'replay_ready' => NotificationType.replayReady,
    'soundcheck_open' => NotificationType.soundcheckOpen,
    'replay_price_prompt' => NotificationType.replayPricePrompt,
    _ => NotificationType.follow,
  };
}

// ── Service ───────────────────────────────────────────────────────────────────

class NotificationService {
  static const _select = '*, actor:profiles!actor_id(username, avatar_url)';

  /// Notifications for the current user, newest first. Keyset-paged by
  /// created_at via [cursor].
  static Future<Paged<AppNotification>> list({String? cursor}) async {
    final uid = _requireUid();
    var b = supabase
        .from('notifications')
        .select(_select)
        .eq('recipient_id', uid);
    if (cursor != null) b = b.lt('created_at', cursor);
    final rows = await b.order('created_at', ascending: false).limit(kPageSize);
    final items = (rows as List)
        .map((r) => AppNotification.fromJson(r as Map<String, dynamic>))
        .toList();
    final hasMore = items.length == kPageSize;
    return Paged(
      items: items,
      hasMore: hasMore,
      nextCursor: hasMore ? items.last.createdAt.toIso8601String() : null,
    );
  }

  /// Count of unread notifications for the current user.
  static Future<int> unreadCount() async {
    final uid = _requireUid();
    final res = await supabase
        .from('notifications')
        .select('id')
        .eq('recipient_id', uid)
        .isFilter('read_at', null);
    return (res as List).length;
  }

  /// Mark a single notification as read.
  static Future<void> markRead(String notificationId) async {
    await supabase
        .from('notifications')
        .update({'read_at': DateTime.now().toIso8601String()})
        .eq('id', notificationId);
  }

  /// Mark all notifications for the current user as read.
  static Future<void> markAllRead() async {
    final uid = _requireUid();
    await supabase
        .from('notifications')
        .update({'read_at': DateTime.now().toIso8601String()})
        .eq('recipient_id', uid)
        .isFilter('read_at', null);
  }

  static String _requireUid() {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) {
      throw StateError('NotificationService: no authenticated user');
    }
    return uid;
  }
}
