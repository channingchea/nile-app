import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/event_service.dart';
import '../services/livekit_service.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
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
    _controller?.dispose();
    super.dispose();
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
      ),
      body: NileMaxWidth(child: Center(child: _buildContent())),
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
