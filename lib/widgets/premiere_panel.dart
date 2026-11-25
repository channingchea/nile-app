import 'dart:async';

import 'package:flutter/material.dart';

import '../services/film_sync.dart';
import '../services/premiere.dart' show formatFilmLength;
import '../theme.dart';

/// One transport press. [action] is a livekit `film-control` verb.
typedef FilmControl =
    Future<void> Function(
      String action, {
      int? positionMs,
      int? seconds,
      String? message,
      bool? on,
      String? corner,
      int? percent,
    });

/// The Studio's Premiere panel (docs/plans/studio-modes.md, phase 7): Play,
/// Pause, Intermission, Hold, End, a scrubber with time remaining, and the
/// Commentary and picture-in-picture switches. Used by the real Studio and by
/// Studio Setup's rehearsal (with a local [onControl]).
class PremierePanel extends StatefulWidget {
  const PremierePanel({
    super.key,
    required this.film,
    required this.now,
    required this.onControl,
    required this.canPlay,
    this.playHint,
    this.listening = false,
    this.onListen,
  });

  final FilmState film;
  final int Function() now;
  final FilmControl onControl;

  /// The show is live and the film is ready.
  final bool canPlay;

  /// Why Play is off, e.g. "Start the show first".
  final String? playHint;

  /// The host hears the film in their monitor.
  final bool listening;
  final ValueChanged<bool>? onListen;

  @override
  State<PremierePanel> createState() => _PremierePanelState();
}

class _PremierePanelState extends State<PremierePanel> {
  Timer? _tick;
  bool _busy = false;
  double? _scrub;

