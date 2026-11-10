import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

import '../services/capture_guard.dart';
import '../services/film_sync.dart';
import '../services/premiere.dart';
import '../services/premiere_service.dart';
import '../theme.dart';

/// Plays a Premiere film in step with the show clock
/// (docs/plans/studio-modes.md, phase 7).
///
/// Every second it compares the player with where [film] says the film is at
/// [now] (server ms): under 0.3 s off it leaves it, up to 1.5 s it eases back
/// with a 0.95-1.05x speed change, beyond that it seeks. A late joiner seeks
/// straight to the right place. The signed stream lasts an hour, so a fresh
/// one is fetched and swapped in a few minutes before it runs out.
///
/// [demo] replaces the stream with a stand-in (Studio Setup's rehearsal).
class FilmSyncPlayer extends StatefulWidget {
  const FilmSyncPlayer({
    super.key,
    required this.eventId,
    required this.film,
    required this.now,
    this.muted = false,
    this.captionsLang,
    this.protect = true,
    this.onPlayback,
    this.onRefused,
    this.demo,
  });

  final String eventId;
  final FilmState film;
  final int Function() now;
  final bool muted;

  /// Caption language to show, or null for none.
  final String? captionsLang;

  /// Screen-recording blackout while this player is up (viewers).
  final bool protect;
  final ValueChanged<FilmPlayback>? onPlayback;
  final ValueChanged<FilmRefused>? onRefused;
  final Widget Function(int positionMs)? demo;

  @override
  State<FilmSyncPlayer> createState() => _FilmSyncPlayerState();
}

class _FilmSyncPlayerState extends State<FilmSyncPlayer> {
  VideoPlayerController? _c;
  FilmPlayback? _playback;
  String? _error;
  Timer? _tick;
  Timer? _renew;
  DateTime _settleUntil = DateTime(0);
  String? _captionsFor;
  bool _held = false;

