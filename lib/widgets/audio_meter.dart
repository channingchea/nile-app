import 'dart:async';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import '../theme.dart';

/// Vertical VU/peak meter for a [LocalParticipant]'s audio.
///
/// Driven by the participant's `audioLevel` (normalized 0–1 loudness, exposed on
/// Participant rather than the track), polled on a ticker. Shows a green→amber→
/// red scale with a peak-hold marker and a clip indicator that latches when the
/// signal nears full-scale — the operator's cue to lower gain at the soundboard,
/// since true clipping happens at the hardware ADC and can't be undone in
/// software.
class AudioMeter extends StatefulWidget {
  final Participant participant;
  final double height;

  const AudioMeter({super.key, required this.participant, this.height = 220});

  @override
  State<AudioMeter> createState() => _AudioMeterState();
}

class _AudioMeterState extends State<AudioMeter> {
  static const _clipThreshold = 0.92; // fraction of full-scale that latches clip
  static const _peakDecay = 0.04; // how fast the peak-hold marker falls per tick

  Timer? _timer;
  double _level = 0; // smoothed current level (0–1)
  double _peak = 0; // peak-hold marker (0–1)
  bool _clipping = false;
  DateTime? _clipAt;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 80), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _tick() {
    final raw = widget.participant.audioLevel.clamp(0.0, 1.0);
    // light smoothing for the bar, instant for clip detection
    final smoothed = _level + (raw - _level) * 0.5;
    var peak = (_peak - _peakDecay).clamp(0.0, 1.0);
    if (raw > peak) peak = raw;

    var clipping = _clipping;
    if (raw >= _clipThreshold) {
      clipping = true;
      _clipAt = DateTime.now();
    } else if (_clipAt != null &&
        DateTime.now().difference(_clipAt!) > const Duration(milliseconds: 1500)) {
      clipping = false; // hold the warning ~1.5s after the last over
    }

    if (!mounted) return;
    setState(() {
      _level = smoothed;
      _peak = peak;
      _clipping = clipping;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 56,
          height: widget.height,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: NileColors.bgPage,
            borderRadius: BorderRadius.circular(NileRadius.sm),
            border: Border.all(color: NileColors.border),
          ),
          child: CustomPaint(
            painter: _MeterPainter(level: _level, peak: _peak),
            size: Size.infinite,
          ),
        ),
        const SizedBox(height: 12),
        AnimatedOpacity(
          opacity: _clipping ? 1 : 0.25,
          duration: const Duration(milliseconds: 120),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _clipping ? NileColors.coral : Colors.transparent,
              borderRadius: BorderRadius.circular(NileRadius.sm),
              border: Border.all(color: NileColors.coral),
            ),
            child: Text(
              'CLIP',
              style: NileTextStyles.labelMd().copyWith(
                color: _clipping ? Colors.white : NileColors.coral,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MeterPainter extends CustomPainter {
  final double level;
  final double peak;
  _MeterPainter({required this.level, required this.peak});

  @override
  void paint(Canvas canvas, Size size) {
    final r = const Radius.circular(3);
    // background track
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, r),
      Paint()..color = NileColors.bgSurface,
    );

    final fillH = size.height * level;
    final top = size.height - fillH;

    // color zones by level: green < 0.7, amber < 0.9, coral above
    Color barColor;
    if (level >= 0.9) {
      barColor = NileColors.coral;
    } else if (level >= 0.7) {
      barColor = NileColors.amber;
    } else {
      barColor = NileColors.volt;
    }

    if (fillH > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(0, top, size.width, size.height),
          r,
        ),
        Paint()..color = barColor,
      );
    }

    // peak-hold marker
    final peakY = size.height - size.height * peak;
    canvas.drawRect(
      Rect.fromLTRB(0, peakY - 1, size.width, peakY + 1),
      Paint()..color = Colors.white.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(_MeterPainter old) =>
      old.level != level || old.peak != peak;
}
