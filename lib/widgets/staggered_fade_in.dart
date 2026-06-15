import 'package:flutter/material.dart';

import '../theme.dart';

/// Fade-up entrance for list items. Staggers by [index]; items past
/// [_maxStagger] render immediately so deep scrolls never feel laggy.
class NileStaggeredFadeIn extends StatefulWidget {
  final int index;
  final Widget child;
  const NileStaggeredFadeIn({super.key, required this.index, required this.child});

  static const int _maxStagger = 8;

  @override
  State<NileStaggeredFadeIn> createState() => _NileStaggeredFadeInState();
}

class _NileStaggeredFadeInState extends State<NileStaggeredFadeIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    final skip = widget.index >= NileStaggeredFadeIn._maxStagger;
    _controller = AnimationController(
      vsync: this,
      duration: NileMotion.base,
      value: skip ? 1 : 0,
    );
    _anim = CurvedAnimation(parent: _controller, curve: NileMotion.curve);
    if (!skip) {
      Future.delayed(Duration(milliseconds: 40 * widget.index), () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _anim,
    builder: (_, child) => Opacity(
      opacity: _anim.value,
      child: Transform.translate(
        offset: Offset(0, 12 * (1 - _anim.value)),
        child: child,
      ),
    ),
    child: widget.child,
  );
}
