import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../router.dart';
import '../services/event_service.dart';
import '../services/follow_service.dart';
import '../services/supabase_client.dart';
import '../services/topic_service.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/nile_desktop.dart';
import '../widgets/nile_glass_nav_bar.dart';
import '../widgets/nile_skeleton.dart';

/// The Schedule destination — a week of what's on, as a board.
///
/// New in Phase 7 and desktop-first: it is the fifth shell branch but has no
/// slot in the phone bar, so on a phone it is only reachable from a link. The
/// layout answers to its own width rather than to the window class, because the
/// shell hands this branch the full width left of the window (the context rail
/// is suppressed here — "live now / up next" is exactly what a schedule already
/// shows).
///
/// Wide enough for seven readable columns and it is a week board; narrower and
/// it becomes a one-day agenda with the day scrubber doing the navigating.
class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key});

  /// Below seven columns of this width the board stops being legible and the
  /// agenda takes over.
  static const double minColumnWidth = 150;
  static const double minWeekBoardWidth = minColumnWidth * 7;

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

/// Whose events to show. Deliberately not a topic filter — that is a separate
/// axis and both apply at once.
enum ScheduleScope { all, following, mine }

class _ScheduleScreenState extends State<ScheduleScreen> {
  /// Local midnight on the Monday of the week being shown.
  late DateTime _weekStart;

  List<Event>? _events;
  Map<String, List<String>> _eventTopics = const {};
  List<Topic> _topics = const [];
  Set<String> _following = const {};
  String? _error;

  ScheduleScope _scope = ScheduleScope.all;
  String? _topicFilter;

  /// Agenda mode only. Null means "the whole week".
  DateTime? _selectedDay;

