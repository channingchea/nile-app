import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../services/event_service.dart';
import '../services/livekit_service.dart';
import '../services/mini_player.dart';
import '../theme.dart';

/// Plays the composited replay (VOD) for an ended event. The signed playback URL
/// is minted server-side by the `replay-url` action behind the same paid-ticket
/// gate as the live stream, so navigation here is only offered when a replay is
/// known to be available to this user (see event detail).
class ReplayScreen extends StatefulWidget {
  final Event event;
  const ReplayScreen({super.key, required this.event});

  @override
  State<ReplayScreen> createState() => _ReplayScreenState();
}

class _ReplayScreenState extends State<ReplayScreen> {
  VideoPlayerController? _controller;
  String? _error;
  bool _controlsVisible = true;

  /// There is only a dock to shrink into at desktop widths, so on phones the
  /// screen keeps its original behaviour: leaving stops playback.
  bool _canDock = false;

  @override
  void initState() {
    super.initState();
    // Arriving from the dock: the controller is already initialised and mid-
    // playback. Reusing it skips a second signed-URL round-trip and picks up
    // exactly where the mini player was.
    final docked = MiniPlayer.instance.reclaim(widget.event.id);
    if (docked != null) {
      _controller = docked;
    } else {
      _load();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Read here, not in dispose, where MediaQuery is no longer safe to touch.
    _canDock = !NileBreakpoints.of(context).isCompact;
  }

  Future<void> _load() async {
    final slug = widget.event.liveKitEventId ?? widget.event.id;
    final playback = await LivekitService.replayUrl(eventId: slug);
    if (!mounted) return;
    if (playback == null) {
      setState(() => _error = 'This replay is no longer available.');
      return;
    }
    final controller = VideoPlayerController.networkUrl(Uri.parse(playback.url));
    try {
      await controller.initialize();
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = "Couldn't load this replay.");
      return;
    }
    if (!mounted) {
      controller.dispose();
      return;
    }
    setState(() => _controller = controller);
    controller.play();
  }

  @override
  void dispose() {
    final c = _controller;
    // Already handed over by _minimise — the dock owns it and disposing here
    // would kill the audio the mini player exists to preserve.
    if (c != null && !identical(MiniPlayer.instance.controller, c)) {
      if (_canDock && c.value.isPlaying) {
        // Navigating away mid-playback shrinks into the dock instead of
        // stopping. That behaviour is the whole point of the docked player.
        _dock(c);
      } else {
        c.dispose();
      }
    }
    super.dispose();
  }

  void _dock(VideoPlayerController c) => MiniPlayer.instance.adopt(
    c,
    eventId: widget.event.id,
    title: widget.event.title,
    subtitle: '@${widget.event.hostUsername}',
  );

  void _minimise() {
    final c = _controller;
    if (c == null) return;
    _dock(c);
    context.pop();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(widget.event.title, overflow: TextOverflow.ellipsis),
        actions: [
          if (_canDock && _controller != null)
            IconButton(
              tooltip: 'Minimise',
              icon: const Icon(Icons.picture_in_picture_alt_outlined),
              onPressed: _minimise,
            ),
        ],
      ),
      // A player is one of the surfaces that breaks out of the text column —
      // capped only so the video doesn't stretch absurdly on a 32" display.
      body: NileMaxWidth(
        maxWidth: 1100,
        child: Center(child: _buildContent()),
      ),
    );
  }

  Widget _buildContent() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(NileSpacing.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: NileColors.txtSecondary, size: 40),
            const SizedBox(height: NileSpacing.s12),
            Text(_error!, textAlign: TextAlign.center, style: NileTextStyles.bodyMd()),
          ],
        ),
      );
    }
    final c = _controller;
    if (c == null) {
      return CircularProgressIndicator(color: NileColors.volt);
    }
    return GestureDetector(
      onTap: () => setState(() => _controlsVisible = !_controlsVisible),
      child: AspectRatio(
        aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(c),
            if (_controlsVisible) _Controls(controller: c, onPlayPause: _togglePlay),
          ],
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  final VideoPlayerController controller;
  final VoidCallback onPlayPause;
  const _Controls({required this.controller, required this.onPlayPause});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black26,
      child: Column(
        children: [
          const Spacer(),
          IconButton(
            iconSize: 64,
            color: Colors.white,
            icon: Icon(
              controller.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
            ),
            onPressed: onPlayPause,
          ),
          const Spacer(),
          VideoProgressIndicator(
            controller,
            allowScrubbing: true,
            padding: const EdgeInsets.all(NileSpacing.s12),
            colors: VideoProgressColors(
              playedColor: NileColors.volt,
              bufferedColor: Colors.white24,
              backgroundColor: Colors.white10,
            ),
          ),
        ],
      ),
    );
  }
}
