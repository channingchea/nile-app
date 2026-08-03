import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import 'rolling_number.dart';

/// Heart icon + count with a scale "pop" and light haptic on tap.
///
/// Two tap targets: the heart toggles the like, the count opens [onCountTap]
/// (the "liked by" list). When [onCountTap] is null the whole row toggles.
class LikeButton extends StatefulWidget {
  final bool liked;
  final int count;
  final VoidCallback? onTap;
  final VoidCallback? onCountTap;
  final double iconSize;

  const LikeButton({
    super.key,
    required this.liked,
    required this.count,
    required this.onTap,
    this.onCountTap,
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
    // Nothing to show when there are no likes yet.
    final countTap = widget.count > 0 ? widget.onCountTap : null;

    final heart = ScaleTransition(
      scale: _pop,
      child: Icon(
        widget.liked ? Icons.favorite : Icons.favorite_border,
        size: widget.iconSize,
        color: color,
      ),
    );
    final count = NileRollingNumber(
      value: widget.count,
      style: NileTextStyles.bodySm().copyWith(color: color),
    );

    const pad = EdgeInsets.symmetric(
      horizontal: NileSpacing.s4,
      vertical: NileSpacing.s4,
    );

    // Single target: the whole row toggles (original behaviour).
    if (countTap == null) {
      return InkWell(
        onTap: widget.onTap == null ? null : _handleTap,
        borderRadius: BorderRadius.circular(NileRadius.sm),
        child: Padding(
          padding: pad,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [heart, const SizedBox(width: NileSpacing.s4), count],
          ),
        ),
      );
    }

    // Split targets: heart toggles, count opens the "liked by" list.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: widget.onTap == null ? null : _handleTap,
          borderRadius: BorderRadius.circular(NileRadius.sm),
          child: Padding(padding: pad, child: heart),
        ),
        InkWell(
          onTap: countTap,
          borderRadius: BorderRadius.circular(NileRadius.sm),
          child: Padding(
            padding: pad,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 16),
              child: count,
            ),
          ),
        ),
      ],
    );
  }
}
