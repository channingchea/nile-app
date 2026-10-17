import 'dart:async';

import 'package:flutter/material.dart';

import '../services/studio_graphics.dart';
import '../theme.dart';

/// Draws pushed Studio graphics over a video (Studio master host, phase 5).
///
/// Sized off the video area, not the screen, so a lower third reads the same on
/// a phone, a Studio thumbnail and a full-screen TV-sized window. Each position
/// fades on its own: swapping a lower third cross-fades, a slate fades over the
/// picture (audio carries on underneath — it is only drawn over the video).
///
/// Used by the viewer, the Studio monitor, the operator phone's preview and the
/// Studio Preview demo. Viewers can't hide it.
class NileGraphicsLayer extends StatelessWidget {
  const NileGraphicsLayer({super.key, required this.graphics});

  final List<LiveGraphic> graphics;

  static const _fade = Duration(milliseconds: 280);

  @override
  Widget build(BuildContext context) {
    if (graphics.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, box) {
          // One "unit" is 1% of the video's width; everything scales off it.
          final u = box.maxWidth / 100;
          LiveGraphic? at(String key) =>
              graphics.where((g) => g.capKey == key).lastOrNull;

          Widget slot(String key, Widget Function(LiveGraphic g) build) {
            final g = at(key);
            return AnimatedSwitcher(
              duration: _fade,
              child: g == null
                  ? const SizedBox.shrink(key: ValueKey('none'))
                  : KeyedSubtree(key: ValueKey(g.id), child: build(g)),
            );
          }

          final banner = at(GraphicKind.banner.wire);
          final bannerHeight = banner == null ? 0.0 : u * 6;
          return Stack(
            fit: StackFit.expand,
            children: [
              for (final corner in logoCorners)
                Positioned(
                  left: corner.endsWith('l') ? u * 3 : null,
                  right: corner.endsWith('r') ? u * 3 : null,
                  top: corner.startsWith('t') ? u * 3 : null,
                  bottom: corner.startsWith('b') ? u * 3 + bannerHeight : null,
                  child: slot('logo:$corner', (g) => _Logo(g: g, u: u)),
                ),
              Positioned(
                left: u * 4,
                bottom: u * 4 + bannerHeight,
                child: slot(
                  GraphicKind.lowerThird.wire,
                  (g) => _LowerThird(g: g, u: u),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: slot(
                  GraphicKind.banner.wire,
                  (g) => _Banner(g: g, u: u, height: u * 6),
                ),
              ),
              Positioned.fill(
                child: slot(GraphicKind.slate.wire, (g) => _Slate(g: g, u: u)),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LowerThird extends StatelessWidget {
  const _LowerThird({required this.g, required this.u});
  final LiveGraphic g;
  final double u;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(maxWidth: u * 60),
    child: Container(
      decoration: BoxDecoration(
        color: NileColors.bgSurface.withValues(alpha: 0.92),
        border: Border(left: BorderSide(color: NileColors.volt, width: u * 0.8)),
      ),
      padding: EdgeInsets.symmetric(horizontal: u * 2, vertical: u * 1.2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            g.title ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: NileTextStyles.headingMd().copyWith(
              fontSize: u * 3.2,
              color: NileColors.txtPrimary,
              height: 1.15,
            ),
          ),
          if ((g.subtitle ?? '').isNotEmpty)
            Text(
              g.subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NileTextStyles.bodyMd().copyWith(
                fontSize: u * 2.1,
                color: NileColors.txtSecondary,
                height: 1.2,
              ),
            ),
        ],
      ),
    ),
  );
}

class _Logo extends StatelessWidget {
  const _Logo({required this.g, required this.u});
  final LiveGraphic g;
  final double u;

  @override
  Widget build(BuildContext context) {
    final side = u * switch (g.size) {
      's' => 8.0,
      'l' => 18.0,
      _ => 12.0,
    };
    final url = g.imageUrl;
    if (url == null) return const SizedBox.shrink();
    return SizedBox(
      width: side,
      height: side,
      child: Image.network(
        url,
        fit: BoxFit.contain,
        alignment: Alignment.center,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.g, required this.u, required this.height});
  final LiveGraphic g;
  final double u;
  final double height;

  @override
  Widget build(BuildContext context) {
    final style = NileTextStyles.labelLg().copyWith(
      fontSize: u * 2.4,
      color: NileColors.onVolt,
    );
    final text = g.text ?? '';
    return Container(
      height: height,
      color: NileColors.volt.withValues(alpha: 0.95),
      alignment: Alignment.centerLeft,
      padding: EdgeInsets.symmetric(horizontal: g.scrolling ? 0 : u * 3),
      child: g.scrolling
          ? _Marquee(text: text, style: style, gap: u * 12)
          : Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
    );
  }
}

/// A ticker: the text slides right-to-left forever, at a steady speed
/// whatever its length.
class _Marquee extends StatefulWidget {
  const _Marquee({required this.text, required this.style, required this.gap});
  final String text;
  final TextStyle style;
  final double gap;

  @override
  State<_Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<_Marquee> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final run = painter.width + widget.gap;
    // ~ one screen-percent of travel every 60 ms, whatever the size.
    final ms = (run / (widget.style.fontSize ?? 14) * 400).round().clamp(2000, 60000);
    if (_c.duration?.inMilliseconds != ms) {
      _c.duration = Duration(milliseconds: ms);
      _c.repeat();
    }
    return ClipRect(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => OverflowBox(
          alignment: Alignment.centerLeft,
          maxWidth: double.infinity,
          child: Transform.translate(
            offset: Offset(-run * _c.value, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 3; i++) ...[
                  Text(widget.text, maxLines: 1, style: widget.style),
                  SizedBox(width: widget.gap),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Slate extends StatefulWidget {
  const _Slate({required this.g, required this.u});
  final LiveGraphic g;
  final double u;

  @override
  State<_Slate> createState() => _SlateState();
}

class _SlateState extends State<_Slate> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    if (widget.g.endsAt != null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  String? get _countdown {
    final end = widget.g.endsAt;
    if (end == null) return null;
    final left = Duration(
      milliseconds: (end - DateTime.now().millisecondsSinceEpoch).clamp(0, 86400000),
    );
    final m = left.inMinutes;
    final s = (left.inSeconds % 60).toString().padLeft(2, '0');
    return left.inHours > 0
        ? '${left.inHours}:${(m % 60).toString().padLeft(2, '0')}:$s'
        : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.u;
    final g = widget.g;
    final countdown = _countdown;
    return Container(
      color: NileColors.bgPage,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (g.imageUrl != null)
            Opacity(
              opacity: 0.35,
              child: Image.network(
                g.imageUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          Center(
            child: Padding(
              padding: EdgeInsets.all(u * 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    g.title ?? '',
                    textAlign: TextAlign.center,
                    style: NileTextStyles.headingLg().copyWith(
                      fontSize: u * 6,
                      color: NileColors.txtPrimary,
                    ),
                  ),
                  if (countdown != null) ...[
                    SizedBox(height: u * 2),
                    Text(
                      countdown,
                      style: NileTextStyles.headingLg().copyWith(
                        fontSize: u * 9,
                        color: NileColors.volt,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                  if ((g.subtitle ?? '').isNotEmpty) ...[
                    SizedBox(height: u * 2),
                    Text(
                      g.subtitle!,
                      textAlign: TextAlign.center,
                      style: NileTextStyles.bodyLg().copyWith(
                        fontSize: u * 2.6,
                        color: NileColors.txtSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
