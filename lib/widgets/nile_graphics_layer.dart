import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:qr_flutter/qr_flutter.dart';

import '../services/live_elements.dart';
import '../services/overlay_layout.dart';
import '../services/studio_graphics.dart';
import '../theme.dart';
import 'elements/element_kinds.dart';
import 'overlay_look.dart';

/// Draws what the Studio puts over a video: graphics and live elements, each
/// in its spot on the 3×3 grid (or full screen) and in its camera's layer
/// order ([placeOverlay]). Studio master host phase 5; one overlay for
/// graphics and elements since studio live elements phase 2.
///
/// Measured against the 16:9 picture inside the box ([videoFrame]), not the
/// screen, so a lower third reads the same on a phone upright or sideways, a
/// Studio thumbnail and a TV-sized window. Each item fades on its own: swapping
/// a lower third cross-fades, a slate fades over the picture (audio carries on
/// underneath — it is only drawn over the video).
///
/// Used by the viewer, the Studio monitor and tiles, the operator phone's
/// preview and Studio Preview. Viewers can't hide it.
///
/// Auto-hide: a graphic past its `hideAt` stops drawing on the dot (and fades
/// out), even before the Studio takes it out of the room metadata.
///
/// Nothing here takes a touch except, when [onTapLink] is set, a QR code with
/// a link (viewers on a phone tap it instead of scanning their own screen) —
/// and never one under a full-screen item.
class NileGraphicsLayer extends StatefulWidget {
  const NileGraphicsLayer({
    super.key,
    required this.graphics,
    this.elements = const [],
    this.layers = const [],
    this.onTapLink,
  });

  final List<LiveGraphic> graphics;
  final List<LiveElement> elements;

  /// This camera's layer list ([OverlayLayout.layersFor]); empty = every item
  /// in its default spot.
  final List<LayerEntry> layers;

  /// Called with a tapped [LiveGraphic.tappable] graphic. Null = nothing is
  /// tappable (Studio, operator phones).
  final ValueChanged<LiveGraphic>? onTapLink;

  static const fade = Duration(milliseconds: 250);

  @override
  State<NileGraphicsLayer> createState() => _NileGraphicsLayerState();
}

/// A channel that just went away, kept while it fades out.
typedef _Gone = ({PlacedItem last, int until});

class _NileGraphicsLayerState extends State<NileGraphicsLayer> {
  Timer? _hideTimer;
  Timer? _purgeTimer;
  List<PlacedItem> _placed = const [];
  final Map<String, _Gone> _gone = {};

  @override
  void initState() {
    super.initState();
    _recompute();
  }

  @override
  void didUpdateWidget(NileGraphicsLayer old) {
    super.didUpdateWidget(old);
    _recompute();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _purgeTimer?.cancel();
    super.dispose();
  }

