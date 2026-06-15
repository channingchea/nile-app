import 'package:flutter/material.dart';

import '../theme.dart';

/// Animated counter for live-updating numbers (likes, viewers, prices).
/// New digits roll in vertically; tabular figures keep the width stable.
class NileRollingNumber extends StatefulWidget {
  final int value;
  final TextStyle style;
  const NileRollingNumber({super.key, required this.value, required this.style});

  @override
  State<NileRollingNumber> createState() => _NileRollingNumberState();
}

class _NileRollingNumberState extends State<NileRollingNumber> {
  late int _previous = widget.value;

  @override
  void didUpdateWidget(NileRollingNumber old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _previous = old.value;
  }

  @override
  Widget build(BuildContext context) {
    final up = widget.value >= _previous;
    return AnimatedSwitcher(
      duration: NileMotion.base,
      switchInCurve: NileMotion.curve,
      switchOutCurve: NileMotion.curve,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: Offset(0, up ? 0.6 : -0.6),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: Text(
        '${widget.value}',
        key: ValueKey(widget.value),
        style: widget.style.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
