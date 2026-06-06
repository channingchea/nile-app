import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_client.dart';

// ── Model ─────────────────────────────────────────────────────────────────────

/// An ephemeral live-chat message. Carried over Supabase Realtime broadcast —
/// never persisted, so the sender's username travels inside the payload (no
/// profile join is possible on a broadcast channel).
class ChatMessage {
  final String senderId;
  final String username;
  final String content;
  final DateTime sentAt;

  const ChatMessage({
    required this.senderId,
    required this.username,
    required this.content,
    required this.sentAt,
  });

  bool get isMine => senderId == supabase.auth.currentUser?.id;

  Map<String, dynamic> toJson() => {
        'sender_id': senderId,
        'username': username,
        'content': content,
        'sent_at': sentAt.toIso8601String(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        senderId: json['sender_id'] as String? ?? '',
        username: json['username'] as String? ?? 'viewer',
        content: json['content'] as String? ?? '',
        sentAt: DateTime.tryParse(json['sent_at'] as String? ?? '') ??
            DateTime.now(),
      );
}

// ── Service ─────────────────────────────────────────────────────────────────

/// Live-stream chat over Supabase Realtime broadcast. Messages are ephemeral:
/// no table, no history, no RLS — they exist only for clients connected to the
/// channel at send time. Mirrors the channel lifecycle of [EventService].
class ChatService {
  static const _event = 'msg';

  static String _channelName(String eventId) => 'live_chat:$eventId';

  /// Opens the broadcast channel for [eventId] and invokes [onMessage] for each
  /// incoming message. Returns the channel — call [RealtimeChannel.unsubscribe]
  /// to leave. `self: true` lets the sender see their own messages echoed back,
  /// keeping a single render path for all messages.
  static RealtimeChannel subscribe(
    String eventId,
    void Function(ChatMessage) onMessage,
  ) {
    final channel = supabase.channel(
      _channelName(eventId),
      opts: const RealtimeChannelConfig(self: true),
    );
    channel
        .onBroadcast(
          event: _event,
          callback: (payload) {
            try {
              onMessage(ChatMessage.fromJson(payload));
            } catch (_) {}
          },
        )
        .subscribe();
    return channel;
  }

  /// Broadcasts [content] from the current user on [channel]. Trims and ignores
  /// empty content. [username] is resolved once by the caller at join time.
  static Future<void> send(
    RealtimeChannel channel, {
    required String username,
    required String content,
  }) async {
    final uid = supabase.auth.currentUser?.id;
    final text = content.trim();
    if (uid == null || text.isEmpty) return;
    final msg = ChatMessage(
      senderId: uid,
      username: username,
      content: text,
      sentAt: DateTime.now(),
    );
    await channel.sendBroadcastMessage(event: _event, payload: msg.toJson());
  }
}