  String? get _myId => supabase.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _weekStart = nileMondayOf(DateTime.now());
    _load();
    _loadStatic();
  }

  // ── Week arithmetic ────────────────────────────────────────────────────────
  // All of it goes through nileAddDays / nileMondayOf, which are wall-clock
  // rather than Duration arithmetic — see their docs for why that matters
  // across a daylight-saving boundary.

  List<DateTime> get _weekDays =>
      [for (var i = 0; i < 7; i++) nileAddDays(_weekStart, i)];

  bool get _isThisWeek => _weekStart == nileMondayOf(DateTime.now());

  void _shiftWeek(int weeks) {
    setState(() {
      _weekStart = nileAddDays(_weekStart, weeks * 7);
      _selectedDay = null;
      _events = null;
    });
    _load();
  }

  void _goToday() {
    if (_isThisWeek) return;
    setState(() {
      _weekStart = nileMondayOf(DateTime.now());
      _selectedDay = null;
      _events = null;
    });
    _load();
  }

  // ── Loading ────────────────────────────────────────────────────────────────

  /// Topic names and the follow graph don't change week to week, so they load
  /// once instead of on every arrow press.
  Future<void> _loadStatic() async {
    try {
      final topics = await TopicService.listTopics();
      final following = await FollowService.getFollowingIds();
      if (!mounted) return;
      setState(() {
        _topics = topics;
        _following = following.toSet();
      });
    } catch (_) {
      // Filters degrade to "All" rather than blocking the grid.
    }
  }

  Future<void> _load() async {
    try {
      final events = await EventService.getScheduledBetween(
        from: _weekStart,
        to: nileAddDays(_weekStart, 7),
      );
      // Colour coding is decoration: a failure here must not empty the grid.
      var topics = const <String, List<String>>{};
      try {
        topics = await TopicService.topicIdsForEvents(
          [for (final e in events) e.id],
        );
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _events = events;
        _eventTopics = topics;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _events = const [];
        _error = 'Could not load the schedule';
      });
    }
  }

  // ── Filtering ──────────────────────────────────────────────────────────────

  bool _passes(Event e) {
    switch (_scope) {
      case ScheduleScope.all:
        break;
      case ScheduleScope.following:
        if (!_following.contains(e.hostId)) return false;
      case ScheduleScope.mine:
        if (e.hostId != _myId) return false;
    }
    final topic = _topicFilter;
    if (topic != null && !(_eventTopics[e.id] ?? const []).contains(topic)) {
      return false;
    }
    return true;
  }

  /// Events bucketed by local day. The `.toLocal()` is the whole point: the
  /// server hands back UTC, and bucketing a UTC timestamp into a local day
  /// column is how an 8 PM Sunday show ends up in Monday's column.
  Map<DateTime, List<Event>> get _byDay {
    final out = <DateTime, List<Event>>{};
    for (final e in _events ?? const <Event>[]) {
      final at = e.scheduledAt;
      if (at == null || !_passes(e)) continue;
      (out[nileDayKey(at.toLocal())] ??= []).add(e);
    }
    for (final list in out.values) {
      list.sort((a, b) => a.scheduledAt!.compareTo(b.scheduledAt!));
    }
    return out;
  }

  /// Only the topics actually present this week — a filter row of topics with
  /// nothing behind them is just noise.
  List<Topic> get _topicsThisWeek {
    final present = <String>{};
    for (final e in _events ?? const <Event>[]) {
      present.addAll(_eventTopics[e.id] ?? const []);
    }
    return [for (final t in _topics) if (present.contains(t.id)) t];
  }

  void _open(Event e) {
    final location = NileRoutes.eventOrWatch(
      isLive: e.isLive,
      eventId: e.id,
      liveKitEventId: e.liveKitEventId,
    );
    context.push(location, extra: location.startsWith('/event/') ? e : null);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final compact = NileBreakpoints.of(context).isCompact;
    final body = SafeArea(
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final board =
              constraints.maxWidth >= ScheduleScreen.minWeekBoardWidth;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                weekStart: _weekStart,
                isThisWeek: _isThisWeek,
                onPrevious: () => _shiftWeek(-1),
                onNext: () => _shiftWeek(1),
                onToday: _goToday,
              ),
              _Filters(
                scope: _scope,
                onScope: (s) => setState(() => _scope = s),
                topics: _topicsThisWeek,
                topicFilter: _topicFilter,
                onTopic: (id) => setState(() => _topicFilter = id),
              ),
              if (!board) ...[
                const SizedBox(height: NileSpacing.s8),
                NileDayStrip(
                  days: _weekDays,
                  selected: _selectedDay,
                  onSelected: (d) => setState(() => _selectedDay = d),
                  countFor: (d) => (_byDay[d] ?? const []).length,
                ),
              ],
              const SizedBox(height: NileSpacing.s16),
              Expanded(child: _content(board: board, compact: compact)),
            ],
          );
        },
      ),
    );

    // Inside the desktop shell the rail and top bar are already overhead, so the
    // screen is just a body. A phone can only reach this from a link, and there
    // is no Schedule slot in its nav bar — so it gets a plain titled scaffold.
    if (!compact) return body;
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(title: const Text('Schedule')),
      body: body,
    );
  }

  Widget _content({required bool board, required bool compact}) {
    if (_events == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: NileSpacing.s16),
        child: NileSkeletonList(),
      );
    }
    final byDay = _byDay;
    final total = byDay.values.fold<int>(0, (n, l) => n + l.length);
    if (total == 0) {
      return NileEmptyState(
        icon: _error != null
            ? Icons.cloud_off_outlined
            : Icons.event_available_outlined,
        title: _error ?? 'Nothing scheduled',
        body: _error != null
            ? 'Check your connection and try again.'
            : _scope == ScheduleScope.all && _topicFilter == null
            ? 'No shows are on the calendar this week.'
            : 'Nothing matches these filters this week.',
        actionLabel: _error != null ? 'Retry' : null,
        onAction: _error != null
            ? () {
                setState(() {
                  _events = null;
                  _error = null;
                });
                _load();
              }
            : null,
      );
    }

    // Only the phone layout has a floating nav bar for the last card to clear.
    final bottomGap = compact
        ? NileGlassNavBar.reservedHeight + NileSpacing.s16
        : NileSpacing.s32;

    return board
        ? _WeekBoard(
            days: _weekDays,
            byDay: byDay,
            topicOf: _topicOf,
            onOpen: _open,
            bottomGap: bottomGap,
          )
        : _Agenda(
            days: _selectedDay != null ? [_selectedDay!] : _weekDays,
            byDay: byDay,
            topicOf: _topicOf,
            onOpen: _open,
            bottomGap: bottomGap,
          );
  }

  /// The colour a card is coded with: its first topic, or null when untagged.
  /// First rather than blended, because a two-tone card reads as a bug.
  Color? _topicOf(Event e) {
    final ids = _eventTopics[e.id];
    if (ids == null || ids.isEmpty) return null;
    return nileTopicTint(ids.first);
  }
}

