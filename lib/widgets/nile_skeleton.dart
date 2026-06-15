import 'package:flutter/material.dart';
import '../theme.dart';

/// Single pulsing placeholder block. Compose inside [NileSkeletonPulse]
/// (or use [NileSkeletonList]) so the whole group breathes together.
class NileSkeleton extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;

  const NileSkeleton({
    super.key,
    this.width,
    this.height = 12,
    this.radius = NileRadius.sm,
  });

  const NileSkeleton.circle({super.key, double size = 36})
    : width = size,
      height = size,
      radius = NileRadius.pill;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: NileColors.bgRaised,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// Wraps any skeleton layout in a shared opacity pulse.
class NileSkeletonPulse extends StatefulWidget {
  final Widget child;
  const NileSkeletonPulse({super.key, required this.child});

  @override
  State<NileSkeletonPulse> createState() => _NileSkeletonPulseState();
}

class _NileSkeletonPulseState extends State<NileSkeletonPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(
        begin: 0.45,
        end: 1.0,
      ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut)),
      child: widget.child,
    );
  }
}

/// A feed-card-shaped placeholder (avatar + text lines).
class NileSkeletonCard extends StatelessWidget {
  const NileSkeletonCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(NileSpacing.s12),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.lg),
        border: Border.all(color: NileColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Row(
            children: [
              NileSkeleton.circle(),
              SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NileSkeleton(width: 120),
                  SizedBox(height: 6),
                  NileSkeleton(width: 72, height: 10),
                ],
              ),
            ],
          ),
          SizedBox(height: 14),
          NileSkeleton(width: double.infinity),
          SizedBox(height: 8),
          NileSkeleton(width: 220),
        ],
      ),
    );
  }
}

/// A pulsing column of [count] skeleton cards — drop-in replacement for a
/// full-screen spinner while a list loads.
class NileSkeletonList extends StatelessWidget {
  final int count;
  final EdgeInsetsGeometry padding;

  const NileSkeletonList({
    super.key,
    this.count = 4,
    this.padding = const EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s8, NileSpacing.s16, NileSpacing.s16),
  });

  @override
  Widget build(BuildContext context) {
    return NileSkeletonPulse(
      child: Padding(
        padding: padding,
        child: Column(
          children: [
            for (var i = 0; i < count; i++) ...[
              const NileSkeletonCard(),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }
}
