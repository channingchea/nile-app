import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:qr_flutter/qr_flutter.dart';

import '../services/brand_kit.dart';
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
///
/// Auto-hide: a graphic past its `hideAt` stops drawing on the dot (and fades
/// out), even before the Studio takes it out of the room metadata.
///
/// Each graphic draws in its attached brand kit ([LiveGraphic.brand]) or, with
/// none, in Nile's own style.
///
/// Nothing here takes a touch except, when [onTapLink] is set, a QR code with
/// a link (viewers on a phone tap it instead of scanning their own screen).
class NileGraphicsLayer extends StatefulWidget {
  const NileGraphicsLayer({super.key, required this.graphics, this.onTapLink});

  final List<LiveGraphic> graphics;

  /// Called with a tapped [LiveGraphic.tappable] graphic. Null = nothing is
  /// tappable (Studio, operator phones).
  final ValueChanged<LiveGraphic>? onTapLink;

  static const fade = Duration(milliseconds: 250);

  @override
  State<NileGraphicsLayer> createState() => _NileGraphicsLayerState();
}

class _NileGraphicsLayerState extends State<NileGraphicsLayer> {
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void didUpdateWidget(NileGraphicsLayer old) {
    super.didUpdateWidget(old);
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  /// Rebuild when the next graphic's auto-hide comes due.
  void _scheduleHide() {
    _hideTimer?.cancel();
    final now = DateTime.now().millisecondsSinceEpoch;
    final next = widget.graphics
        .map((g) => g.hideAt)
        .whereType<int>()
        .where((h) => h > now)
        .fold<int?>(null, (a, b) => a == null || b < a ? b : a);
    if (next == null) return;
    _hideTimer = Timer(Duration(milliseconds: next - now + 20), () {
      if (mounted) setState(_scheduleHide);
    });
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final graphics = [
      for (final g in widget.graphics)
        if (!g.expiredAt(now)) g,
    ];
    const fade = NileGraphicsLayer.fade;
    final onTapLink = widget.onTapLink;
    // Never short-circuit to nothing: the last graphic has to be able to fade
    // out, which needs its AnimatedSwitcher still in the tree.
    return LayoutBuilder(
      builder: (context, box) {
        // One "unit" is 1% of the video's width; everything scales off it.
        final u = box.maxWidth / 100;
        LiveGraphic? at(String key) =>
            graphics.where((g) => g.capKey == key).lastOrNull;

        // A slate covers everything under it, so nothing under it takes taps.
        final slateUp = at(GraphicKind.slate.wire) != null;
        VoidCallback? tapFor(LiveGraphic g) =>
            onTapLink != null && g.tappable && !slateUp ? () => onTapLink(g) : null;

        // Every slot ignores the pointer unless it holds a tappable graphic,
        // so touches fall through to the video controls underneath.
        Widget slot(String key, Widget Function(LiveGraphic g) build) {
          final g = at(key);
          return IgnorePointer(
            ignoring: g == null || tapFor(g) == null,
            child: AnimatedSwitcher(
              duration: fade,
              child: g == null
                  ? const SizedBox.shrink(key: ValueKey('none'))
                  : KeyedSubtree(key: ValueKey(g.id), child: build(g)),
            ),
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
                child: _corner(corner, u, slot, tapFor),
              ),
            Positioned(
              left: u * 4,
              bottom: u * 4 + bannerHeight,
              child: slot(
                GraphicKind.lowerThird.wire,
                (g) => _LowerThird(g: g, u: u),
              ),
            ),
            // A chat card sits above where a lower third goes, so the two
            // can be up together.
            Positioned(
              left: u * 4,
              bottom: u * 4 + bannerHeight + u * 11,
              child: slot(GraphicKind.chat.wire, (g) => _ChatCard(g: g, u: u)),
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
    );
  }

  /// One corner: the logo (or sponsor) hugging the corner, and a QR code
  /// beside it on the screen-centre side. The logo carries the gap on its
  /// inward edge, so it sits exactly in the corner whether or not a QR is up.
  Widget _corner(
    String corner,
    double u,
    Widget Function(String key, Widget Function(LiveGraphic g) build) slot,
    VoidCallback? Function(LiveGraphic g) tapFor,
  ) {
    final left = corner.endsWith('l');
    final logo = slot(
      'logo:$corner',
      (g) => Padding(
        padding: left
            ? EdgeInsets.only(right: u * 1.5)
            : EdgeInsets.only(left: u * 1.5),
        child: g.kind == GraphicKind.sponsor && g.imageUrl == null
            ? _SponsorBadge(g: g, u: u)
            : _Logo(g: g, u: u),
      ),
    );
    final qr = slot('qr:$corner', (g) => _Qr(g: g, u: u, onTap: tapFor(g)));
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: corner.startsWith('t')
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.end,
      children: left ? [logo, qr] : [qr, logo],
    );
  }
}

/// A graphic's colours and fonts: its brand kit's, or Nile's own when it has
/// none (then everything resolves to exactly the Nile tokens).
class _Look {
  const _Look(this.brand);
  factory _Look.of(LiveGraphic g) => _Look(g.brand);

  final BrandStyle? brand;

  /// Replaces volt: lower-third stripe, banner fill, countdown numbers.
  Color get accent => brand?.accentColor ?? NileColors.volt;

  /// Card backgrounds (lower third, chat card, QR frame, sponsor badge).
  Color get panel => brand?.panelColor ?? NileColors.bgSurface;

  /// Full-screen slate background.
  Color get page => brand?.panelColor ?? NileColors.bgPage;
  Color get text => brand?.textColor ?? NileColors.txtPrimary;
  Color get textDim =>
      brand?.textColor.withValues(alpha: 0.7) ?? NileColors.txtSecondary;

  /// Text on the accent colour (the banner).
  Color get onAccent => brand?.onAccentColor ?? NileColors.onVolt;

  /// [s] in the kit's font, sizes and weights kept. Only fonts on the
  /// [brandFonts] list are fetched; anything else keeps the Nile font.
  TextStyle font(TextStyle s) {
    final f = brand?.font;
    return f == null || !brandFonts.contains(f)
        ? s
        : GoogleFonts.getFont(f, textStyle: s);
  }
}

class _LowerThird extends StatelessWidget {
  const _LowerThird({required this.g, required this.u});
  final LiveGraphic g;
  final double u;

  @override
  Widget build(BuildContext context) {
    final look = _Look.of(g);
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
    final look = _Look.of(g);
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
    final look = _Look.of(g);
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
    final look = _Look.of(g);
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
    final look = _Look.of(g);
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
    final look = _Look.of(g);
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
