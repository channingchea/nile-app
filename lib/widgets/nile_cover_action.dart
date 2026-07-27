import 'package:flutter/material.dart';

/// Circular scrim disc for controls that float over cover art or video, where
/// the backdrop is arbitrary imagery and no theme surface applies. Keeps a
/// white icon legible on a light or busy cover.
class NileCoverAction extends StatelessWidget {
  const NileCoverAction({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: 0.35),
    shape: const CircleBorder(),
    child: child,
  );
}

/// Back control for screens that render media to the top edge instead of an
/// app bar. Renders nothing when there is nothing to pop — Profile is both a
/// root tab (no back) and a pushed route (back), and this is what tells them
/// apart without threading a flag through 14 call sites.
class NileCoverBackButton extends StatelessWidget {
  const NileCoverBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Navigator.canPop(context)) return const SizedBox.shrink();
    final isIOS = Theme.of(context).platform == TargetPlatform.iOS;
    return NileCoverAction(
      child: IconButton(
        icon: Icon(
          isIOS ? Icons.arrow_back_ios_new : Icons.arrow_back,
          color: Colors.white,
        ),
        tooltip: 'Back',
        onPressed: () => Navigator.maybePop(context),
      ),
    );
  }
}
