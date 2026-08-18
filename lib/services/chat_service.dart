import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_client.dart';

// ── Model ─────────────────────────────────────────────────────────────────────

/// A live-chat message, carried to the audience over Supabase Realtime
/// broadcast.
///
/// The audience experience is still ephemeral — nobody arriving late sees what
/// came before them, and there is no history to scroll. But since #16 phase 1
/// every message sent through [ChatService.send] is also recorded server-side
/// (`live_chat_messages`, migration 0107) so a host can actually remove one,
/// a report can carry the real text as evidence, and a ban has something to
/// sweep. That record is kept 30 days and is readable only by the event's host
/// and platform admins.
///
/// The sender's username travels inside the payload because a broadcast carries
/// no profile join. It is stamped by the server from `profiles`, not by the
/// sending client — that is what stops one viewer chatting under another's name.
class ChatMessage {
  /// `live_chat_messages.id`, when the message came through the server.
  ///
  /// Null for two reasons, both normal: system announcements are not chat, and
  /// builds that predate #16 still broadcast straight to the channel. A null id
  /// simply means this line cannot be individually removed — the sender-wide
  /// removal a ban issues still applies to it.
  final String? id;
  final String senderId;
  final String username;
  final String? avatarUrl;
  final String content;
  final DateTime sentAt;
  // 'user' = a viewer's message; 'system' = an app-generated announcement
  // (e.g. a tip), rendered without an author and styled distinctly.
  final String kind;

  const ChatMessage({
    this.id,
    required this.senderId,
    required this.username,
    this.avatarUrl,
    required this.content,
    required this.sentAt,
    this.kind = 'user',
  });

  bool get isMine => senderId == supabase.auth.currentUser?.id;
  bool get isSystem => kind == 'system';

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'sender_id': senderId,
    'username': username,
    if (avatarUrl != null) 'avatar_url': avatarUrl,
    'content': content,
    'sent_at': sentAt.toUtc().toIso8601String(),
    'kind': kind,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String?,
    senderId: json['sender_id'] as String? ?? '',
    username: json['username'] as String? ?? 'viewer',
    avatarUrl: json['avatar_url'] as String?,
    content: json['content'] as String? ?? '',
    sentAt:
        DateTime.tryParse(json['sent_at'] as String? ?? '') ?? DateTime.now(),
    kind: json['kind'] as String? ?? 'user',
  );
}

/// An ephemeral tap-to-react emoji, broadcast on the same channel as chat.
class LiveReaction {
  final String emoji;
  final String senderId;
  const LiveReaction({required this.emoji, required this.senderId});

  Map<String, dynamic> toJson() => {'emoji': emoji, 'sender_id': senderId};

  factory LiveReaction.fromJson(Map<String, dynamic> json) => LiveReaction(
    emoji: json['emoji'] as String? ?? '❤️',
    senderId: json['sender_id'] as String? ?? '',
  );
}

/// A message the server refused, carrying wording already fit to show the user
/// ("You're sending messages too quickly"). Thrown rather than returned so a
/// caller cannot forget to check.
class ChatSendException implements Exception {
  final String message;
  const ChatSendException(this.message);
  @override
  String toString() => message;
}

// ── Service ─────────────────────────────────────────────────────────────────

/// Live-stream chat. Delivery is a Supabase Realtime broadcast; authorship and
/// moderation run through the `live-chat` Edge Function.
class ChatService {
  static const _event = 'msg';
  static const _reactEvent = 'react';
  static const _removeEvent = 'rm';
  static const _removeSenderEvent = 'rm_user';

  /// Hard cap enforced server-side too. The composer should stop the user well
  /// before this; it exists so a modified client cannot paste an essay.
  static const int maxMessageLength = 500;

  static String _channelName(String eventId) => 'live_chat:$eventId';