// ── Header ───────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({
    required this.weekStart,
    required this.isThisWeek,
    required this.onPrevious,
    required this.onNext,
    required this.onToday,
  });

  final DateTime weekStart;
  final bool isThisWeek;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onToday;

  /// "Aug 10 – 16", or "Aug 31 – Sep 6" when the week straddles two months.
  String get _range {
    final end = nileAddDays(weekStart, 6);
    final from = '${nileMonthAbbr(weekStart.month)} ${weekStart.day}';
    final to = end.month == weekStart.month
        ? '${end.day}'
        : '${nileMonthAbbr(end.month)} ${end.day}';
    return '$from – $to';
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      NileSpacing.s16,
      NileSpacing.s16,
      NileSpacing.s16,
      NileSpacing.s12,
    ),
    child: Row(
      children: [
        Text(
          isThisWeek ? 'This week' : _range,
          style: NileTextStyles.headingMd(),
        ),
        if (isThisWeek) ...[
          const SizedBox(width: NileSpacing.s12),
          Text(
            _range,
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtTertiary,
            ),
          ),
        ],
        const Spacer(),
        if (!isThisWeek)
          TextButton(onPressed: onToday, child: const Text('Today')),
        IconButton(
          tooltip: 'Previous week',
          onPressed: onPrevious,
          icon: const Icon(Icons.chevron_left),
        ),
        IconButton(
          tooltip: 'Next week',
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    ),
  );
}

// ── Filters ──────────────────────────────────────────────────────────────────

class _Filters extends StatelessWidget {
  const _Filters({
    required this.scope,
    required this.onScope,
    required this.topics,
    required this.topicFilter,
    required this.onTopic,
  });

  final ScheduleScope scope;
  final ValueChanged<ScheduleScope> onScope;
  final List<Topic> topics;
  final String? topicFilter;
  final ValueChanged<String?> onTopic;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16),
    child: Row(
      children: [
        for (final s in ScheduleScope.values) ...[
          _Chip(
            label: switch (s) {
              ScheduleScope.all => 'All',
              ScheduleScope.following => 'Following',
              ScheduleScope.mine => 'My events',
            },
            selected: scope == s,
            onTap: () => onScope(s),
          ),
          const SizedBox(width: NileSpacing.s8),
        ],
        if (topics.isNotEmpty) ...[
          Container(
            width: 1,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: NileSpacing.s8),
            color: NileColors.border,
          ),
          for (final t in topics) ...[
            _Chip(
              label: t.name,
              // Tapping the active topic clears it — a chip row with no
              // visible "clear" needs the toggle to be the way out.
              selected: topicFilter == t.id,
              accent: nileTopicTint(t.id),
              onTap: () => onTopic(topicFilter == t.id ? null : t.id),
            ),
            const SizedBox(width: NileSpacing.s8),
          ],
        ],
      ],
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.accent,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final tint = accent ?? NileColors.volt;
    return Material(
      color: selected ? tint.withValues(alpha: 0.15) : Colors.transparent,
      borderRadius: BorderRadius.circular(NileRadius.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NileRadius.pill),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(NileRadius.pill),
            border: Border.all(
              color: selected ? tint : NileColors.border,
            ),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (accent != null) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                ),
                const SizedBox(width: NileSpacing.s6),
              ],
              Text(
                label,
                style: NileTextStyles.labelMd().copyWith(
                  color: selected ? NileColors.txtPrimary : NileColors.txtSecondary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Week board ───────────────────────────────────────────────────────────────

/// Seven day columns side by side.
///
/// Not a time-proportional grid. At Nile's density an hour-by-hour grid would
/// be mostly empty rows with a few cards floating in them; a board keeps the
/// day-to-day comparison a calendar is for without the dead space. The day
/// headers sit outside the scroll view so they stay put while the columns move.
class _WeekBoard extends StatelessWidget {
  const _WeekBoard({
    required this.days,
    required this.byDay,
    required this.topicOf,
    required this.onOpen,
    required this.bottomGap,
  });

  final List<DateTime> days;
  final Map<DateTime, List<Event>> byDay;
  final Color? Function(Event) topicOf;
  final void Function(Event) onOpen;
  final double bottomGap;

  @override
  Widget build(BuildContext context) {
    final today = nileDayKey(DateTime.now());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final day in days)
                Expanded(
                  child: _DayHeader(
                    day: day,
                    isToday: day == today,
                    count: (byDay[day] ?? const []).length,
                  ),
                ),
            ],
          ),
        ),
        Divider(color: NileColors.border, height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              NileSpacing.s16,
              NileSpacing.s12,
              NileSpacing.s16,
              bottomGap,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final day in days)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: NileSpacing.s4,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final e in byDay[day] ?? const <Event>[])
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: NileSpacing.s8,
                              ),
                              child: _ScheduleCard(
                                event: e,
                                tint: topicOf(e),
                                dense: true,
                                onTap: () => onOpen(e),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.day,
    required this.isToday,
    required this.count,
  });

  final DateTime day;
  final bool isToday;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: NileSpacing.s8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          nileWeekdayAbbr(day.weekday).toUpperCase(),
          style: NileTextStyles.caption().copyWith(
            color: isToday ? NileColors.volt : NileColors.txtTertiary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: NileSpacing.s2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '${day.day}',
              style: NileTextStyles.headingSm().copyWith(
                color: isToday ? NileColors.volt : NileColors.txtPrimary,
              ).tabular,
            ),
            if (count > 0) ...[
              const SizedBox(width: NileSpacing.s6),
              Text(
                '$count',
                style: NileTextStyles.caption().tabular,
              ),
            ],
          ],
        ),
      ],
    ),
  );
}

