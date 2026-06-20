import 'package:flutter/material.dart';
import '../services/event_service.dart';
import '../theme.dart';
import 'live_badge.dart';

/// Status pill shown top-left on an event cover.
/// LIVE → animated coral [LiveBadge]; scheduled → volt date·time pill;
/// ended/draft → muted dark pill. Returns null when nothing should show.
class EventCoverPill extends StatelessWidget {
  final Event event;
  const EventCoverPill({super.key, required this.event});

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// "Fri · 9:00 PM" for a same-week date, else "Jun 21 · 9:00 PM".
  static String _label(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    final time = '$h:$m $ampm';
    final now = DateTime.now();
    final days = dt.difference(DateTime(now.year, now.month, now.day)).inDays;
    if (days >= 0 && days < 7) {
      const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return '${wd[dt.weekday - 1]} · $time';
    }
    return '${_months[dt.month - 1]} ${dt.day} · $time';
  }

  @override
  Widget build(BuildContext context) {
    if (event.isLive) return const LiveBadge();

    late final Color bg, fg;
    late final String text;
    if (event.isScheduled && event.scheduledAt != null) {
      bg = NileColors.volt;
      fg = NileColors.bgPage;
      text = _label(event.scheduledAt!.toLocal());
    } else if (event.isDraft) {
      bg = NileColors.bgPage.withValues(alpha: 0.6);
      fg = NileColors.txtSecondary;
      text = 'DRAFT';
    } else if (event.isEnded) {
      bg = NileColors.bgPage.withValues(alpha: 0.6);
      fg = Colors.white;
      text = 'ENDED';
    } else {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: NileSpacing.s8,
        vertical: NileSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(NileRadius.pill),
      ),
      child: Text(
        text,
        style: NileTextStyles.labelSm().copyWith(
          color: fg,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// Diagonal gradient placeholder for events without a cover photo.
/// Picks a stable hue from the event id so each event gets a consistent look.
class EventCoverPlaceholder extends StatelessWidget {
  final String seed;
  const EventCoverPlaceholder({super.key, required this.seed});

  static const _pairs = <List<Color>>[
    [Color(0xFFFF4D6D), Color(0xFF8B5CF6)], // coral → violet
    [Color(0xFF00B4FF), Color(0xFF1E3A8A)], // azure → deep blue
    [Color(0xFFFFB800), Color(0xFFFF6B35)], // amber → orange
    [Color(0xFF8B5CF6), Color(0xFF00B4FF)], // violet → azure
  ];

  @override
  Widget build(BuildContext context) {
    final colors = _pairs[seed.hashCode.abs() % _pairs.length];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
    );
  }
}