  /// Server-authored announcements (tips today). Read-only for clients: the
  /// Realtime Authorization policy in migration 0104 grants SELECT but no
  /// INSERT on this topic, so only the service role can put a message on it.
  /// That is what stops a viewer forging a "@host tipped $200 🎉" line in the
  /// distinct system style, to an audience that just paid to be in the room.
  static String _systemChannelName(String eventId) => 'live_system:$eventId';

  /// Opens the broadcast channel for [eventId] and invokes [onMessage] for each
  /// incoming message (and [onReaction] for each emoji burst, if provided).
  /// Returns the channel — call [RealtimeChannel.unsubscribe] to leave.
  ///
  /// [onRemove] fires when the host removes a single message, [onRemoveSender]
  /// when a ban wipes everything one person said. Both are silent by design:
  /// the line disappears with no "message removed" placeholder, because a
  /// tombstone is a trophy.
  ///
  /// `self: true` echoes the sender's own reactions back, keeping a single
  /// render path. Messages now arrive from the server for everyone including
  /// their author, so they take the same path either way.
  /// `onBroadcast` hands the callback the whole realtime envelope
  /// (`{type, event, payload}`), not the payload the sender wrote. Reading the
  /// fields straight off it silently yields every default — a message renders
  /// as "viewer" with no text — so unwrap one level first. Tolerates an
  /// already-unwrapped map so a future client change can't break it back.
  static Map<String, dynamic> _body(Map<String, dynamic> envelope) {
    final inner = envelope['payload'];
    return inner is Map ? Map<String, dynamic>.from(inner) : envelope;
  }

  static RealtimeChannel subscribe(
    String eventId,
    void Function(ChatMessage) onMessage, {
    void Function(LiveReaction)? onReaction,
    void Function(String messageId)? onRemove,
    void Function(String senderId)? onRemoveSender,
    void Function(RealtimeSubscribeStatus status, Object? error)? onStatus,
  }) {
    // private: true routes the join and every broadcast through the Realtime
    // Authorization policies in migration 0104. Before that the only thing
    // between a stranger and a paid show's chat was knowing the slug — which is
    // in the public share URL.
    final channel = supabase.channel(
      _channelName(eventId),
      opts: const RealtimeChannelConfig(self: true, private: true),
    );
    channel.onBroadcast(
      event: _event,
      callback: (payload) {
        try {
          final msg = ChatMessage.fromJson(_body(payload));
          // A client cannot author a system message any more, and one arriving
          // on the chat topic is by definition forged — drop it rather than
          // render it in the announcement style.
          if (msg.isSystem) return;
          onMessage(msg);
        } catch (_) {}
      },
    );
    if (onReaction != null) {
      channel.onBroadcast(
        event: _reactEvent,
        callback: (payload) {
          try {
            onReaction(LiveReaction.fromJson(_body(payload)));
          } catch (_) {}
        },
      );
    }
    if (onRemove != null) {
      channel.onBroadcast(
        event: _removeEvent,
        callback: (payload) {
          final id = _body(payload)['id'] as String?;
          if (id != null && id.isNotEmpty) onRemove(id);
        },
      );
    }
    if (onRemoveSender != null) {
      channel.onBroadcast(
        event: _removeSenderEvent,
        callback: (payload) {
          final id = _body(payload)['sender_id'] as String?;
          if (id != null && id.isNotEmpty) onRemoveSender(id);
        },
      );
    }
    channel.subscribe(onStatus);
    return channel;
  }

  /// Opens the read-only system-announcement channel for [eventId]. Separate
  /// from [subscribe] so the caller can tear both down; nothing is ever sent on
  /// it from the client.
  static RealtimeChannel subscribeSystem(
    String eventId,
    void Function(ChatMessage) onMessage,
  ) {
    final channel = supabase.channel(
      _systemChannelName(eventId),
      opts: const RealtimeChannelConfig(private: true),
    );
    channel.onBroadcast(
      event: _event,
      callback: (payload) {
        try {
          onMessage(ChatMessage.fromJson(_body(payload)));
        } catch (_) {}
      },
    );
    channel.subscribe();
    return channel;
  }