  /// Place everything still up, and remember what just left so its fade-out
  /// has somewhere to happen.
  void _recompute() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final placed = placeOverlay(
      graphics: [
        for (final g in widget.graphics)
          if (!g.expiredAt(now)) g,
      ],
      elements: widget.elements,
      layers: widget.layers,
    );
    final current = {for (final p in placed) p.channel};
    for (final p in _placed) {
      if (!current.contains(p.channel)) {
        _gone[p.channel] = (
          last: p,
          until: now + NileGraphicsLayer.fade.inMilliseconds + 50,
        );
      }
    }
    _gone.removeWhere((k, g) => current.contains(k) || g.until <= now);
    _placed = placed;
    _schedulePurge(now);
    _scheduleHide(now);
  }

  void _schedulePurge(int now) {
    _purgeTimer?.cancel();
    if (_gone.isEmpty) return;
    final next = _gone.values.map((g) => g.until).reduce((a, b) => a < b ? a : b);
    _purgeTimer = Timer(Duration(milliseconds: next - now + 10), () {
      if (mounted) setState(_recompute);
    });
  }

  /// Rebuild when the next graphic's auto-hide comes due.
  void _scheduleHide(int now) {
    _hideTimer?.cancel();
    final next = widget.graphics
        .map((g) => g.hideAt)
        .whereType<int>()
        .where((h) => h > now)
        .fold<int?>(null, (a, b) => a == null || b < a ? b : a);
    if (next == null) return;
    _hideTimer = Timer(Duration(milliseconds: next - now + 20), () {
      if (mounted) setState(_recompute);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Everything on screen plus what is fading out, as (channel, placement,
    // item-or-null).
    final channels = <({String key, PlacedItem at, PlacedItem? item})>[
      for (final p in _placed) (key: p.channel, at: p, item: p),
      for (final e in _gone.entries) (key: e.key, at: e.value.last, item: null),
    ];
    final onTapLink = widget.onTapLink;
    final fullZ = _placed.where((p) => p.isFull).map((p) => p.z);
    final topFull = fullZ.isEmpty ? null : fullZ.reduce((a, b) => a > b ? a : b);

    return LayoutBuilder(
      builder: (context, box) {
        final frame = videoFrame(box.biggest);
        // One "unit" is 1% of the picture's width; everything scales off it.
        final u = frame.width / 100;
        final margin = u * 3;
        final bannerH = u * 6;

        VoidCallback? tapFor(PlacedItem p) {
          final g = p.graphic;
          if (onTapLink == null || g == null || !g.tappable) return null;
          // Under a full-screen item nothing takes taps.
          if (topFull != null && topFull > p.z) return null;
          return () => onTapLink(g);
        }

        Widget channel(({String key, PlacedItem at, PlacedItem? item}) c) {
          final item = c.item;
          return IgnorePointer(
            key: ValueKey(c.key),
            ignoring: item == null || tapFor(item) == null,
            child: AnimatedSwitcher(
              duration: NileGraphicsLayer.fade,
              child: item == null
                  ? const SizedBox.shrink(key: ValueKey('none'))
                  : KeyedSubtree(
                      key: ValueKey(item.id),
                      child: _draw(item, u, tapFor(item), bannerH),
                    ),
            ),
          );
        }

        // A banner is a full-width row; bottom (or top) spots sit clear of it.
        bool bannerAt(LayoutSpot s) =>
            _placed.any((p) => p.isBanner && p.spot == s);
        final topInset = bannerAt(LayoutSpot.tc) ? bannerH : 0.0;
        final bottomInset = bannerAt(LayoutSpot.bc) ? bannerH : 0.0;

        final layers = <({int z, Widget child})>[];
        final bySpot = <LayoutSpot, List<({String key, PlacedItem at, PlacedItem? item})>>{};
        for (final c in channels) {
          final at = c.at;
          if (at.isFull) {
            layers.add((
              z: at.z,
              child: Positioned.fill(key: ValueKey('at:${c.key}'), child: channel(c)),
            ));
          } else if (at.isBanner) {
            layers.add((
              z: at.z,
              child: Positioned(
                key: ValueKey('at:${c.key}'),
                left: 0,
                right: 0,
                top: switch (at.spot) {
                  LayoutSpot.tc => 0.0,
                  LayoutSpot.mc => (frame.height - bannerH) / 2,
                  _ => null,
                },
                bottom: at.spot == LayoutSpot.bc ? 0.0 : null,
                child: channel(c),
              ),
            ));
          } else {
            bySpot.putIfAbsent(at.spot, () => []).add(c);
          }
        }
        bySpot.forEach((spot, list) {
          layers.add((
            z: list.map((c) => c.at.z).reduce((a, b) => a > b ? a : b),
            child: Positioned.fill(
              key: ValueKey('spot:${spot.wire}'),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  margin,
                  margin + topInset,
                  margin,
                  margin + bottomInset,
                ),
                child: Align(
                  alignment: spot.alignment,
                  child: _spot(spot, list, channel, u),
                ),
              ),
            ),
          ));
        });
        layers.sort((a, b) => a.z.compareTo(b.z));

        // Never short-circuit to nothing: the last item has to be able to fade
        // out, which needs its AnimatedSwitcher still in the tree.
        return Stack(
          children: [
            Positioned.fromRect(
              rect: frame,
              child: Stack(
                fit: StackFit.expand,
                children: [for (final l in layers) l.child],
              ),
            ),
          ],
        );
      },
    );
  }

  /// One grid spot: corner bugs (logos, sponsor, QR) side by side at the edge,
  /// then lower third, chat card and elements stacking inward from it.
  Widget _spot(
    LayoutSpot spot,
    List<({String key, PlacedItem at, PlacedItem? item})> list,
    Widget Function(({String key, PlacedItem at, PlacedItem? item})) channel,
    double u,
  ) {
    int rank(PlacedItem p) => switch (p.graphic?.kind) {
      GraphicKind.lowerThird => 0,
      GraphicKind.chat => 1,
      null => 2,
      _ => 3,
    };
    final compact = list.where((c) => c.at.isCompact).toList()
      ..sort((a, b) {
        // The logo hugs the corner; a QR code sits on the screen-centre side.
        final qa = a.at.graphic?.kind == GraphicKind.qr ? 1 : 0;
        final qb = b.at.graphic?.kind == GraphicKind.qr ? 1 : 0;
        return spot.isRight ? qb - qa : qa - qb;
      });
    final rest = list.where((c) => !c.at.isCompact).toList()
      ..sort((a, b) {
        final r = rank(a.at) - rank(b.at);
        return r != 0 ? r : b.at.z - a.at.z;
      });
    final gap = u * 1.5;
    final cross = spot.isLeft
        ? CrossAxisAlignment.start
        : spot.isRight
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.center;
    final children = <Widget>[
      if (compact.isNotEmpty)
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: spot.isTop
              ? CrossAxisAlignment.start
              : spot.isBottom
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.center,
          children: [
            for (var i = 0; i < compact.length; i++) ...[
              if (i > 0) SizedBox(width: gap),
              channel(compact[i]),
            ],
          ],
        ),
      for (final c in rest) channel(c),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: cross,
      verticalDirection: spot.isBottom
          ? VerticalDirection.up
          : VerticalDirection.down,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          children[i],
        ],
      ],
    );
  }

  Widget _draw(PlacedItem p, double u, VoidCallback? onTap, double bannerH) {
    final e = p.element;
    if (e != null) return buildElement(e, u, full: p.isFull);
    final g = p.graphic!;
    return switch (g.kind) {
      GraphicKind.lowerThird => _LowerThird(g: g, u: u),
      GraphicKind.chat => _ChatCard(g: g, u: u),
      GraphicKind.logo => _Logo(g: g, u: u),
      GraphicKind.sponsor =>
        g.imageUrl == null ? _SponsorBadge(g: g, u: u) : _Logo(g: g, u: u),
      GraphicKind.qr => _Qr(g: g, u: u, onTap: onTap),
      GraphicKind.banner => _Banner(g: g, u: u, height: bannerH),
      GraphicKind.slate => _Slate(g: g, u: u),
    };
  }
}

