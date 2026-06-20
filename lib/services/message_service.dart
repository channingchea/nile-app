import 'dart:typed_data';

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

  /// True when the counterpart is currently hosting a live (or soundcheck) show.
  final bool isLive;

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
    this.isLive = false,
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
    final otherProfile =
        (isA ? json['profile_b'] : json['profile_a'])
            as Map<String, dynamic>? ??
        {};
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

/// A single reaction on a message. One row per (message, user); DMs being 1:1,
/// the screen renders distinct emojis without counts.
class MessageReaction {
  final String userId;
  final String emoji;

  const MessageReaction({required this.userId, required this.emoji});

  factory MessageReaction.fromJson(Map<String, dynamic> json) =>
      MessageReaction(
        userId: json['user_id'] as String,
        emoji: json['emoji'] as String,
      );
}

class Message {
  final String id;
  final String conversationId;
  final String senderId;
  final String content;
  final DateTime? readAt;
  final DateTime createdAt;

  /// Reactions on this message (one per user). Empty when none.
  final List<MessageReaction> reactions;

  /// Public URL of an attached image, when this is an image message.
  final String? imageUrl;

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
    this.imageUrl,
    this.sharedPostId,
    this.sharedPost,
    this.sharedEventId,
    this.sharedEvent,
    this.reactions = const [],
  });

  bool get isRead => readAt != null;

  /// The given user's current reaction emoji, or null if they haven't reacted.
  String? reactionOf(String userId) {
    for (final r in reactions) {
      if (r.userId == userId) return r.emoji;
    }
    return null;
  }
  bool get isImage => imageUrl != null && imageUrl!.isNotEmpty;
  bool get isSharedPost => sharedPostId != null;
  bool get isSharedEvent => sharedEventId != null;

  Message copyWith({
    DateTime? readAt,
    Post? sharedPost,
    Event? sharedEvent,
    List<MessageReaction>? reactions,
  }) => Message(
    id: id,
    conversationId: conversationId,
    senderId: senderId,
    content: content,
    readAt: readAt ?? this.readAt,
    createdAt: createdAt,
    imageUrl: imageUrl,
    sharedPostId: sharedPostId,
    sharedPost: sharedPost ?? this.sharedPost,
    sharedEventId: sharedEventId,
    sharedEvent: sharedEvent ?? this.sharedEvent,
    reactions: reactions ?? this.reactions,
  );

  factory Message.fromJson(Map<String, dynamic> json) {
    final sp = json['shared_post'] as Map<String, dynamic>?;
    final se = json['shared_event'] as Map<String, dynamic>?;
    final rx = json['message_reactions'] as List?;
    return Message(
      reactions: rx == null
          ? const <MessageReaction>[]
          : rx
                .map((r) =>
                    MessageReaction.fromJson(r as Map<String, dynamic>))
                .toList(),
      id: json['id'] as String,
      conversationId: json['conversation_id'] as String,
      senderId: json['sender_id'] as String,
      content: json['content'] as String,
      readAt: json['read_at'] != null
          ? DateTime.parse(json['read_at'] as String)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
      imageUrl: json['image_url'] as String?,
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

  // Joins the shared post/event (+ author/host) for rich card rendering, plus
  // this message's reactions (one row per user) for chip rendering.
  static const _msgSelect =
      '*, shared_post:posts!messages_shared_post_id_fkey('
      '*, profiles!posts_user_id_fkey(username, avatar_url)), '
      'shared_event:events!messages_shared_event_id_fkey('
      '*, profiles!events_host_id_fkey(username, avatar_url)), '
      'message_reactions(user_id, emoji)';

  static String _requireUid() {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) throw StateError('MessageService: not authenticated');
    return uid;
  }

  /// Returns all conversations for the current user, sorted by most recent
  /// message. Each row already carries the counterpart profile, unread count,
  /// last-message preview, and live-presence flag — assembled server-side by
  /// the `get_conversations_for_user` RPC in one round trip.
  static Future<List<Conversation>> getConversations() async {
    _requireUid();
    final rows = await supabase.rpc('get_conversations_for_user');
    return (rows as List)
        .map((r) => _conversationFromRpc(r as Map<String, dynamic>))
        .toList();
  }

  static Conversation _conversationFromRpc(Map<String, dynamic> r) {
    final last = r['last_message_at'];
    return Conversation(
      id: r['id'] as String,
      participantA: r['participant_a'] as String,
      participantB: r['participant_b'] as String,
      lastMessageAt: last != null ? DateTime.parse(last as String) : null,
      createdAt: DateTime.parse(r['created_at'] as String),
      otherUserId: r['other_user_id'] as String,
      otherUsername: r['other_username'] as String? ?? 'user',
      otherAvatarUrl: r['other_avatar_url'] as String?,
      unreadCount: (r['unread_count'] as num?)?.toInt() ?? 0,
      lastMessageContent: r['last_message_content'] as String?,
      isLive: r['is_live'] as bool? ?? false,
    );
  }

  /// Gets or creates a 1-to-1 conversation between the current user and
  /// [otherUserId]. Returns the conversation id.
  static Future<Conversation> getOrCreate(String otherUserId) async {
    final myId = _requireUid();
    // Enforce ordering: smaller UUID is always participant_a.
    final a = myId.compareTo(otherUserId) < 0 ? myId : otherUserId;
    final b = a == myId ? otherUserId : myId;

    // Upsert — do nothing on conflict so we get the existing row back.
    await supabase
        .from('conversations')
        .upsert(
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
    final rows = await q.order('created_at', ascending: false).limit(kPageSize);
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
    String conversationId,
    String content,
  ) async {
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

  /// Uploads [bytes] to the public 'messages' bucket under the sender's folder
  /// and sends an image message in [conversationId]. [caption] is the body
  /// (the content CHECK requires 1..1000 chars), defaulting to 'Photo'.
  static Future<Message> sendImageMessage(
    String conversationId,
    Uint8List bytes, {
    String caption = 'Photo',
  }) async {
    final myId = _requireUid();
    final path =
        '$myId/${DateTime.now().millisecondsSinceEpoch}.jpg';
    await supabase.storage
        .from('messages')
        .uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: true,
          ),
        );
    final imageUrl = supabase.storage.from('messages').getPublicUrl(path);
    final body = caption.trim().isEmpty ? 'Photo' : caption.trim();
    final row = await supabase
        .from('messages')
        .insert({
          'conversation_id': conversationId,
          'sender_id': myId,
          'content': body,
          'image_url': imageUrl,
        })
        .select(_msgSelect)
        .single();
    return Message.fromJson(row);
  }

  /// Deletes a message the current user authored. RLS should also enforce
  /// sender-only deletion server-side; the eq('sender_id') guard is defensive.
  static Future<void> deleteMessage(String messageId) async {
    final myId = _requireUid();
    await supabase
        .from('messages')
        .delete()
        .eq('id', messageId)
        .eq('sender_id', myId);
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

  // ── Reactions ───────────────────────────────────────────────────────────────

  /// Sets the current user's reaction on [messageId] to [emoji], replacing any
  /// existing one (upsert on the (message_id, user_id) unique key). [conversationId]
  /// is denormalized onto the row so realtime can filter by it.
  static Future<void> setReaction(
    String messageId,
    String conversationId,
    String emoji,
  ) async {
    final myId = _requireUid();
    await supabase.from('message_reactions').upsert({
      'message_id': messageId,
      'conversation_id': conversationId,
      'user_id': myId,
      'emoji': emoji,
    }, onConflict: 'message_id,user_id');
  }

  /// Removes the current user's reaction on [messageId] (toggle off).
  static Future<void> removeReaction(String messageId) async {
    final myId = _requireUid();
    await supabase
        .from('message_reactions')
        .delete()
        .eq('message_id', messageId)
        .eq('user_id', myId);
  }

  /// Fetches the current set of reactions for [messageId]. Used to reconcile a
  /// single message after a realtime reaction event (payloads carry only the
  /// changed row, so we re-read the authoritative set).
  static Future<List<MessageReaction>> fetchReactions(String messageId) async {
    final rows = await supabase
        .from('message_reactions')
        .select('user_id, emoji')
        .eq('message_id', messageId);
    return (rows as List)
        .map((r) => MessageReaction.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  /// Subscribes to reaction changes (insert/update/delete) in [conversationId],
  /// filtered by the denormalized conversation_id (mirrors [subscribeToMessages]).
  /// Each payload carries only the changed row, so [onChange] is handed the
  /// affected message_id; the screen re-fetches that message's reactions and
  /// patches its in-memory copy. Call [cancel] on the channel to unsubscribe.
  static RealtimeChannel subscribeToReactions(
    String conversationId,
    void Function(String messageId) onChange,
  ) {
    final filter = PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: 'conversation_id',
      value: conversationId,
    );
    void emit(PostgresChangePayload payload) {
      // INSERT/UPDATE carry newRecord; DELETE carries oldRecord.
      final id = (payload.newRecord['message_id'] ??
          payload.oldRecord['message_id']) as String?;
      if (id != null) onChange(id);
    }

    return supabase
        .channel('reactions:$conversationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'message_reactions',
          filter: filter,
          callback: emit,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'message_reactions',
          filter: filter,
          callback: emit,
        )
        .onPostgresChanges(
          // DELETE old records carry only the PK; the conversation_id filter
          // isn't applied to deletes, so the screen ignores unknown message_ids.
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'message_reactions',
          callback: emit,
        )
        .subscribe();
  }

  /// Subscribes to new, updated, and deleted messages in [conversationId].
  /// [onMessage] fires for inserts; [onUpdate] fires for updates (e.g. a read
  /// receipt setting read_at); [onDelete] fires with the deleted message id.
  /// Call [cancel] on the returned subscription to unsubscribe.
  static RealtimeChannel subscribeToMessages(
    String conversationId,
    void Function(Message) onMessage, {
    void Function(Message)? onUpdate,
    void Function(String id)? onDelete,
  }) {
    final filter = PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: 'conversation_id',
      value: conversationId,
    );
    return supabase
        .channel('messages:$conversationId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: filter,
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
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'messages',
          filter: filter,
          callback: (payload) {
            try {
              onUpdate?.call(Message.fromJson(payload.newRecord));
            } catch (_) {}
          },
        )
        .onPostgresChanges(
          // DELETE old records reliably carry only the primary key, and the
          // conversation_id filter isn't applied to deletes — the screen
          // filters by whether the id is in its list.
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'messages',
          callback: (payload) {
            try {
              final id = payload.oldRecord['id'] as String?;
              if (id != null) onDelete?.call(id);
            } catch (_) {}
          },
        )
        .subscribe();
  }

  /// Ephemeral typing channel for [conversationId] using Supabase broadcast
  /// (no schema/persistence — events vanish when no one is listening).
  /// [onTyping] fires when the *other* participant starts or stops typing;
  /// its bool is their current typing state. Call [sendTyping] on the returned
  /// channel via [broadcastTyping]; unsubscribe when leaving the screen.
  static RealtimeChannel subscribeToTyping(
    String conversationId,
    void Function(bool isTyping) onTyping,
  ) {
    final myId = _requireUid();
    return supabase
        .channel('typing:$conversationId')
        .onBroadcast(
          event: 'typing',
          // The broadcast frame nests our sent map under a 'payload' key:
          // {event, type, payload: {sender_id, is_typing}}. Fall back to the
          // top level in case a future client flattens it.
          callback: (frame) {
            final data =
                (frame['payload'] as Map?)?.cast<String, dynamic>() ?? frame;
            if (data['sender_id'] == myId) return; // ignore our own echoes
            onTyping(data['is_typing'] == true);
          },
        )
        .subscribe();
  }

  /// Broadcasts the current user's typing state on [channel] (from
  /// [subscribeToTyping]). Cheap and fire-and-forget.
  static void broadcastTyping(RealtimeChannel channel, bool isTyping) {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) return;
    channel.sendBroadcastMessage(
      event: 'typing',
      payload: {'sender_id': myId, 'is_typing': isTyping},
    );
  }
}
