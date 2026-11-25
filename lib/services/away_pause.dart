import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

/// Pause-on-leave (docs/plans/cost-controls-and-60-payout.md, phase 4): a
/// viewer who isn't looking isn't sent video.
///
/// `paused` is a phone leaving the app; `hidden` is a Mac window minimised or
/// a web tab in the background. `inactive` is not away — that is a click on
/// another Mac window with Nile still in view, or a phone's control centre.
bool isAwayState(AppLifecycleState state) =>
    state == AppLifecycleState.hidden || state == AppLifecycleState.paused;

/// Calls [onAway] once when the app goes away and [onBack] once when it is in
/// view again (`resumed`, or `inactive` for a Mac window that is visible but
/// not focused).
class AwayWatcher with WidgetsBindingObserver {
  AwayWatcher({required this.onAway, required this.onBack}) {
    WidgetsBinding.instance.addObserver(this);
  }

  final VoidCallback onAway;
  final VoidCallback onBack;

  bool get away => _away;
  bool _away = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) return;
    final away = isAwayState(state);
    if (away == _away) return;
    _away = away;
    away ? onAway() : onBack();
  }

  void dispose() => WidgetsBinding.instance.removeObserver(this);
}

/// Pauses the video players it is given while the app is away and restarts
/// the ones it paused on return. For recordings and films; the live room has
/// its own handling in viewer_screen.
class AwayPause {
  AwayPause(this._players, {this.onChange}) {
    _watcher = AwayWatcher(onAway: _pause, onBack: _play);
  }

  final Iterable<VideoPlayerController?> Function() _players;

  /// After players were paused or restarted, to redraw a play button.
  final VoidCallback? onChange;

  late final AwayWatcher _watcher;
  final _paused = <VideoPlayerController>{};

  void _pause() {
    for (final c in _players()) {
      if (c != null && c.value.isPlaying) {
        c.pause();
        _paused.add(c);
      }
    }
    if (_paused.isNotEmpty) onChange?.call();
  }

  void _play() {
    if (_paused.isEmpty) return;
    // Only what is still on screen: a player disposed meanwhile is gone.
    final current = _players().toSet();
    for (final c in _paused) {
      if (current.contains(c)) c.play();
    }
    _paused.clear();
    onChange?.call();
  }

  void dispose() => _watcher.dispose();
}
