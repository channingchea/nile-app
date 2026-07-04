import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import '../theme.dart';

/// Translucent "Liquid Glass" backdrop for a top app bar, matching
/// [NileGlassNavBar]: a backdrop blur + translucent surface tint + specular
/// bottom edge. Drop it into an app bar's `flexibleSpace` so page content
/// scrolls *behind* the bar instead of triggering Material's default green
/// surface-tint on scroll.
///
/// Host setup (so there's content to blur):
///  • `AppBar` screens: set `extendBodyBehindAppBar: true` on the Scaffold.
///  • `CustomScrollView` + `SliverAppBar`: nothing extra — slivers already
///    scroll under a pinned bar.
///
/// The host app bar must also be made transparent so only this glass shows:
/// `backgroundColor: Colors.transparent`, `surfaceTintColor: Colors.transparent`,
/// `scrolledUnderElevation: 0`, `elevation: 0`. The [appBar] / [sliverAppBar]
/// factories below apply all of that for you.
class NileGlassBar extends StatelessWidget {
  const NileGlassBar({super.key});

  static const double _blurSigma = 20; // matches NileGlassNavBar
  static const double _tintAlpha = 0.62;

  /// A standard [AppBar] with the glass backdrop pre-wired.
  static AppBar appBar({
    Key? key,
    Widget? title,
    List<Widget>? actions,
    Widget? leading,
    bool centerTitle = false,
  }) {
    return AppBar(
      key: key,
      title: title,
      actions: actions,
      leading: leading,
      centerTitle: centerTitle,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      flexibleSpace: const NileGlassBar(),
    );
  }

  /// A pinned [SliverAppBar] with the glass backdrop pre-wired.
  static SliverAppBar sliverAppBar({
    Key? key,
    Widget? title,
    List<Widget>? actions,
    Widget? leading,
    bool pinned = true,
    bool floating = false,
    bool centerTitle = false,
  }) {
    return SliverAppBar(
      key: key,
      title: title,
      actions: actions,
      leading: leading,
      pinned: pinned,
      floating: floating,
      centerTitle: centerTitle,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      flexibleSpace: const NileGlassBar(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: _blurSigma, sigmaY: _blurSigma),
        child: Container(
          decoration: BoxDecoration(
            color: NileColors.bgSurface.withValues(alpha: _tintAlpha),
            // Specular rim along the bottom edge — the "lit glass" seam where
            // the bar meets the scrolling content.
            border: Border(
              bottom: BorderSide(color: NileColors.borderStrong, width: 0.5),
            ),
          ),
        ),
      ),
    );
  }
}
