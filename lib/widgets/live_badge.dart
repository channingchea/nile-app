import 'package:flutter/material.dart';
import '../theme.dart';

/// Coral LIVE badge with a breathing dot.
class LiveBadge extends StatefulWidget {
  final String label;
  const LiveBadge({super.key, this.label = 'LIVE'});

  @override
  State<LiveBadge> createState() => _LiveBadgeState();
}

class _LiveBadgeState extends State<LiveBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulse = Tween<double>(
      begin: 0.35,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s8, vertical: NileSpacing.s4),
      decoration: BoxDecoration(
        color: NileColors.coral,
        borderRadius: BorderRadius.circular(NileRadius.xs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (_, _) => Opacity(
              opacity: _pulse.value,
              child: const CircleAvatar(
                radius: 3.5,
                backgroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 5),
          Text(
            widget.label,
            style: NileTextStyles.caption().copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}