/// A graphic's look: its attached brand kit, or Nile's own.
OverlayLook _lookOf(LiveGraphic g) => OverlayLook(g.brand);

class _LowerThird extends StatelessWidget {
  const _LowerThird({required this.g, required this.u});
  final LiveGraphic g;
  final double u;

  @override
  Widget build(BuildContext context) {
    final look = _lookOf(g);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: u * 60),
      child: Container(
        decoration: BoxDecoration(
          color: look.panel.withValues(alpha: 0.92),
          border: Border(left: BorderSide(color: look.accent, width: u * 0.8)),
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
              style: look.font(
                NileTextStyles.headingMd().copyWith(
                  fontSize: u * 3.2,
                  color: look.text,
                  height: 1.15,
                ),
              ),
            ),
            if ((g.subtitle ?? '').isNotEmpty)
              Text(
                g.subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: look.font(
                  NileTextStyles.bodyMd().copyWith(
                    fontSize: u * 2.1,
                    color: look.textDim,
                    height: 1.2,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChatCard extends StatelessWidget {
  const _ChatCard({required this.g, required this.u});
  final LiveGraphic g;
  final double u;

  @override
  Widget build(BuildContext context) {
    final look = _lookOf(g);
    final name = g.title ?? '';
    final avatar = g.avatarUrl;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: u * 55),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: u * 1.6, vertical: u * 1.2),
        decoration: BoxDecoration(
          color: look.panel.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(u * 1.4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: u * 2,
              backgroundColor: nileChatNameColor(name),
              foregroundImage: avatar == null ? null : NetworkImage(avatar),
              child: Text(
                name.isEmpty ? '?' : name[0].toUpperCase(),
                style: look.font(
                  NileTextStyles.labelSm().copyWith(
                    fontSize: u * 1.8,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            SizedBox(width: u * 1.2),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '@$name',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: look.font(
                      NileTextStyles.labelLg().copyWith(
                        fontSize: u * 1.9,
                        color: nileChatNameColor(name),
                        height: 1.2,
                      ),
                    ),
                  ),
                  Text(
                    g.text ?? '',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: look.font(
                      NileTextStyles.bodyMd().copyWith(
                        fontSize: u * 2.2,
                        color: look.text,
                        height: 1.25,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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

/// A sponsor with no logo on file: "Sponsored by" over the sponsor's name.
class _SponsorBadge extends StatelessWidget {
  const _SponsorBadge({required this.g, required this.u});
  final LiveGraphic g;
  final double u;

  @override
  Widget build(BuildContext context) {
    final look = _lookOf(g);
    final scale = switch (g.size) {
      's' => 0.8,
      'l' => 1.4,
      _ => 1.0,
    };
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: u * 24 * scale),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: u * 1.4 * scale,
          vertical: u * 0.9 * scale,
        ),
        decoration: BoxDecoration(
          color: look.panel.withValues(alpha: 0.92),
          // NileRadius.sm as it reads on a 600 px-wide video (u = 6).
          borderRadius: BorderRadius.circular(NileRadius.sm * u / 6 * scale),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Sponsored by',
              maxLines: 1,
              style: look.font(
                NileTextStyles.caption().copyWith(
                  fontSize: u * 1.4 * scale,
                  color: look.textDim,
                  height: 1.2,
                ),
              ),
            ),
            Text(
              g.title ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: look.font(
                NileTextStyles.labelLg().copyWith(
                  fontSize: u * 2.2 * scale,
                  color: look.text,
                  height: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A link as a QR code. The code itself is always black on white so every
/// phone camera reads it; only the frame and caption take the brand kit.
class _Qr extends StatelessWidget {
  const _Qr({required this.g, required this.u, this.onTap});
  final LiveGraphic g;
  final double u;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final url = g.url;
    if (url == null) return const SizedBox.shrink();
    final look = _lookOf(g);
    final side = u * switch (g.size) {
      's' => 9.0,
      'l' => 18.0,
      _ => 13.0,
    };
    final caption = g.caption ?? '';
    final card = Container(
      padding: EdgeInsets.all(u * 0.8),
      decoration: BoxDecoration(
        color: look.panel.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(u * 1.2),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          QrImageView(
            data: url,
            size: side,
            // The white quiet zone round the code.
            padding: EdgeInsets.all(side * 0.07),
            backgroundColor: Colors.white,
            errorCorrectionLevel: QrErrorCorrectLevel.M,
            eyeStyle: const QrEyeStyle(
              eyeShape: QrEyeShape.square,
              color: Colors.black,
            ),
            dataModuleStyle: const QrDataModuleStyle(
              dataModuleShape: QrDataModuleShape.square,
              color: Colors.black,
            ),
            semanticsLabel: caption.isEmpty ? 'QR code' : caption,
          ),
          if (caption.isNotEmpty) ...[
            SizedBox(height: u * 0.6),
            SizedBox(
              width: side,
              child: Text(
                caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: look.font(
                  NileTextStyles.bodyMd().copyWith(
                    fontSize: u * 1.6,
                    color: look.text,
                    height: 1.2,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return card;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: card,
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
    final look = _lookOf(g);
    final style = look.font(
      NileTextStyles.labelLg().copyWith(
        fontSize: u * 2.4,
        color: look.onAccent,
      ),
    );
    final text = g.text ?? '';
    return Container(
      height: height,
      color: look.accent.withValues(alpha: 0.95),
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
    final look = _lookOf(g);
    final countdown = _countdown;
    return Container(
      color: look.page,
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
                    style: look.font(
                      NileTextStyles.headingLg().copyWith(
                        fontSize: u * 6,
                        color: look.text,
                      ),
                    ),
                  ),
                  if (countdown != null) ...[
                    SizedBox(height: u * 2),
                    Text(
                      countdown,
                      style: look.font(
                        NileTextStyles.headingLg().copyWith(
                          fontSize: u * 9,
                          color: look.accent,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    // Counting to a time of day: say the time too, in this
                    // viewer's own time zone.
                    if (g.showsClock && g.endsAt != null)
                      Text(
                        'at ${DateFormat.jm().format(DateTime.fromMillisecondsSinceEpoch(g.endsAt!))}',
                        style: look.font(
                          NileTextStyles.bodyLg().copyWith(
                            fontSize: u * 2.6,
                            color: look.textDim,
                          ),
                        ),
                      ),
                  ],
                  if ((g.subtitle ?? '').isNotEmpty) ...[
                    SizedBox(height: u * 2),
                    Text(
                      g.subtitle!,
                      textAlign: TextAlign.center,
                      style: look.font(
                        NileTextStyles.bodyLg().copyWith(
                          fontSize: u * 2.6,
                          color: look.textDim,
                        ),
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
