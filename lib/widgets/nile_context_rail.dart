import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../router.dart';
import '../services/app_lifecycle.dart';
import '../services/event_service.dart';
import '../theme.dart';
import 'live_badge.dart';
import 'nile_desktop.dart';

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
          // The rail is the shell's flexible zone, so on a wide display it is
          // handed far more than its 322 pt design width — 568 on a maximised
          // 16" MacBook. Past roughly 500 a single column of cards reads as
          // sparse rather than generous, so both sections lay out into as many
          // columns as fit and collapse back to one at the design width.
          if (live.isNotEmpty) ...[
            const NileSectionHeader(
              'Live now',
              accent: NileColors.coral,
              dense: true,
            ),
            NileCardGrid(
              minItemWidth: _minCardWidth,
              maxColumns: 2,
              children: [
                for (final e in live) _LiveCard(event: e, onTap: () => _open(e)),
              ],
            ),
            const SizedBox(height: NileSpacing.s24),
          ],
          if (upcoming.isNotEmpty) ...[
            const NileSectionHeader('Up next', dense: true),
            NileCardGrid(
              minItemWidth: _minCardWidth,
              maxColumns: 2,
              spacing: NileSpacing.s8,
              children: [
                for (final e in upcoming)
                  _UpNextRow(event: e, onTap: () => _open(e)),
              ],
            ),
          ],
        ],
      ],
    );
  }
}

/// Below this the rail is at (or near) its design width and everything sits in
/// one column; two of these plus the grid gap is what a second column costs.
const double _minCardWidth = 240;

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

  // A past timestamp used to collapse to "Starting now" whether the slot was 40
  // seconds or three days ago. Only the first few minutes still read as "now";
  // past that, fall through to an absolute date, which can't lie.
  if (delta.isNegative) {
    if (delta.inMinutes > -10) return 'Starting now';
    final clock = nileClock(local);
    final daysAgo = nileDayKey(now).difference(nileDayKey(local)).inDays;
    if (daysAgo == 0) return 'Earlier today, $clock';
    if (daysAgo == 1) return 'Yesterday $clock';
    return '${nileMonthAbbr(local.month)} ${local.day}, $clock';
  }

  if (delta.inMinutes < 1) return 'Starting now';
  if (delta.inMinutes < 60) return 'in ${delta.inMinutes}m';
  if (delta.inHours < 12) return 'in ${delta.inHours}h';

  final days = nileDayKey(local).difference(nileDayKey(now)).inDays;
  final time = nileClock(local);
  if (days == 0) return 'Today $time';
  if (days == 1) return 'Tomorrow $time';
  if (days < 7) return '${nileWeekdayAbbr(local.weekday)} $time';
  return '${nileMonthAbbr(local.month)} ${local.day}, $time';
}