  /// Sends [content] as the current user in [eventId] (the LiveKit slug).
  ///
  /// Goes through the `live-chat` function rather than straight onto the
  /// channel: that is where the length cap, the rate limit, the ban check and
  /// the server-side record live. The message reaches the room only after it is
  /// written, which costs a round trip and buys a message that can be removed.
  ///
  /// The sender's own copy arrives back over the broadcast like everyone
  /// else's, so there is nothing to echo locally.
  ///
  /// Throws [ChatSendException] with wording fit to show the user.
  static Future<void> send({
    required String eventId,
    required String content,
  }) async {
    final text = content.trim();
    if (text.isEmpty) return;

    try {
      final res = await supabase.functions.invoke(
        'live-chat',
        body: {'action': 'send', 'eventId': eventId, 'content': text},
      );
      final data = res.data;
      if (data is Map && data['error'] != null) {
        throw ChatSendException(data['error'].toString());
      }
    } on FunctionException catch (e) {
      final details = e.details;
      final msg = details is Map ? details['error']?.toString() : null;
      throw ChatSendException(msg ?? "Message didn't send — try again");
    } catch (e) {
      if (e is ChatSendException) rethrow;
      throw const ChatSendException("Message didn't send — try again");
    }
  }

  /// Host: remove one message for everyone. Silent — the line simply stops
  /// being rendered. The row is soft-deleted, not destroyed, so a report filed
  /// against it still has its text.
  static Future<void> removeMessage({
    required String eventId,
    required String messageId,
  }) => _moderate({
    'action': 'remove',
    'eventId': eventId,
    'messageId': messageId,
  });

  /// Host: ban [targetId] from this event's chat. Permanent for this event —
  /// it also wipes what they already said, disconnects them from the room, and
  /// stops `viewer-token` letting them back in.
  static Future<void> banSender({
    required String eventId,
    required String targetId,
  }) => _moderate({
    'action': 'ban',
    'eventId': eventId,
    'targetId': targetId,
  });

  /// Host: change how the room behaves — whether crew may moderate, slow mode,
  /// and who may speak. Partial: only the keys present in [patch] are written,
  /// so a client that predates one control cannot blank it.
  ///
  /// Keys: `crewModeration` (bool), `slowModeSeconds` (int 0-300),
  /// `access` ('everyone' | 'followers' | 'ticket_holders').
  static Future<void> updateSettings({
    required String eventId,
    required Map<String, dynamic> patch,
  }) => _moderate({'action': 'settings', 'eventId': eventId, ...patch});

  static Future<void> _moderate(Map<String, dynamic> body) async {
    try {
      final res = await supabase.functions.invoke('live-chat', body: body);
      final data = res.data;
      if (data is Map && data['error'] != null) {
        throw ChatSendException(data['error'].toString());
      }
    } on FunctionException catch (e) {
      final details = e.details;
      final msg = details is Map ? details['error']?.toString() : null;
      throw ChatSendException(msg ?? 'That did not go through — try again');
    }
  }

  /// Broadcasts a tap-to-react [emoji] on [channel]. Throttling is the caller's
  /// responsibility (the viewer coalesces taps to protect the channel).
  ///
  /// Still a direct broadcast, unlike [send]: a reaction carries no text to
  /// moderate and arrives in bursts, so routing it through a function would buy
  /// nothing and cost a round trip per tap.
  static Future<void> sendReaction(
    RealtimeChannel channel, {
    required String emoji,
  }) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return;
    final r = LiveReaction(emoji: emoji, senderId: uid);
    await channel.sendBroadcastMessage(event: _reactEvent, payload: r.toJson());
  }

  // sendSystem is gone on purpose (review E1). Announcements are authored by
  // the server now — stripe-webhook broadcasts to live_system:<slug> when a tip
  // actually settles. That also fixed the two ways the old client-side path got
  // it wrong (E10): a cancelled tip used to re-announce the viewer's PREVIOUS
  // tip, and a tip that settled after the viewer closed the screen was never
  // announced at all.
}