  /// The film-under-commentary slider while it's being dragged.
  double? _duck;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => mounted && _scrub == null ? setState(() {}) : null,
    );
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _go(
    String action, {
    int? positionMs,
    int? seconds,
    String? message,
    bool? on,
    String? corner,
    int? percent,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onControl(
        action,
        positionMs: positionMs,
        seconds: seconds,
        message: message,
        on: on,
        corner: corner,
        percent: percent,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _intermission() async {
    final mins = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text('Intermission', style: NileTextStyles.headingSm()),
        children: [
          for (final m in const [5, 10, 15, 20])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, m),
              child: Text('$m minutes'),
            ),
        ],
      ),
    );
    if (mins != null) await _go('intermission', seconds: mins * 60);
  }

  Future<void> _hold() async {
    final text = TextEditingController();
    final msg = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text('Hold the film', style: NileTextStyles.headingSm()),
        content: TextField(
          controller: text,
          maxLength: 140,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Message for viewers (optional)',
            hintText: 'e.g. Fixing a sound problem, back in a moment',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, text.text),
            child: const Text('Hold'),
          ),
        ],
      ),
    );
    text.dispose();
    if (msg != null) await _go('hold', message: msg);
  }

  Future<void> _end() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text('End the film now?', style: NileTextStyles.headingSm()),
        content: Text(
          'Everyone moves to the Q&A. The film ends by itself when the '
          'credits finish, so you only need this to stop early.',
          style: NileTextStyles.bodyMd().copyWith(
            color: NileColors.txtSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep playing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End film'),
          ),
        ],
      ),
    );
    if (ok == true) await _go('end');
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.film;
    final n = f.nowAt(widget.now());
    final dur = f.dur;
    final pos = _scrub?.round() ?? n.pos;
    final label = NileTextStyles.labelSm().copyWith(
      color: NileColors.txtTertiary,
      letterSpacing: 1.2,
    );
    final status = switch (n.phase) {
      FilmPhase.pre => 'PRE-SHOW',
      FilmPhase.playing => 'FILM PLAYING',
      FilmPhase.paused => 'PAUSED',
      FilmPhase.intermission =>
        'INTERMISSION ${f.until == null ? '' : formatCountdown(f.until! - widget.now())}',
      FilmPhase.hold => 'HOLDING',
      FilmPhase.ended => 'Q&A',
    };
    final transport = <Widget>[
      if (n.phase == FilmPhase.pre || n.phase == FilmPhase.ended)
        Tooltip(
          message: widget.canPlay ? '' : (widget.playHint ?? ''),
          child: FilledButton.icon(
            onPressed: widget.canPlay && !_busy ? () => _go('play') : null,
            icon: const Icon(Icons.play_arrow),
            label: Text(
              n.phase == FilmPhase.ended ? 'Play again' : 'Play film',
            ),
          ),
        )
      else ...[
        n.moving
            ? FilledButton.icon(
                onPressed: _busy ? null : () => _go('pause'),
                icon: const Icon(Icons.pause),
                label: const Text('Pause'),
              )
            : FilledButton.icon(
                onPressed: _busy ? null : () => _go('resume'),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Resume'),
              ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _intermission,
          icon: const Icon(Icons.local_cafe_outlined, size: 18),
          label: const Text('Intermission'),
        ),
        OutlinedButton.icon(
          onPressed: _busy || n.phase == FilmPhase.hold ? null : _hold,
          icon: const Icon(Icons.front_hand_outlined, size: 18),
          label: const Text('Hold'),
        ),
        TextButton(
          onPressed: _busy ? null : _end,
          child: const Text('End film'),
        ),
      ],
      if (n.phase == FilmPhase.ended)
        TextButton(
          onPressed: _busy ? null : () => _go('reset'),
          child: const Text('Back to pre-show'),
        ),
    ];
    return Container(
      padding: const EdgeInsets.all(NileSpacing.s12),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        border: Border(top: BorderSide(color: NileColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text('PREMIERE', style: label),
              const SizedBox(width: NileSpacing.s8),
              Text(
                status,
                style: NileTextStyles.labelSm().copyWith(
                  color: n.moving ? NileColors.volt : NileColors.txtSecondary,
                ),
              ),
              const Spacer(),
              if (dur > 0)
                Text(
                  '${formatFilmLength(Duration(milliseconds: pos))} / '
                  '${formatFilmLength(Duration(milliseconds: dur))}'
                  '  ·  ${formatFilmLength(Duration(milliseconds: dur - pos))} left',
                  style: NileTextStyles.caption().copyWith(
                    color: NileColors.txtSecondary,
                  ),
                ),
            ],
          ),
          if (dur > 0)
            Slider(
              value: pos.clamp(0, dur).toDouble(),
              max: dur.toDouble(),
              onChanged: n.showingFilm && !_busy
                  ? (v) => setState(() => _scrub = v)
                  : null,
              onChangeEnd: n.showingFilm
                  ? (v) async {
                      await _go('seek', positionMs: v.round());
                      if (mounted) setState(() => _scrub = null);
                    }
                  : null,
            ),
          Wrap(
            spacing: NileSpacing.s8,
            runSpacing: NileSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ...transport,
              const SizedBox(width: NileSpacing.s8),
              FilterChip(
                label: const Text('Commentary'),
                tooltip:
                    'Your mic on over the film, which drops for viewers to '
                    'the level you set',
                selected: f.commentary,
                onSelected: _busy ? null : (v) => _go('commentary', on: v),
              ),
              PopupMenuButton<PipCorner>(
                tooltip: 'Your camera in a corner of the film',
                color: NileColors.bgSurface,
                onSelected: (c) => _go('pip', corner: c.name),
                itemBuilder: (_) => [
                  for (final c in PipCorner.values)
                    CheckedPopupMenuItem(
                      value: c,
                      checked: f.pip == c,
                      child: Text(c.label),
                    ),
                ],
                child: Chip(
                  avatar: const Icon(
                    Icons.picture_in_picture_alt_outlined,
                    size: 18,
                  ),
                  label: Text(
                    f.pip == PipCorner.off
                        ? 'Picture in picture'
                        : 'PiP: ${f.pip.label}',
                  ),
                ),
              ),
              if (widget.onListen != null)
                FilterChip(
                  label: const Text('Hear the film'),
                  tooltip:
                      'Plays the film’s sound on this device. Use headphones, or '
                      'your mic picks it up.',
                  selected: widget.listening,
                  onSelected: widget.onListen,
                ),
            ],
          ),
          if (f.commentary)
            Row(
              children: [
                Icon(
                  Icons.volume_down,
                  size: 18,
                  color: NileColors.txtSecondary,
                ),
                const SizedBox(width: NileSpacing.s8),
                Text(
                  'Film under your voice',
                  style: NileTextStyles.labelSm().copyWith(
                    color: NileColors.txtSecondary,
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: _duck ?? f.duck.toDouble(),
                    max: 100,
                    divisions: 20,
                    label: '${(_duck ?? f.duck).round()}%',
                    onChanged: _busy ? null : (v) => setState(() => _duck = v),
                    onChangeEnd: (v) async {
                      await _go('duck', percent: v.round());
                      if (mounted) setState(() => _duck = null);
                    },
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text(
                    '${(_duck ?? f.duck).round()}%',
                    textAlign: TextAlign.end,
                    style: NileTextStyles.labelSm().copyWith(
                      color: NileColors.txtSecondary,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
