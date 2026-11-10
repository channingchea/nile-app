import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../services/event_service.dart';
import '../services/livekit_service.dart';
import '../services/mini_player.dart';
import '../services/premiere.dart' show FilmRefused;
import '../services/premiere_service.dart';
import '../services/studio_mode.dart';
import '../services/overlay_clock.dart';
import '../services/replay_timeline.dart';
import '../theme.dart';
import '../widgets/replay_grid_overlay.dart';

/// Plays the replay (VOD) for an ended event. The signed playback URL is minted
/// server-side behind the same paid-ticket gate as the live stream, so
/// navigation here is only offered when a replay is known to be available to
/// this user (see event detail).
///
/// Shows recorded with the grid recorder (studio live elements, phase 6) play
/// the grid of on-air cameras and element angles with the graphics and
/// elements drawn over each tile; older shows play the combined recording.
class ReplayScreen extends StatefulWidget {
  final Event event;
  const ReplayScreen({super.key, required this.event});

  @override
  State<ReplayScreen> createState() => _ReplayScreenState();
}

class _ReplayScreenState extends State<ReplayScreen> {
  /// Overlay timelines by event, so a replay coming back from the dock keeps
  /// its graphics without another fetch.
  static final _timelines = <String, ReplayTimeline>{};

  VideoPlayerController? _controller;
  ReplayTimeline? _timeline;
  String? _error;
  bool _controlsVisible = true;

  /// There is only a dock to shrink into at desktop widths, so on phones the
  /// screen keeps its original behaviour: leaving stops playback.
  bool _canDock = false;

  // Premiere: Intro (recording) · Film (Stream) · Q&A (recording).
  ({int start, int? end, bool filmReady})? _chapters;
  _Chapter _chapter = _Chapter.intro;
  VideoPlayerController? _film;
  String? _filmError;

  @override
  void initState() {
    super.initState();
    // Arriving from the dock: the controller is already initialised and mid-
    // playback. Reusing it skips a second signed-URL round-trip and picks up
    // exactly where the mini player was.
    final docked = MiniPlayer.instance.reclaim(widget.event.id);
    if (docked != null) {
      _controller = docked;
      _timeline = _timelines[widget.event.id];
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
    // The grid replay when this show has one with overlays to draw; the
    // combined recording otherwise.
    final grid = await LivekitService.replayGrid(eventId: slug);
    final timeline = grid == null ? null : ReplayTimeline.fromMarks(grid.marks);
    final url = timeline != null && !timeline.isEmpty
        ? grid!.url
        : (await LivekitService.replayUrl(eventId: slug))?.url;
    if (!mounted) return;
    if (url == null) {
      setState(() => _error = 'This replay is no longer available.');
      return;
    }
    if (url == grid?.url && timeline != null) {
      _timeline = _timelines[widget.event.id] = timeline;
    } else {
      _timelines.remove(widget.event.id);
    }
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
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
    if (widget.event.studioMode == StudioMode.premiere) {
      unawaited(_loadChapters());
    }
  }

  // ── Premiere chapters ──────────────────────────────────────────────────────

  int? get _startWall => _timeline?.startWall;

  /// Recording offsets (ms) where the film began and where the Q&A begins.
  int? get _introEnd {
    final c = _chapters, w = _startWall;
    return c == null || w == null ? null : c.start - w;
  }

  int? get _qaStart {
    final c = _chapters, w = _startWall;
    return c?.end == null || w == null ? null : c!.end! - w;
  }

  Future<void> _loadChapters() async {
    try {
      final c = await PremiereService.replayChapters(widget.event.id);
      if (!mounted || c == null) return;
      setState(() => _chapters = c);
      _controller?.addListener(_onRecordingTick);
    } catch (_) {}
  }

  /// Intro runs into the film by itself.
  void _onRecordingTick() {
    final c = _controller, end = _introEnd;
    if (c == null || end == null || _chapter != _Chapter.intro) return;
    if (c.value.isPlaying && c.value.position.inMilliseconds >= end) {
      unawaited(_openChapter(_Chapter.film));
    }
  }

  void _onFilmTick() {
    final f = _film;
    if (f == null || _chapter != _Chapter.film) return;
    final v = f.value;
    if (v.isInitialized &&
        !v.isPlaying &&
        v.position >= v.duration &&
        v.duration > Duration.zero) {
      unawaited(_openChapter(_Chapter.qa));
    }
  }

  Future<void> _openChapter(_Chapter ch) async {
    setState(() => _chapter = ch);
    if (ch == _Chapter.film) {
      _controller?.pause();
      if (_film == null && _filmError == null) {
        try {
          final p = await PremiereService.playback(widget.event.id);
          final f = VideoPlayerController.networkUrl(p.url);
          await f.initialize();
          if (!mounted) {
            await f.dispose();
            return;
          }
          f.addListener(_onFilmTick);
          setState(() => _film = f);
        } on FilmRefused catch (e) {
          if (mounted) setState(() => _filmError = e.message);
        } catch (_) {
          if (mounted) setState(() => _filmError = "Couldn't load the film.");
        }
      }
      if (_chapter == _Chapter.film) await _film?.play();
      return;
    }
    await _film?.pause();
    final c = _controller;
    if (c == null) return;
    final at = ch == _Chapter.qa ? (_qaStart ?? 0) : 0;
    await c.seekTo(Duration(milliseconds: at < 0 ? 0 : at));
    await c.play();
  }

  Widget _chapterBar() {
    final c = _chapters!;
    Widget chip(String label, _Chapter ch, {bool enabled = true}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s4),
      child: ChoiceChip(
        label: Text(label),
        selected: _chapter == ch,
        onSelected: enabled ? (_) => _openChapter(ch) : null,
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(NileSpacing.s8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          chip('Intro', _Chapter.intro, enabled: _introEnd != null),
          chip('Film', _Chapter.film, enabled: c.filmReady),
          chip('Q&A', _Chapter.qa, enabled: _qaStart != null),
        ],
      ),
    );
  }

