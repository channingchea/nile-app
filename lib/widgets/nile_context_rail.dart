import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../router.dart';
import '../services/app_lifecycle.dart';
import '../services/event_service.dart';
import '../theme.dart';
import 'live_badge.dart';

/// The persistent right-hand rail: what's on air now, and what's on next.
///
/// It exists to keep a session going — the wireframes' "this is what keeps
/// someone on the site" column. On event and stream routes Phase 7 swaps its
/// contents for chat, which is why the body is a [child] slot rather than
/// hard-wired.
class NileContextRail extends StatelessWidget {
  const NileContextRail({super.key, this.child, this.width});

  /// Overrides the default live/up-next body. Phase 7 passes chat here.
  final Widget? child;

  /// The rail is the flexible zone in the shell: both it and the nav rail are
  /// pinned to the window edges, so once the content column reaches its ceiling
  /// this is what absorbs the remaining width. Defaults to [minWidth].
  final double? width;

  /// Design width, and the narrowest the rail is ever drawn.
  static const double minWidth = 322;

  @override
  Widget build(BuildContext context) => Container(
    width: width ?? minWidth,
    decoration: BoxDecoration(
      color: NileColors.bgPage,
      border: Border(left: BorderSide(color: NileColors.border)),
    ),
    child: SafeArea(left: false, child: child ?? const _WhatsOn()),
  );
}

class _WhatsOn extends StatefulWidget {
  const _WhatsOn();

  @override
  State<_WhatsOn> createState() => _WhatsOnState();
}

class _WhatsOnState extends State<_WhatsOn> {
  List<Event>? _live;
  List<Event>? _upcoming;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    // "Live now" is only useful if it's actually now. A minute and a half is
    // frequent enough to feel current without hammering two queries.
    _poll = Timer.periodic(const Duration(seconds: 90), (_) => _load());
    AppLifecycle.instance.state.addListener(_onLifecycle);
  }

  @override
  void dispose() {
    _poll?.cancel();
    AppLifecycle.instance.state.removeListener(_onLifecycle);
    super.dispose();
  }

  /// After a sleep or a long backgrounding the rail is guaranteed stale, and
  /// the periodic timer may not have fired while suspended.
  void _onLifecycle() {
    if (AppLifecycle.instance.state.value == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    try {
      final liveFuture = EventService.getLiveNow(limit: 4);
      final upcomingFuture = EventService.getUpcoming(limit: 6);
      final live = await liveFuture;
      final upcoming = await upcomingFuture;
      if (!mounted) return;
      setState(() {
        _live = live;
        _upcoming = upcoming;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _live ??= const [];
        _upcoming ??= const [];
      });
    }
  }

  void _open(Event e) {
    final live = e.status == 'live';
    final location = NileRoutes.eventOrWatch(
      isLive: live,
      eventId: e.id,
      liveKitEventId: e.liveKitEventId,
    );
    // The viewer route takes only an id; the event page renders instantly when
    // handed the model it already has.
    context.push(location, extra: location.startsWith('/event/') ? e : null);
  }

  @override
  Widget build(BuildContext context) {
    final live = _live;
    final upcoming = _upcoming;
    final loading = live == null || upcoming == null;
    final nothing = !loading && live.isEmpty && upcoming.isEmpty;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        NileSpacing.s16,
        NileSpacing.s16,
        NileSpacing.s16,
        NileSpacing.s32,
      ),
      children: [
        if (loading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(NileSpacing.s32),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (nothing)
          const _Empty()
        else ...[
          if (live.isNotEmpty) ...[
            const _SectionHeader('Live now', accent: NileColors.coral),
            for (final e in live)
              Padding(
                padding: const EdgeInsets.only(bottom: NileSpacing.s12),
                child: _LiveCard(event: e, onTap: () => _open(e)),
              ),
            const SizedBox(height: NileSpacing.s12),
          ],
          if (upcoming.isNotEmpty) ...[
            const _SectionHeader('Up next'),
            for (final e in upcoming)
              _UpNextRow(event: e, onTap: () => _open(e)),
          ],
        ],
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label, {this.accent});
  final String label;
  final Color? accent;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: NileSpacing.s12),
    child: Row(
      children: [
        if (accent != null) ...[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: NileSpacing.s8),
        ],
        Text(
          label.toUpperCase(),
          style: NileTextStyles.labelSm().copyWith(
            color: accent ?? NileColors.txtSecondary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

/// A live show, given the space a live show deserves: 16:9 cover, LIVE badge,
/// viewer count.
class _LiveCard extends StatelessWidget {
  const _LiveCard({required this.event, required this.onTap});
  final Event event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cover = event.coverImageUrl;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NileRadius.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(NileRadius.md),
            child: Stack(
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: cover == null
                      ? Container(color: NileColors.bgRaised)
                      : Image.network(
                          cover,
                          fit: BoxFit.cover,
                          cacheWidth: nileDecodeWidth(
                            NileContextRail.minWidth - NileSpacing.s32,
                          ),
                          errorBuilder: (_, _, _) =>
                              Container(color: NileColors.bgRaised),
                        ),
                ),
                const Positioned(
                  top: NileSpacing.s8,
                  left: NileSpacing.s8,
                  child: LiveBadge(),
                ),
                if (event.viewerCount > 0)
                  Positioned(
                    bottom: NileSpacing.s8,
                    right: NileSpacing.s8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: NileSpacing.s6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0x99000000),
                        borderRadius: BorderRadius.circular(NileRadius.pill),
                      ),
                      child: Text(
                        '${event.viewerCount}',
                        style: NileTextStyles.caption()
                            .copyWith(color: const Color(0xFFFAFAFA))
                            .tabular,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: NileSpacing.s8),
          Text(
            event.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: NileTextStyles.labelMd(),
          ),
          Text(
            '@${event.hostUsername}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: NileTextStyles.caption(),
          ),
        ],
      ),
    );
  }
}

