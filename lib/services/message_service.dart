import 'package:supabase_flutter/supabase_flutter.dart';
import 'event_service.dart';
import 'pagination.dart';
import 'post_service.dart';
import 'supabase_client.dart';

// ── Models ────────────────────────────────────────────────────────────────────

class Conversation {
  final String id;
  final String participantA;
  final String participantB;
  final DateTime? lastMessageAt;
  final DateTime createdAt;
  // Hydrated for the current user's counterpart.
  final String otherUserId;
  final String otherUsername;
  final String? otherAvatarUrl;
  final int unreadCount;
  final String? lastMessageContent;

  const Conversation({
    required this.id,
    required this.participantA,
    required this.participantB,
    this.lastMessageAt,
    required this.createdAt,
    required this.otherUserId,
    required this.otherUsername,
    this.otherAvatarUrl,
    this.unreadCount = 0,
    this.lastMessageContent,
  });

  factory Conversation.fromJson(
    Map<String, dynamic> json,
    String myId, {
    int unreadCount = 0,
    String? lastMessageContent,
  }) {
    final aId = json['participant_a'] as String;
    final bId = json['participant_b'] as String;
    final isA = myId == aId;
    final otherProfile = (isA
        ? json['profile_b']
        : json['profile_a']) as Map<String, dynamic>? ?? {};
    return Conversation(
      id: json['id'] as String,
      participantA: aId,
      participantB: bId,
      lastMessageAt: json['last_message_at'] != null
          ? DateTime.parse(json['last_message_at'] as String)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
      otherUserId: isA ? bId : aId,
      otherUsername: otherProfile['username'] as String? ?? 'user',
      otherAvatarUrl: otherProfile['avatar_url'] as String?,
      unreadCount: unreadCount,
      lastMessageContent: lastMessageContent,
    );
  }
}

class Message {
  final String id;
  final String conversationId;
  final String senderId;
  final String content;
  final DateTime? readAt;
  final DateTime createdAt;
  /// Set when this message shares a post (rich card). Null for plain messages.
  final String? sharedPostId;
  /// Hydrated original post for [sharedPostId], when joined. May be null even
  /// if [sharedPostId] is set (e.g. realtime payload before hydration, or the
  /// original post was deleted).
  final Post? sharedPost;
  /// Set when this message shares an event (rich card).
  final String? sharedEventId;
  /// Hydrated event for [sharedEventId], when joined (see [sharedPost] notes).
  final Event? sharedEvent;

  const Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.content,
    this.readAt,
    required this.createdAt,
    this.sharedPostId,
    this.sharedPost,
    this.sharedEventId,
    this.sharedEvent,
  });

  bool get isRead => readAt != null;
  bool get isSharedPost => sharedPostId != null;
  bool get isSharedEvent => sharedEventId != null;

  Message copyWith({Post? sharedPost, Event? sharedEvent}) => Message(
        id: id,
        conversationId: conversationId,
        senderId: senderId,
        content: content,
        readAt: readAt,
        createdAt: createdAt,
        sharedPostId: sharedPostId,
        sharedPost: sharedPost ?? this.sharedPost,
        sharedEventId: sharedEventId,
        sharedEvent: sharedEvent ?? this.sharedEvent,
      );

  factory Message.fromJson(Map<String, dynamic> json) {
    final sp = json['shared_post'] as Map<String, dynamic>?;
    final se = json['shared_event'] as Map<String, dynamic>?;
    return Message(
      id: json['id'] as String,
      conversationId: json['conversation_id'] as String,
      senderId: json['sender_id'] as String,
      content: json['content'] as String,
      readAt: json['read_at'] != null
          ? DateTime.parse(json['read_at'] as String)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
      sharedPostId: json['shared_post_id'] as String?,
      sharedPost: sp != null ? Post.fromJson(sp) : null,
      sharedEventId: json['shared_event_id'] as String?,
      sharedEvent: se != null ? Event.fromJson(se) : null,
    );
  }
}

