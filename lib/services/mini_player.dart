import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

/// Owns the currently-docked replay so playback outlives the screen that
/// started it.
///
/// The whole point of the mini player is that navigating away doesn't stop the
/// audio, and a [VideoPlayerController] only survives if something outside the
/// widget tree holds it. So the screen hands its controller over
/// ([adopt]) instead of disposing it, and takes it back ([reclaim]) if the user
/// reopens the same replay — no second signed-URL round-trip, no restart from
/// zero.
///
/// Exactly one owner at a time: whoever holds the controller disposes it.
class MiniPlayer extends ChangeNotifier {
  MiniPlayer._();
  static final MiniPlayer instance = MiniPlayer._();

  VideoPlayerController? _controller;
  String? _eventId;
  String _title = '';
  String? _subtitle;

  VideoPlayerController? get controller => _controller;

  /// Event id of what's docked — the same id [reclaim] matches on and the id
  /// the expand button routes to.
  String? get eventId => _eventId;

  String get title => _title;
  String? get subtitle => _subtitle;
  bool get isActive => _controller != null;

  /// Dock a controller that is already initialised (and usually playing).
  /// Anything previously docked is disposed — one player, one dock.
  void adopt(
    VideoPlayerController controller, {
    required String eventId,
    required String title,
    String? subtitle,
  }) {
    if (identical(_controller, controller)) return;
    _controller?.dispose();
    _controller = controller;
    _eventId = eventId;
    _title = title;
    _subtitle = subtitle;
    _notifySoon();
  }

  /// Hand the controller back to a screen reopening the same replay, clearing
  /// the dock. Returns null when a different replay (or nothing) is docked, in
  /// which case the caller creates its own.
  VideoPlayerController? reclaim(String eventId) {
    if (_controller == null || _eventId != eventId) return null;
    final controller = _controller;
    _clear();
    _notifySoon();
    return controller;
  }

  /// User dismissed the dock: stop and release.
  void close() {
    final controller = _controller;
    _clear();
    notifyListeners();
    // Disposed after the frame that removes the dock. Tearing down the texture
    // while `VideoPlayer` is still mounted logs a platform-view error.
    if (controller != null) {
      SchedulerBinding.instance.addPostFrameCallback((_) => controller.dispose());
    }
  }

  void togglePlay() {
    final c = _controller;
    if (c == null) return;
    c.value.isPlaying ? c.pause() : c.play();
    notifyListeners();
  }

  void _clear() {
    _controller = null;
    _eventId = null;
    _title = '';
    _subtitle = null;
  }

  /// [adopt] and [reclaim] are both called from `initState`/`dispose`, where a
  /// synchronous notify would mark the host overlay dirty mid-build.
  void _notifySoon() =>
      SchedulerBinding.instance.addPostFrameCallback((_) => notifyListeners());
}
