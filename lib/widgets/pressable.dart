import 'package:flutter/material.dart';

/// Scales its child down slightly while pressed.
///
/// Uses a [Listener] (not a gesture detector) so it never competes with the
/// child's own InkWell/onTap; pointer-cancel (e.g. scroll takeover) snaps back.
class NilePressable extends StatefulWidget {
  final Widget child;
  final double pressedScale;

  const NilePressable({
    super.key,
    required this.child,
    this.pressedScale = 0.97,
  });

  @override
  State<NilePressable> createState() => _NilePressableState();
}

class _NilePressableState extends State<NilePressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _down = true),
      onPointerUp: (_) => setState(() => _down = false),
      onPointerCancel: (_) => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? widget.pressedScale : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