// ── Service ───────────────────────────────────────────────────────────────────

class MessageService {
  static const _convSelect =
      '*, profile_a:profiles!participant_a(username, avatar_url), '
      'profile_b:profiles!participant_b(username, avatar_url)';

  // Joins the shared post/event (+ author/host) for rich card rendering.
  static const _msgSelect =
      '*, shared_post:posts!messages_shared_post_id_fkey('
      '*, profiles!posts_user_id_fkey(username, avatar_url)), '
      'shared_event:events!messages_shared_event_id_fkey('
      '*, profiles!events_host_id_fkey(username, avatar_url))';

  static String _requireUid() {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('MessageService: not authenticated');
    return uid;
  }

  /// Returns all conversations for the current user, sorted by most recent
  /// message. Each conversation includes unread count and last message preview.
  static Future<List<Conversation>> getConversations() async {
    final myId = _requireUid();
    final rows = await supabase
        .from('conversations')
        .select(_convSelect)
        .or('participant_a.eq.$myId,participant_b.eq.$myId')
        .order('last_message_at', ascending: false, nullsFirst: false);

    final convs = (rows as List)
        .map((r) => Conversation.fromJson(r as Map<String, dynamic>, myId))
        .toList();

    if (convs.isEmpty) return [];

    final ids = convs.map((c) => c.id).toList();

    // Fetch unread counts.
    List unreadRows = [];
    try {
      unreadRows = await supabase
          .from('messages')
          .select('conversation_id')
          .inFilter('conversation_id', ids)
          .neq('sender_id', myId)
          .isFilter('read_at', null);
    } catch (_) {}

    final unreadMap = <String, int>{};
    for (final r in unreadRows) {
      final cid = r['conversation_id'] as String;
      unreadMap[cid] = (unreadMap[cid] ?? 0) + 1;
    }

    // Fetch last message per conversation (one message each, newest first).
    final lastMap = <String, String>{};
    try {
      for (final id in ids) {
        final res = await supabase
            .from('messages')
            .select('conversation_id, content')
            .eq('conversation_id', id)
            .order('created_at', ascending: false)
            .limit(1);
        if ((res as List).isNotEmpty) {
          lastMap[id] = res.first['content'] as String;
        }
      }
    } catch (_) {}

    return convs.map((c) => Conversation(
          id: c.id,
          participantA: c.participantA,
          participantB: c.participantB,
          lastMessageAt: c.lastMessageAt,
          createdAt: c.createdAt,
          otherUserId: c.otherUserId,
          otherUsername: c.otherUsername,
          otherAvatarUrl: c.otherAvatarUrl,
          unreadCount: unreadMap[c.id] ?? 0,
          lastMessageContent: lastMap[c.id],
        )).toList();
  }

  /// Gets or creates a 1-to-1 conversation between the current user and
  /// [otherUserId]. Returns the conversation id.
  static Future<Conversation> getOrCreate(String otherUserId) async {
    final myId = _requireUid();
    // Enforce ordering: smaller UUID is always participant_a.
    final a = myId.compareTo(otherUserId) < 0 ? myId : otherUserId;
    final b = a == myId ? otherUserId : myId;

    // Upsert — do nothing on conflict so we get the existing row back.
    await supabase.from('conversations').upsert(
      {'participant_a': a, 'participant_b': b},
      onConflict: 'participant_a,participant_b',
      ignoreDuplicates: true,
    );

    final row = await supabase
        .from('conversations')
        .select(_convSelect)
        .eq('participant_a', a)
        .eq('participant_b', b)
        .single();

    return Conversation.fromJson(row, myId);
  }

