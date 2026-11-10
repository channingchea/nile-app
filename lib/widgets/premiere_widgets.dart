import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/analytics.dart';
import '../services/film_sync.dart';
import '../services/premiere.dart';
import '../services/premiere_service.dart';
import '../theme.dart';
import 'film_sync_player.dart';

/// Premiere's viewer side (docs/plans/studio-modes.md, phases 7-8): the film
/// stage with its slates, the trailer, and the closing slate.

/// The film full size, with the host in a corner when the Studio puts them
/// there, the rating card as the film starts, and the intermission / hold
/// slates over it.
class PremiereFilmStage extends StatefulWidget {
  const PremiereFilmStage({
    super.key,
    required this.eventId,
    required this.film,
    required this.now,
    this.host,
    this.muted = false,
    this.demo,
    this.protect = true,
    this.onPlayback,
  });

  final String eventId;
  final FilmState film;
  final int Function() now;

  /// The stream's details once they arrive (chat rule, rating prompt).
  final ValueChanged<FilmPlayback>? onPlayback;

  /// The host's camera (the stage), shown picture-in-picture when the film
  /// state asks for it.
  final Widget? host;
  final bool muted;
  final Widget Function(int positionMs)? demo;
  final bool protect;

  @override
  State<PremiereFilmStage> createState() => _PremiereFilmStageState();
}

class _PremiereFilmStageState extends State<PremiereFilmStage> {
  FilmPlayback? _playback;
  FilmRefused? _refused;
  String? _captions;
  bool _ratingShown = false;
  bool _ratingUp = false;
  Timer? _ratingTimer;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Slates count down; redraw once a second while one is up.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      final p = widget.film.nowAt(widget.now()).phase;
      if (mounted && p == FilmPhase.intermission) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _ratingTimer?.cancel();
    super.dispose();
  }

  void _onPlayback(FilmPlayback p) {
    if (_playback == null && widget.demo == null) {
      final late = widget.film.nowAt(widget.now()).pos > 2 * 60 * 1000;
      unawaited(NileAnalytics.capture(NileEvent.filmWatched, {'late': late}));
    }
    setState(() => _playback = p);
    widget.onPlayback?.call(p);
    // The rating card, once, as the film starts (not on a late join deep in).
    final n = widget.film.nowAt(widget.now());
    if (!_ratingShown && p.rating != null && n.pos < 2 * 60 * 1000) {
      _ratingShown = true;
      setState(() => _ratingUp = true);
      _ratingTimer = Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() => _ratingUp = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.film;
    final n = f.nowAt(widget.now());
    final captions = _playback?.captions ?? const <FilmCaptionTrack>[];
    return LayoutBuilder(
      builder: (context, box) {
        final pipW = math.min(box.maxWidth * 0.28, 320.0);
        return Stack(
          fit: StackFit.expand,
          children: [
            FilmSyncPlayer(
              eventId: widget.eventId,
              film: f,
              now: widget.now,
              muted: widget.muted,
              captionsLang: _captions,
              protect: widget.protect,
              onPlayback: _onPlayback,
              onRefused: (e) => setState(() => _refused = e),
              demo: widget.demo,
            ),
            if (widget.host != null && f.pip != PipCorner.off)
              Positioned(
                left: f.pip == PipCorner.tl || f.pip == PipCorner.bl
                    ? 12
                    : null,
                right: f.pip == PipCorner.tr || f.pip == PipCorner.br
                    ? 12
                    : null,
                top: f.pip == PipCorner.tl || f.pip == PipCorner.tr ? 12 : null,
                bottom: f.pip == PipCorner.bl || f.pip == PipCorner.br
                    ? 12
                    : null,
                width: pipW,
                height: pipW * 9 / 16,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(NileRadius.md),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: NileColors.border),
                    ),
                    child: widget.host,
                  ),
                ),
              ),
            if (n.phase == FilmPhase.intermission)
              FilmSlate(
                title: 'Intermission',
                body: f.until == null
                    ? 'Back soon'
                    : 'Back in ${formatCountdown(f.until! - widget.now())}',
              )
            else if (n.phase == FilmPhase.hold)
              FilmSlate(title: 'Please stand by', body: f.message),
            if (_refused?.age == true || _ratingUp)
              Center(
                child: FilmRatingCard(
                  rating: _refused?.rating ?? _playback?.rating,
                  warning: _playback?.contentWarning,
                  refusal: _refused?.age == true ? _refused!.message : null,
                ),
              ),
            if (captions.isNotEmpty)
              Positioned(
                right: 8,
                bottom: 8,
                child: _CaptionsButton(
                  tracks: captions,
                  selected: _captions,
                  onSelected: (l) => setState(() => _captions = l),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CaptionsButton extends StatelessWidget {
  const _CaptionsButton({
    required this.tracks,
    required this.selected,
    required this.onSelected,
  });

  final List<FilmCaptionTrack> tracks;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Captions',
    color: NileColors.bgSurface,
    onSelected: (v) => onSelected(v.isEmpty ? null : v),
    itemBuilder: (_) => [
      CheckedPopupMenuItem(
        value: '',
        checked: selected == null,
        child: const Text('Off'),
      ),
      for (final t in tracks)
        CheckedPopupMenuItem(
          value: t.lang,
          checked: selected == t.lang,
          child: Text(t.label),
        ),
    ],
    child: Container(
      padding: const EdgeInsets.all(NileSpacing.s8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
      child: Icon(
        selected == null
            ? Icons.closed_caption_off_outlined
            : Icons.closed_caption,
        color: Colors.white,
      ),
    ),
  );
}

/// A full-frame slate over the film (intermission, hold).
class FilmSlate extends StatelessWidget {
  const FilmSlate({super.key, required this.title, this.body});

  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black.withValues(alpha: 0.82),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(NileSpacing.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: NileTextStyles.headingLg().copyWith(color: Colors.white),
            ),
            if (body != null && body!.isNotEmpty) ...[
              const SizedBox(height: NileSpacing.s8),
              Text(
                body!,
                textAlign: TextAlign.center,
                style: NileTextStyles.bodyLg().copyWith(color: Colors.white70),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// The rating card shown as the film starts. With [refusal] it explains why
/// an 18+ film won't play.
class FilmRatingCard extends StatelessWidget {
  const FilmRatingCard({super.key, this.rating, this.warning, this.refusal});

  final FilmRating? rating;
  final String? warning;
  final String? refusal;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(maxWidth: 420),
    margin: const EdgeInsets.all(NileSpacing.s16),
    padding: const EdgeInsets.all(NileSpacing.s24),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(NileRadius.lg),
      border: Border.all(color: Colors.white24),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (rating != null)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: NileSpacing.s12,
              vertical: NileSpacing.s4,
            ),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 2),
              borderRadius: BorderRadius.circular(NileRadius.sm),
            ),
            child: Text(
              rating == FilmRating.nr ? 'NOT RATED' : 'RATED ${rating!.wire}',
              style: NileTextStyles.headingSm().copyWith(color: Colors.white),
            ),
          ),
        if (warning != null && warning!.isNotEmpty) ...[
          const SizedBox(height: NileSpacing.s12),
          Text(
            warning!,
            textAlign: TextAlign.center,
            style: NileTextStyles.bodyMd().copyWith(color: Colors.white),
          ),
        ],
        if (refusal != null) ...[
          const SizedBox(height: NileSpacing.s12),
          Text(
            refusal!,
            textAlign: TextAlign.center,
            style: NileTextStyles.bodyMd().copyWith(color: Colors.white),
          ),
          const SizedBox(height: NileSpacing.s4),
          Text(
            'Chat and the host’s camera are still open to you.',
            textAlign: TextAlign.center,
            style: NileTextStyles.bodySm().copyWith(color: Colors.white70),
          ),
        ],
      ],
    ),
  );
}