/// A scheduled show: compact enough that five of them still fit above the fold.
class _UpNextRow extends StatelessWidget {
  const _UpNextRow({required this.event, required this.onTap});
  final Event event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cover = event.coverImageUrl;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NileRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: NileSpacing.s6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(NileRadius.sm),
              child: SizedBox(
                width: 56,
                height: 56,
                child: cover == null
                    ? Container(color: NileColors.bgRaised)
                    : Image.network(
                        cover,
                        fit: BoxFit.cover,
                        cacheWidth: nileDecodeWidth(56),
                        errorBuilder: (_, _, _) =>
                            Container(color: NileColors.bgRaised),
                      ),
              ),
            ),
            const SizedBox(width: NileSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: NileTextStyles.bodyMd(),
                  ),
                  const SizedBox(height: NileSpacing.s2),
                  Text(
                    nileWhen(event.scheduledAt),
                    style: NileTextStyles.caption()
                        .copyWith(color: NileColors.volt),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: NileSpacing.s40),
    child: Column(
      children: [
        Icon(Icons.sensors_off, color: NileColors.txtTertiary, size: 28),
        const SizedBox(height: NileSpacing.s12),
        Text(
          'Nothing on air',
          style: NileTextStyles.labelMd()
              .copyWith(color: NileColors.txtSecondary),
        ),
        const SizedBox(height: NileSpacing.s4),
        Text(
          'Live shows and what’s coming up appear here.',
          textAlign: TextAlign.center,
          style: NileTextStyles.caption(),
        ),
      ],
    ),
  );
}

/// Short, glanceable start time: "Starting now", "in 25m", "in 3h", "Tomorrow
/// 7:30 PM", then a date. Deliberately local-time — the July UTC bug came from
/// formatting a naive timestamp, so this only ever formats a [DateTime] that
/// has already been converted with `.toLocal()`.
String nileWhen(DateTime? at) {
  if (at == null) return 'Scheduled';
  final local = at.toLocal();
  final now = DateTime.now();
  final delta = local.difference(now);

  if (delta.isNegative) return 'Starting now';
  if (delta.inMinutes < 1) return 'Starting now';
  if (delta.inMinutes < 60) return 'in ${delta.inMinutes}m';
  if (delta.inHours < 12) return 'in ${delta.inHours}h';

  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final days = day.difference(today).inDays;
  final time = _clock(local);
  if (days == 0) return 'Today $time';
  if (days == 1) return 'Tomorrow $time';
  if (days < 7) return '${_weekday(local.weekday)} $time';
  return '${_month(local.month)} ${local.day}, $time';
}

String _clock(DateTime d) {
  final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final minute = d.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${d.hour < 12 ? 'AM' : 'PM'}';
}

String _weekday(int w) =>
    const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][w - 1];

String _month(int m) => const [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
][m - 1];