  /// Paged message history for a conversation, newest first.
  static Future<Paged<Message>> getMessages(
    String conversationId, {
    String? cursor,
  }) async {
    var q = supabase
        .from('messages')
        .select(_msgSelect)
        .eq('conversation_id', conversationId);
    if (cursor != null) q = q.lt('created_at', cursor);
    final rows =
        await q.order('created_at', ascending: false).limit(kPageSize);
    final items = (rows as List)
        .map((r) => Message.fromJson(r as Map<String, dynamic>))
        .toList();
    final hasMore = items.length == kPageSize;
    return Paged(
      items: items,
      hasMore: hasMore,
      nextCursor: hasMore ? items.last.createdAt.toIso8601String() : null,
    );
  }

  /// Sends a message in [conversationId].
  static Future<Message> sendMessage(
      String conversationId, String content) async {
    final myId = _requireUid();
    final row = await supabase
        .from('messages')
        .insert({
          'conversation_id': conversationId,
          'sender_id': myId,
          'content': content.trim(),
        })
        .select(_msgSelect)
        .single();
    return Message.fromJson(row);
  }

  /// Shares [postId] into [conversationId] as a rich post-card message.
  /// [caption] is the message body (the content CHECK requires 1..1000 chars),
  /// defaulting to a short label so the row is always valid.
  static Future<Message> sendSharedPost(
    String conversationId,
    String postId, {
    String caption = 'Shared a post',
  }) async {
    final myId = _requireUid();
    final body = caption.trim().isEmpty ? 'Shared a post' : caption.trim();
    final row = await supabase
        .from('messages')
        .insert({
          'conversation_id': conversationId,
          'sender_id': myId,
          'content': body,
          'shared_post_id': postId,
        })
        .select(_msgSelect)
        .single();
    return Message.fromJson(row);
  }

  /// Convenience: open (or create) the conversation with [otherUserId] and
  /// share [postId] into it in one call. Returns the sent message.
  static Future<Message> sharePostToUser(
    String otherUserId,
    String postId, {
    String caption = 'Shared a post',
  }) async {
    final conv = await getOrCreate(otherUserId);
    return sendSharedPost(conv.id, postId, caption: caption);
  }

  /// Shares [eventId] into [conversationId] as a rich event-card message.
  static Future<Message> sendSharedEvent(
    String conversationId,
    String eventId, {
    String caption = 'Shared an event',
  }) async {
    final myId = _requireUid();
    final body = caption.trim().isEmpty ? 'Shared an event' : caption.trim();
    final row = await supabase
        .from('messages')
        .insert({
          'conversation_id': conversationId,
          'sender_id': myId,
          'content': body,
          'shared_event_id': eventId,
        })
        .select(_msgSelect)
        .single();
    return Message.fromJson(row);
  }

  /// Marks all unread messages from others in [conversationId] as read.
  static Future<void> markRead(String conversationId) async {
    final myId = _requireUid();
    await supabase
        .from('messages')
        .update({'read_at': DateTime.now().toIso8601String()})
        .eq('conversation_id', conversationId)
        .neq('sender_id', myId)
        .isFilter('read_at', null);
  }

  /// Subscribes to new messages in [conversationId].
  /// Call [cancel] on the returned subscription to unsubscribe.
  static RealtimeChannel subscribeToMessages(
    String conversationId,
    void Function(Message) onMessage,
  ) {
    return supabase
        .channel('messages:$conversationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'conversation_id',
            value: conversationId,
          ),
          callback: (payload) async {
            try {
              var msg = Message.fromJson(payload.newRecord);
              // Realtime payloads carry no joins; hydrate shared post/event on
              // the fly so the rich card renders for live-arriving messages.
              if (msg.isSharedPost && msg.sharedPost == null) {
                final post = await PostService.fetchById(msg.sharedPostId!);
                if (post != null) msg = msg.copyWith(sharedPost: post);
              }
              if (msg.isSharedEvent && msg.sharedEvent == null) {
                final event = await EventService.fetchById(msg.sharedEventId!);
                if (event != null) msg = msg.copyWith(sharedEvent: event);
              }
              onMessage(msg);
            } catch (_) {}
          },
        )
        .subscribe();
  }
}
