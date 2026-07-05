import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_client.dart';

// ── Model ─────────────────────────────────────────────────────────────────────

/// An ephemeral live-chat message. Carried over Supabase Realtime broadcast —
/// never persisted, so the sender's username travels inside the payload (no
/// profile join is possible on a broadcast channel).
class ChatMessage {
  final String senderId;
  final String username;
  final String? avatarUrl;
  final String content;
  final DateTime sentAt;
  // 'user' = a viewer's message; 'system' = an app-generated announcement
  // (e.g. a tip), rendered without an author and styled distinctly.
  final String kind;

  const ChatMessage({
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
    'sender_id': senderId,
    'username': username,
    if (avatarUrl != null) 'avatar_url': avatarUrl,
    'content': content,
    'sent_at': sentAt.toIso8601String(),
    'kind': kind,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
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

// ── Service ─────────────────────────────────────────────────────────────────

/// Live-stream chat over Supabase Realtime broadcast. Messages are ephemeral:
/// no table, no history, no RLS — they exist only for clients connected to the
/// channel at send time. Mirrors the channel lifecycle of [EventService].
class ChatService {
  static const _event = 'msg';
  static const _reactEvent = 'react';

  static String _channelName(String eventId) => 'live_chat:$eventId';

  /// Opens the broadcast channel for [eventId] and invokes [onMessage] for each
  /// incoming message (and [onReaction] for each emoji burst, if provided).
  /// Returns the channel — call [RealtimeChannel.unsubscribe] to leave.
  /// `self: true` echoes the sender's own messages/reactions back, keeping a
  /// single render path for everything.
  static RealtimeChannel subscribe(
    String eventId,
    void Function(ChatMessage) onMessage, {
    void Function(LiveReaction)? onReaction,
    void Function(RealtimeSubscribeStatus status, Object? error)? onStatus,
  }) {
    final channel = supabase.channel(
      _channelName(eventId),
      opts: const RealtimeChannelConfig(self: true),
    );
    channel.onBroadcast(
      event: _event,
      callback: (payload) {
        try {
          onMessage(ChatMessage.fromJson(payload));
        } catch (_) {}
      },
    );
    if (onReaction != null) {
      channel.onBroadcast(
        event: _reactEvent,
        callback: (payload) {
          try {
            onReaction(LiveReaction.fromJson(payload));
          } catch (_) {}
        },
      );
    }
    channel.subscribe(onStatus);
    return channel;
  }

  /// Broadcasts [content] from the current user on [channel]. Trims and ignores
  /// empty content. [username]/[avatarUrl] are resolved once by the caller at
  /// join time (broadcast carries no profile join).
  static Future<void> send(
    RealtimeChannel channel, {
    required String username,
    String? avatarUrl,
    required String content,
  }) async {
    final uid = supabase.auth.currentUser?.id;
    final text = content.trim();
    if (uid == null || text.isEmpty) return;
    final msg = ChatMessage(
      senderId: uid,
      username: username,
      avatarUrl: avatarUrl,
      content: text,
      sentAt: DateTime.now(),
    );
    await channel.sendBroadcastMessage(event: _event, payload: msg.toJson());
  }

  /// Broadcasts a tap-to-react [emoji] on [channel]. Throttling is the caller's
  /// responsibility (the viewer coalesces taps to protect the channel).
  static Future<void> sendReaction(
    RealtimeChannel channel, {
    required String emoji,
  }) async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return;
    final r = LiveReaction(emoji: emoji, senderId: uid);
    await channel.sendBroadcastMessage(event: _reactEvent, payload: r.toJson());
  }

  /// Broadcasts a system announcement (e.g. a tip) on [channel]. Rendered
  /// author-less and styled distinctly; carries the sender id only so the
  /// tipper's own client can dedupe. Ephemeral, like every chat message.
  static Future<void> sendSystem(
    RealtimeChannel channel, {
    required String content,
  }) async {
    final text = content.trim();
    if (text.isEmpty) return;
    final msg = ChatMessage(
      senderId: supabase.auth.currentUser?.id ?? '',
      username: '',
      content: text,
      sentAt: DateTime.now(),
      kind: 'system',
    );
    await channel.sendBroadcastMessage(event: _event, payload: msg.toJson());
  }
}
