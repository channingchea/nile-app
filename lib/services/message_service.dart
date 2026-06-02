import 'package:supabase_flutter/supabase_flutter.dart';
import 'pagination.dart';
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

  const Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.content,
    this.readAt,
    required this.createdAt,
  });

  bool get isRead => readAt != null;

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'] as String,
        conversationId: json['conversation_id'] as String,
        senderId: json['sender_id'] as String,
        content: json['content'] as String,
        readAt: json['read_at'] != null
            ? DateTime.parse(json['read_at'] as String)
            : null,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

// ── Service ───────────────────────────────────────────────────────────────────

class MessageService {
  static const _convSelect =
      '*, profile_a:profiles!participant_a(username, avatar_url), '
      'profile_b:profiles!participant_b(username, avatar_url)';

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

    return Conversation.fromJson(row as Map<String, dynamic>, myId);
  }

  /// Paged message history for a conversation, newest first.
  static Future<Paged<Message>> getMessages(
    String conversationId, {
    String? cursor,
  }) async {
    var q = supabase
        .from('messages')
        .select()
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
        .select()
        .single();
    return Message.fromJson(row as Map<String, dynamic>);
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
          callback: (payload) {
            try {
              final msg = Message.fromJson(
                  payload.newRecord as Map<String, dynamic>);
              onMessage(msg);
            } catch (_) {}
          },
        )
        .subscribe();
  }
}