  @override
  void initState() {
    super.initState();
    if (widget.demo != null) {
      _tick = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => mounted ? setState(() {}) : null,
      );
      return;
    }
    if (widget.protect) {
      _held = true;
      unawaited(CaptureGuard.hold());
    }
    unawaited(_open());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _sync());
  }

  @override
  void didUpdateWidget(FilmSyncPlayer old) {
    super.didUpdateWidget(old);
    if (widget.demo != null) return;
    if (old.film != widget.film) _sync(force: true);
    if (old.muted != widget.muted ||
        old.film.commentary != widget.film.commentary ||
        old.film.duck != widget.film.duck) {
      _applyVolume(_c);
    }
    if (old.captionsLang != widget.captionsLang) unawaited(_loadCaptions());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _renew?.cancel();
    _c?.dispose();
    if (_held) unawaited(CaptureGuard.release());
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final p = await PremiereService.playback(widget.eventId);
      if (!mounted) return;
      _playback = p;
      widget.onPlayback?.call(p);
      final c = await _start(p.url);
      if (!mounted) {
        c?.dispose();
        return;
      }
      setState(() => _c = c);
      _scheduleRenew(p.expiresAt);
      unawaited(_loadCaptions());
    } on FilmRefused catch (e) {
      widget.onRefused?.call(e);
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'The film couldn’t load.');
    }
  }

  /// A ready controller already at the right place.
  Future<VideoPlayerController?> _start(Uri url) async {
    final c = VideoPlayerController.networkUrl(url);
    try {
      await c.initialize();
    } catch (_) {
      await c.dispose();
      if (mounted) setState(() => _error = 'The film couldn’t load.');
      return null;
    }
    _applyVolume(c);
    final n = widget.film.nowAt(widget.now());
    await c.seekTo(Duration(milliseconds: n.pos));
    _settleUntil = DateTime.now().add(const Duration(seconds: 2));
    if (n.moving) await c.play();
    return c;
  }

  void _scheduleRenew(DateTime expiresAt) {
    _renew?.cancel();
    final wait = expiresAt
        .subtract(const Duration(minutes: 5))
        .difference(DateTime.now());
    _renew = Timer(wait.isNegative ? Duration.zero : wait, _swapStream);
  }

  /// A fresh signed stream, swapped in once it's ready at the right place.
  Future<void> _swapStream() async {
    try {
      final p = await PremiereService.playback(widget.eventId);
      final c = await _start(p.url);
      if (!mounted || c == null) {
        c?.dispose();
        return;
      }
      final old = _c;
      _playback = p;
      setState(() => _c = c);
      _captionsFor = null;
      unawaited(_loadCaptions());
      unawaited(old?.dispose());
      _scheduleRenew(p.expiresAt);
    } on FilmRefused catch (e) {
      // The replay window closed, or access was taken away.
      widget.onRefused?.call(e);
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      // Try again in a minute; the current stream still has a few left.
      _renew = Timer(const Duration(minutes: 1), _swapStream);
    }
  }

  void _applyVolume(VideoPlayerController? c) => c?.setVolume(
    filmVolume(
      commentary: widget.film.commentary,
      muted: widget.muted,
      duck: widget.film.duck,
    ),
  );

  Future<void> _loadCaptions() async {
    final c = _c, lang = widget.captionsLang;
    if (c == null || lang == _captionsFor) return;
    _captionsFor = lang;
    final track = _playback?.captions.where((t) => t.lang == lang).firstOrNull;
    if (track == null) {
      await c.setClosedCaptionFile(null);
      return;
    }
    try {
      final res = await http.get(track.url);
      if (res.statusCode != 200 || !mounted || _c != c) return;
      await c.setClosedCaptionFile(Future.value(WebVTTCaptionFile(res.body)));
    } catch (_) {
      _captionsFor = null;
    }
  }

  void _sync({bool force = false}) {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    final n = widget.film.nowAt(widget.now());
    final at = c.value.position.inMilliseconds;
    if (!n.moving) {
      if (c.value.isPlaying) c.pause();
      if ((at - n.pos).abs() > kDriftIgnoreMs) {
        c.seekTo(Duration(milliseconds: n.pos));
      }
      return;
    }
    if (!c.value.isPlaying) c.play();
    if (!force && DateTime.now().isBefore(_settleUntil)) return;
    if (c.value.isBuffering) return;
    final step = syncStep(playerMs: at, targetMs: n.pos);
    if (step.seekTo != null) {
      c.seekTo(Duration(milliseconds: step.seekTo!));
      _settleUntil = DateTime.now().add(const Duration(seconds: 2));
    }
    if (c.value.playbackSpeed != step.rate) c.setPlaybackSpeed(step.rate);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.demo != null) {
      return widget.demo!(widget.film.nowAt(widget.now()).pos);
    }
    final c = _c;
    return ColoredBox(
      color: Colors.black,
      child: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(NileSpacing.s24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: NileTextStyles.bodyMd().copyWith(color: Colors.white),
                ),
              ),
            )
          : c == null
          ? Center(child: CircularProgressIndicator(color: NileColors.volt))
          : ValueListenableBuilder<bool>(
              valueListenable: CaptureGuard.captured,
              builder: (context, captured, _) => captured && widget.protect
                  ? const FilmCoveredSlate()
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        Center(
                          child: AspectRatio(
                            aspectRatio: c.value.aspectRatio == 0
                                ? 16 / 9
                                : c.value.aspectRatio,
                            child: VideoPlayer(c),
                          ),
                        ),
                        ValueListenableBuilder<VideoPlayerValue>(
                          valueListenable: c,
                          builder: (context, v, _) => Align(
                            alignment: const Alignment(0, 0.88),
                            child: ClosedCaption(
                              text: widget.captionsLang == null
                                  ? null
                                  : v.caption.text,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
    );
  }
}

/// What a viewer sees while their screen is being recorded.
class FilmCoveredSlate extends StatelessWidget {
  const FilmCoveredSlate({super.key});

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(NileSpacing.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.videocam_off_outlined,
              color: Colors.white,
              size: 40,
            ),
            const SizedBox(height: NileSpacing.s12),
            Text(
              'The film is hidden while your screen is being recorded or shared',
              textAlign: TextAlign.center,
              style: NileTextStyles.headingSm().copyWith(color: Colors.white),
            ),
            const SizedBox(height: NileSpacing.s8),
            Text(
              'Stop the recording or mirroring and it comes right back. '
              'Chat and the host stay on.',
              textAlign: TextAlign.center,
              style: NileTextStyles.bodySm().copyWith(color: Colors.white70),
            ),
          ],
        ),
      ),
    ),
  );
}
