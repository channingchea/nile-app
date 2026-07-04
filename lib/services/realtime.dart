import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Coarse connection state for a realtime subscription, for driving a
/// "reconnecting…" indicator.
enum RealtimeConnState {
  /// First join in flight — no data has arrived over the channel yet.
  connecting,

  /// Subscribed and receiving changes.
  live,

  /// Was live, dropped, and is retrying. Data on screen may be stale.
  reconnecting,
}

/// Adds the two things Supabase realtime doesn't give you out of the box:
/// **backfill on rejoin** and a **UI-facing connection state**.
///
/// Supabase's socket already reconnects and rejoins channels with backoff, but
/// it does not replay the rows that changed while you were disconnected. This
/// wrapper detects a re-subscribe (a `subscribed` status that follows an error
/// or close) and calls [onResync] so the screen can refetch what it missed, and
/// reports a coarse [RealtimeConnState] to [onState].
///
/// Usage — pass a [build] that forwards the status callback into the service's
/// subscribe method and returns the channel it created:
///
/// ```dart
/// _conn = ResilientChannel(
///   build: (onStatus) => MessageService.subscribeToMessages(
///     convId, _onMessage, onStatus: onStatus,
///   ),
///   onResync: _resync,
///   onState: (s) => setState(() => _connState = s),
/// );
/// ...
/// _conn.dispose(); // in State.dispose
/// ```
class ResilientChannel {
  ResilientChannel({
    required RealtimeChannel Function(
      void Function(RealtimeSubscribeStatus status, Object? error) onStatus,
    ) build,
    this.onResync,
    this.onState,
  }) {
    _channel = build(_handleStatus);
  }

  /// Called on every successful *re*-subscribe (not the first join) so the
  /// screen can backfill rows missed while offline.
  final FutureOr<void> Function()? onResync;

  /// Notified whenever the coarse connection state changes.
  final void Function(RealtimeConnState state)? onState;

  late final RealtimeChannel _channel;
  bool _everSubscribed = false;
  bool _disposed = false;
  RealtimeConnState _state = RealtimeConnState.connecting;

  RealtimeConnState get state => _state;
  RealtimeChannel get channel => _channel;

  void _set(RealtimeConnState next) {
    if (_state == next || _disposed) return;
    _state = next;
    onState?.call(next);
  }

  void _handleStatus(RealtimeSubscribeStatus status, Object? error) {
    if (_disposed) return;
    switch (status) {
      case RealtimeSubscribeStatus.subscribed:
        final rejoined = _everSubscribed;
        _everSubscribed = true;
        _set(RealtimeConnState.live);
        // Only backfill on a *re*-join; the first join's own fetch already ran.
        if (rejoined) onResync?.call();
      case RealtimeSubscribeStatus.channelError:
      case RealtimeSubscribeStatus.timedOut:
      case RealtimeSubscribeStatus.closed:
        _set(
          _everSubscribed
              ? RealtimeConnState.reconnecting
              : RealtimeConnState.connecting,
        );
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _channel.unsubscribe();
  }
}
