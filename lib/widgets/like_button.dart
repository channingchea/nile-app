import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import 'rolling_number.dart';

/// Heart icon + count with a scale "pop" and light haptic on tap.
class LikeButton extends StatefulWidget {
  final bool liked;
  final int count;
  final VoidCallback? onTap;
  final double iconSize;

  const LikeButton({
    super.key,
    required this.liked,
    required this.count,
    required this.onTap,
    this.iconSize = 18,
  });

  @override
  State<LikeButton> createState() => _LikeButtonState();
}

class _LikeButtonState extends State<LikeButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: NileMotion.fast,
    lowerBound: 1.0,
    upperBound: 1.35,
  );

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  void _handleTap() {
    HapticFeedback.lightImpact();
    _pop.forward().then((_) {
      if (mounted) _pop.reverse();
    });
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.liked ? NileColors.coral : NileColors.txtSecondary;
    return InkWell(
      onTap: widget.onTap == null ? null : _handleTap,
      borderRadius: BorderRadius.circular(NileRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s4, vertical: NileSpacing.s4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ScaleTransition(
              scale: _pop,
              child: Icon(
                widget.liked ? Icons.favorite : Icons.favorite_border,
                size: widget.iconSize,
                color: color,
              ),
            ),
            const SizedBox(width: NileSpacing.s4),
            NileRollingNumber(
              value: widget.count,
              style: NileTextStyles.bodySm().copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