/// The trailer: muted autoplay on a loop, tap for sound, the poster while it
/// loads (or when there's no trailer). Plays for anyone signed in, ticket or
/// not. Falls back to [fallback] when there's neither.
class PremiereTrailer extends StatefulWidget {
  const PremiereTrailer({
    super.key,
    required this.eventId,
    this.fallback,
    this.fit = BoxFit.cover,
    this.showSoundHint = true,
  });

  final String eventId;
  final Widget? fallback;
  final BoxFit fit;
  final bool showSoundHint;

  @override
  State<PremiereTrailer> createState() => _PremiereTrailerState();
}

class _PremiereTrailerState extends State<PremiereTrailer> {
  VideoPlayerController? _c;
  String? _poster;
  bool _loaded = false;
  bool _sound = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final t = await PremiereService.trailer(widget.eventId);
      if (!mounted) return;
      setState(() {
        _poster = t.posterUrl;
        _loaded = true;
      });
      final url = t.url;
      if (url == null) return;
      final c = VideoPlayerController.networkUrl(url);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      await c.setLooping(true);
      await c.setVolume(0);
      await c.play();
      setState(() => _c = c);
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  void _toggleSound() {
    final c = _c;
    if (c == null) return;
    setState(() => _sound = !_sound);
    c.setVolume(_sound ? 1 : 0);
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final poster = _poster;
    final Widget still = poster != null
        ? ColoredBox(
            color: Colors.black,
            child: Image.network(
              poster,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) =>
                  widget.fallback ?? const SizedBox.shrink(),
            ),
          )
        : widget.fallback ?? ColoredBox(color: NileColors.bgSurface);
    if (c == null) return _loaded ? still : (widget.fallback ?? still);
    return GestureDetector(
      onTap: _toggleSound,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: Colors.black,
            child: FittedBox(
              fit: widget.fit,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: c.value.size.width,
                height: c.value.size.height,
                child: VideoPlayer(c),
              ),
            ),
          ),
          if (widget.showSoundHint)
            Positioned(
              left: 12,
              bottom: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: NileSpacing.s12,
                  vertical: NileSpacing.s4,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(NileRadius.pill),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _sound ? Icons.volume_up : Icons.volume_off,
                      size: 16,
                      color: Colors.white,
                    ),
                    const SizedBox(width: NileSpacing.s4),
                    Text(
                      _sound ? 'Trailer' : 'Tap for sound',
                      style: NileTextStyles.labelSm().copyWith(
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Thanks for watching", as the film ends: tip the filmmaker, open their
/// profile, and (when they asked) rate the film.
class PremiereClosingSlate extends StatefulWidget {
  const PremiereClosingSlate({
    super.key,
    required this.eventId,
    required this.hostName,
    required this.askRating,
    required this.onClose,
    this.onTip,
    this.onProfile,
  });

  final String eventId;
  final String hostName;
  final bool askRating;
  final VoidCallback onClose;
  final VoidCallback? onTip;
  final VoidCallback? onProfile;

  @override
  State<PremiereClosingSlate> createState() => _PremiereClosingSlateState();
}

class _PremiereClosingSlateState extends State<PremiereClosingSlate> {
  int _stars = 0;
  bool _sent = false;

  Future<void> _rate(int s) async {
    setState(() => _stars = s);
    try {
      await PremiereService.rateFilm(widget.eventId, s);
      unawaited(NileAnalytics.capture(NileEvent.filmRated, {'stars': s}));
      if (mounted) setState(() => _sent = true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      constraints: const BoxConstraints(maxWidth: 420),
      margin: const EdgeInsets.all(NileSpacing.s16),
      padding: const EdgeInsets.all(NileSpacing.s24),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.lg),
        border: Border.all(color: NileColors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: Alignment.topRight,
            child: IconButton(
              tooltip: 'Close',
              onPressed: widget.onClose,
              icon: const Icon(Icons.close),
            ),
          ),
          Text('Thanks for watching', style: NileTextStyles.headingMd()),
          const SizedBox(height: NileSpacing.s8),
          Text(
            'The Q&A with ${widget.hostName} starts now.',
            textAlign: TextAlign.center,
            style: NileTextStyles.bodyMd().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
          if (widget.askRating) ...[
            const SizedBox(height: NileSpacing.s16),
            Text(
              _sent ? 'Thanks for rating' : 'Rate the film',
              style: NileTextStyles.labelMd(),
            ),
            const SizedBox(height: NileSpacing.s4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 1; i <= 5; i++)
                  IconButton(
                    tooltip: '$i star${i == 1 ? '' : 's'}',
                    onPressed: () => _rate(i),
                    icon: Icon(
                      i <= _stars ? Icons.star : Icons.star_border,
                      color: NileColors.volt,
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: NileSpacing.s16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.onTip != null)
                FilledButton.icon(
                  onPressed: widget.onTip,
                  icon: const Icon(Icons.favorite_outline, size: 18),
                  label: const Text('Tip'),
                ),
              if (widget.onTip != null && widget.onProfile != null)
                const SizedBox(width: NileSpacing.s8),
              if (widget.onProfile != null)
                OutlinedButton(
                  onPressed: widget.onProfile,
                  child: Text('@${widget.hostName}'),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// Studio Setup's stand-in film: a slow colour drift with a timecode, so the
/// transport has something to move without a real upload.
class DemoFilmPicture extends StatelessWidget {
  const DemoFilmPicture({
    super.key,
    required this.positionMs,
    required this.durationMs,
  });

  final int positionMs;
  final int durationMs;

  @override
  Widget build(BuildContext context) {
    final t = durationMs == 0 ? 0.0 : positionMs / durationMs;
    final hue = (t * 300) % 360;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HSVColor.fromAHSV(1, hue, 0.55, 0.35).toColor(),
            HSVColor.fromAHSV(1, (hue + 60) % 360, 0.6, 0.15).toColor(),
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.movie_outlined,
              size: 48,
              color: Colors.white.withValues(alpha: 0.8),
            ),
            const SizedBox(height: NileSpacing.s8),
            Text(
              'Demo film',
              style: NileTextStyles.headingSm().copyWith(color: Colors.white),
            ),
            const SizedBox(height: NileSpacing.s4),
            Text(
              '${formatFilmLength(Duration(milliseconds: positionMs))} / '
              '${formatFilmLength(Duration(milliseconds: durationMs))}',
              style: NileTextStyles.bodyMd().copyWith(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}