  Widget _filmView() {
    final f = _film;
    if (_filmError != null) {
      return Padding(
        padding: const EdgeInsets.all(NileSpacing.s24),
        child: Text(
          _filmError!,
          textAlign: TextAlign.center,
          style: NileTextStyles.bodyMd(),
        ),
      );
    }
    if (f == null) return CircularProgressIndicator(color: NileColors.volt);
    return GestureDetector(
      onTap: () => setState(() => _controlsVisible = !_controlsVisible),
      child: AspectRatio(
        aspectRatio: f.value.aspectRatio == 0 ? 16 / 9 : f.value.aspectRatio,
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(f),
            if (_controlsVisible)
              _Controls(
                controller: f,
                onPlayPause: () {
                  f.value.isPlaying ? f.pause() : f.play();
                  setState(() {});
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _film?.dispose();
    _controller?.removeListener(_onRecordingTick);
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
        child: _chapters == null
            ? Center(child: _buildContent())
            : Column(
                children: [
                  _chapterBar(),
                  Expanded(
                    child: Center(
                      child: _chapter == _Chapter.film
                          ? _filmView()
                          : _buildContent(),
                    ),
                  ),
                ],
              ),
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
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: NileTextStyles.bodyMd(),
            ),
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
            if (_timeline case final timeline?)
              Positioned.fill(child: _overlay(c, timeline)),
            if (_controlsVisible)
              _Controls(controller: c, onPlayPause: _togglePlay),
          ],
        ),
      ),
    );
  }
}

/// The grid replay's graphics and elements at the current position. Clocks and
/// countdowns read the recording's own moment, not today's.
Widget _overlay(VideoPlayerController c, ReplayTimeline timeline) =>
    ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: c,
      builder: (context, v, _) {
        final overlay = ReplayGridOverlay(
          frame: timeline.frameAt(v.position.inMilliseconds),
        );
        return timeline.startWall == null
            ? overlay
            : OverlayClock(
                now: () => timeline.wallAt(c.value.position.inMilliseconds)!,
                child: overlay,
              );
      },
    );

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
            tooltip: controller.value.isPlaying ? 'Pause' : 'Play',
            iconSize: 64,
            color: Colors.white,
            icon: Icon(
              controller.value.isPlaying
                  ? Icons.pause_circle_filled
                  : Icons.play_circle_fill,
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

enum _Chapter { intro, film, qa }