// ── Agenda ───────────────────────────────────────────────────────────────────

/// The narrow fallback: one day at a time (or the whole week stacked), with the
/// day scrubber above doing the navigating.
class _Agenda extends StatelessWidget {
  const _Agenda({
    required this.days,
    required this.byDay,
    required this.topicOf,
    required this.onOpen,
    required this.bottomGap,
  });

  final List<DateTime> days;
  final Map<DateTime, List<Event>> byDay;
  final Color? Function(Event) topicOf;
  final void Function(Event) onOpen;
  final double bottomGap;

  @override
  Widget build(BuildContext context) {
    final withEvents = [
      for (final d in days)
        if ((byDay[d] ?? const []).isNotEmpty) d,
    ];
    return ListView(
      padding: EdgeInsets.fromLTRB(0, 0, 0, bottomGap),
      children: [
        for (final day in withEvents) ...[
          NileSectionHeader(
            nileDayLabel(day),
            trailing: Text(
              '${nileMonthAbbr(day.month)} ${day.day}',
              style: NileTextStyles.bodySm().copyWith(
                color: NileColors.txtTertiary,
              ),
            ),
          ),
          for (final e in byDay[day]!)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NileSpacing.s16,
                0,
                NileSpacing.s16,
                NileSpacing.s8,
              ),
              child: _ScheduleCard(
                event: e,
                tint: topicOf(e),
                onTap: () => onOpen(e),
              ),
            ),
          const SizedBox(height: NileSpacing.s16),
        ],
      ],
    );
  }
}

// ── Card ─────────────────────────────────────────────────────────────────────

/// One scheduled show. The topic colour is a stripe down the leading edge
/// rather than a fill, so a column of cards stays readable when four topics are
/// on screen at once.
class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({
    required this.event,
    required this.onTap,
    this.tint,
    this.dense = false,
  });

  final Event event;
  final VoidCallback onTap;
  final Color? tint;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final at = event.scheduledAt?.toLocal();
    final live = event.isLive;
    final over = event.isOver;
    final stripe = live
        ? NileColors.coral
        : (over ? NileColors.border : (tint ?? NileColors.border));

    return NileHoverCard(
      borderRadius: NileRadius.md,
      lift: false,
      builder: (context, hovered) => Material(
        color: hovered ? NileColors.bgRaised : NileColors.bgSurface,
        child: InkWell(
          onTap: onTap,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 3, color: stripe),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(NileSpacing.s12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (live) ...[
                              Container(
                                width: 6,
                                height: 6,
                                decoration: const BoxDecoration(
                                  color: NileColors.coral,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: NileSpacing.s6),
                            ],
                            Text(
                              live
                                  ? 'LIVE'
                                  : over
                                      ? 'ENDED'
                                      : (at == null ? '' : nileClock(at)),
                              style: NileTextStyles.caption().copyWith(
                                color: live
                                    ? NileColors.coral
                                    : over
                                        ? NileColors.txtTertiary
                                        : NileColors.txtSecondary,
                                fontWeight: FontWeight.w700,
                              ).tabular,
                            ),
                          ],
                        ),
                        const SizedBox(height: NileSpacing.s4),
                        Text(
                          event.title,
                          maxLines: dense ? 3 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: NileTextStyles.labelMd(),
                        ),
                        const SizedBox(height: NileSpacing.s2),
                        Text(
                          '@${event.hostUsername}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NileTextStyles.caption(),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
