import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/formats.dart';

import '../theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// The shared vocabulary for the Phase 7 desktop screen layouts.
//
// Every bespoke desktop layout is assembled from the pieces in this file rather
// than growing its own. Phase 5b built the shell — rails, top bar, context rail;
// this is the level below that: the bands, headers, hover treatment and split
// bodies the nine screens are made of. Anything a second screen would need a
// near-copy of belongs here.
//
// Nothing here is desktop-gated on its own. The widgets are laid out by the
// space they are given, so a caller can use one inside a compact layout if it
// happens to fit; the decision of *when* to use a desktop band stays with the
// screen, next to the rest of its layout logic.
// ─────────────────────────────────────────────────────────────────────────────

// ── Date formatting ──────────────────────────────────────────────────────────
// Shared so a time reads identically in the context rail, the coming-up strip
// and the schedule grid. All of these take an already-local DateTime: the July
// UTC bug came from formatting a naive timestamp, so conversion stays at the
// call site where it is visible.

String nileClock(DateTime d) => NileFormats.time(d);

/// Hour only, for a dense grid axis: "7 PM", "12 AM", or "19" on a 24h locale.
String nileHourLabel(int hour24) =>
    DateFormat.j().format(DateTime(2024, 1, 1, hour24));

// P4 #41: these were hardcoded English abbreviation tables. intl derives them
// from the ambient locale instead, so the desktop week strip reads correctly
// wherever it's opened. Both take a number rather than a DateTime, so an
// arbitrary date in the right month/weekday is enough to format from.
String nileWeekdayAbbr(int weekday) =>
    NileFormats.weekday(DateTime(2024, 1, weekday));  // 2024-01-01 was a Monday

String nileMonthAbbr(int month) =>
    DateFormat.MMM().format(DateTime(2024, month));

/// Midnight local on the same day as [d] — the canonical key for bucketing
/// events into days. Anything that groups by day must go through this, or
/// two events an hour apart can land in different buckets.
DateTime nileDayKey(DateTime d) => DateTime(d.year, d.month, d.day);

/// [d] shifted by [n] days, keeping the time of day.
///
/// Deliberately not `d.add(Duration(days: n))`. A Duration is an exact span of
/// elapsed time, so crossing a daylight-saving boundary lands an hour either
/// side of midnight — and every day bucket computed from it after that point is
/// off by one. Constructing the date instead is wall-clock arithmetic, which is
/// what a calendar means by "a week later".
DateTime nileAddDays(DateTime d, int n) =>
    DateTime(d.year, d.month, d.day + n, d.hour, d.minute);

/// Local midnight on the Monday of [d]'s week.
DateTime nileMondayOf(DateTime d) =>
    DateTime(d.year, d.month, d.day - (d.weekday - DateTime.monday));

/// Whole calendar days from [from] to [to], counting date boxes on a wall
/// calendar rather than elapsed time.
///
/// `nileDayKey(a).difference(nileDayKey(b)).inDays` looks equivalent and isn't:
/// a Duration measures real elapsed hours, and the gap between two local
/// midnights is 23 hours on a spring-forward day and 25 on a fall-back one.
/// Truncating 23 hours gives 0, so "Tomorrow" read as "Today" every March.
/// Rebuilding the dates in UTC removes DST from the arithmetic entirely.
int nileDaysBetween(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day)
        .difference(DateTime.utc(from.year, from.month, from.day))
        .inDays;

/// "Today", "Tomorrow", then "Wed 13".
String nileDayLabel(DateTime day, {DateTime? now}) {
  final days = nileDaysBetween(now ?? DateTime.now(), day);
  if (days == 0) return 'Today';
  if (days == 1) return 'Tomorrow';
  return '${nileWeekdayAbbr(day.weekday)} ${day.day}';
}

// ── Section header ───────────────────────────────────────────────────────────

/// The header above every desktop band. One widget so Home's live band, the
/// coming-up strip and the schedule sections can't drift into three slightly
/// different treatments.
class NileSectionHeader extends StatelessWidget {
  const NileSectionHeader(
    this.label, {
    super.key,
    this.accent,
    this.trailing,
    this.dense = false,
    this.padding,
  });

  final String label;

  /// A dot in this colour precedes the label and tints it. Coral marks live.
  final Color? accent;

  /// Right-aligned action — a "See all" button, a filter, a count.
  final Widget? trailing;

  /// Small-caps treatment for narrow columns (the context rail).
  final bool dense;

  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final style = dense
        ? NileTextStyles.labelSm().copyWith(
            color: accent ?? NileColors.txtSecondary,
            fontWeight: FontWeight.w700,
          )
        : NileTextStyles.labelMd().copyWith(
            color: accent ?? NileColors.txtPrimary,
          );
    final dotSize = dense ? 6.0 : 8.0;

    return Padding(
      padding: padding ??
          EdgeInsets.fromLTRB(
            dense ? 0 : NileSpacing.s16,
            dense ? 0 : NileSpacing.s16,
            dense ? 0 : NileSpacing.s16,
            NileSpacing.s12,
          ),
      child: Row(
        children: [
          if (accent != null) ...[
            Container(
              width: dotSize,
              height: dotSize,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            ),
            const SizedBox(width: NileSpacing.s8),
          ],
          Expanded(child: Text(dense ? label.toUpperCase() : label, style: style)),
          ?trailing,
        ],
      ),
    );
  }
}

// ── Hover ────────────────────────────────────────────────────────────────────

/// Desktop hover treatment for a card: a small lift, a brightened border, and
/// whatever extra the builder chooses to reveal.
///
/// Inert on touch devices rather than gated on one — [MouseRegion]'s callbacks
/// simply never fire without a pointer, so the same widget is safe to build on a
/// phone and `hovered` stays false there.
class NileHoverCard extends StatefulWidget {
  const NileHoverCard({
    super.key,
    required this.builder,
    this.scale = 1.015,
    this.borderRadius = NileRadius.lg,
    this.lift = true,
  });

  /// Rebuilt on enter and exit. Use [hovered] to reveal a play affordance,
  /// swap a thumbnail for a preview, or show secondary metadata.
  final Widget Function(BuildContext context, bool hovered) builder;

  final double scale;
  final double borderRadius;

  /// Set false when the card is inside a horizontally-clipped strip, where a
  /// scaled card would be cut off at the edge instead of lifting.
  final bool lift;

  @override
  State<NileHoverCard> createState() => _NileHoverCardState();
}

class _NileHoverCardState extends State<NileHoverCard> {
  bool _hovered = false;

  void _set(bool v) {
    if (_hovered != v && mounted) setState(() => _hovered = v);
  }

  @override
  Widget build(BuildContext context) {
    final child = AnimatedContainer(
      duration: NileMotion.fast,
      curve: NileMotion.curve,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        border: Border.all(
          color: _hovered ? NileColors.borderStrong : NileColors.border,
        ),
        boxShadow: _hovered && widget.lift
            ? [
                BoxShadow(
                  color: const Color(0x33000000),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ]
            : const [],
      ),
      clipBehavior: Clip.antiAlias,
      child: widget.builder(context, _hovered),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _set(true),
      onExit: (_) => _set(false),
      child: widget.lift
          ? AnimatedScale(
              scale: _hovered ? widget.scale : 1,
              duration: NileMotion.fast,
              curve: NileMotion.curve,
              child: child,
            )
          : child,
    );
  }
}

// ── Day scrubber ─────────────────────────────────────────────────────────────

/// The day selector above a coming-up strip or a schedule grid.
///
/// Days are supplied by the caller from real data, so a quiet week shows the
/// days that have something on rather than seven dead chips.
class NileDayStrip extends StatelessWidget {
  const NileDayStrip({
    super.key,
    required this.days,
    required this.selected,
    required this.onSelected,
    this.countFor,
    this.allLabel = 'All',
  });

  /// Local midnights, ascending. Use [nileDayKey] to build them.
  final List<DateTime> days;

  /// null selects [allLabel].
  final DateTime? selected;

  final ValueChanged<DateTime?> onSelected;

  /// Optional badge count per day.
  final int Function(DateTime day)? countFor;

  final String allLabel;

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) return const SizedBox.shrink();
    final now = DateTime.now();
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16),
        itemCount: days.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: NileSpacing.s8),
        itemBuilder: (_, i) {
          if (i == 0) {
            return _DayChip(
              label: allLabel,
              selected: selected == null,
              onTap: () => onSelected(null),
            );
          }
          final day = days[i - 1];
          return _DayChip(
            label: nileDayLabel(day, now: now),
            count: countFor?.call(day),
            selected: selected != null && nileDayKey(selected!) == day,
            onTap: () => onSelected(day),
          );
        },
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    // Volt fill for the selected day, matching the rail's selected treatment —
    // a tinted surface, never a volt glyph on the page background.
    final fg = selected ? NileColors.onVolt : NileColors.txtSecondary;
    return Material(
      color: selected ? NileColors.volt : NileColors.bgSurface,
      borderRadius: BorderRadius.circular(NileRadius.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NileRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(NileRadius.pill),
            border: Border.all(
              color: selected ? Colors.transparent : NileColors.border,
            ),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: NileTextStyles.labelMd().copyWith(
                  color: fg,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              if (count != null && count! > 0) ...[
                const SizedBox(width: NileSpacing.s6),
                Text(
                  '$count',
                  style: NileTextStyles.caption().copyWith(color: fg).tabular,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Topic colour coding ──────────────────────────────────────────────────────

/// Deterministic colour for a topic, so the same topic reads the same on every
/// schedule grid without a palette column in the database. Keyed on the topic
/// id (stable) rather than its name (editable).
Color nileTopicTint(String key) {
  const palette = <Color>[
    NileColors.azure,
    NileColors.violet,
    NileColors.amber,
    NileColors.coral,
    NileColors.success,
    Color(0xFF14B8A6), // teal
    Color(0xFFF472B6), // pink
    Color(0xFF60A5FA), // sky
  ];
  var h = 0;
  for (final unit in key.codeUnits) {
    h = (h * 31 + unit) & 0x7fffffff;
  }
  return palette[h % palette.length];
}

// ── Split body ───────────────────────────────────────────────────────────────

/// A two-zone body for a screen that owns the whole window: a content column
/// with a panel pinned beside it.
///
/// This is deliberately NOT the shell's arithmetic. In the shell both rails are
/// pinned to the window edges, so the middle column would visibly float in a
/// gutter unless the three zones summed to exactly the window width. A pushed
/// detail screen has no rails to anchor against, so the pair is capped and
/// centred instead — and the screen puts a full-bleed hero above it to hold the
/// window edges, which is what stops the centring from reading as dead space.
///
/// Below [splitsAt] there is no room for both. [narrow] is supplied by the
/// caller rather than derived, because folding a sticky panel back into a
/// scrolling column is a per-screen decision, not a layout one.
class NileDesktopSplit extends StatelessWidget {
  const NileDesktopSplit({
    super.key,
    required this.content,
    required this.side,
    required this.narrow,
    this.sideWidth = defaultSideWidth,
    this.maxTotalWidth = defaultMaxTotalWidth,
    this.gap = NileSpacing.s32,
  });

  /// Fills the content column. Usually its own scroll view.
  final Widget content;

  /// Fixed-width panel beside [content]. Sticky — it does not scroll with the
  /// content, so it must fit or scroll itself.
  final Widget side;

  /// Used whole when there isn't room to split.
  final Widget narrow;

  final double sideWidth;
  final double maxTotalWidth;
  final double gap;

  static const double defaultSideWidth = 340;
  static const double defaultMaxTotalWidth = 1180;

  /// Narrower than this and the content column stops being readable.
  static const double minContentWidth = 520;

  double get splitsAt => minContentWidth + gap + sideWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final available = constraints.maxWidth;
      if (!available.isFinite || available < splitsAt) return narrow;
      final total = available < maxTotalWidth ? available : maxTotalWidth;
      final contentWidth = total - gap - sideWidth;
      // topCenter, not Center: a body shorter than the window would otherwise
      // float halfway down it, detached from whatever sits above. Horizontal
      // centring is the point here; vertical centring never was.
      return Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: total,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: contentWidth, child: content),
              SizedBox(width: gap),
              SizedBox(width: sideWidth, child: side),
            ],
          ),
        ),
      );
    },
  );
}

// ── Responsive card grid ─────────────────────────────────────────────────────

/// Lays [children] into as many columns of at least [minItemWidth] as fit, and
/// falls back to one column when only one fits.
///
/// Used by the live band, the coming-up strip and (Phase 7 later) Discover's
/// results and the context rail above ~450 px, where a single-column card list
/// starts to look sparse.
class NileCardGrid extends StatelessWidget {
  const NileCardGrid({
    super.key,
    required this.children,
    this.minItemWidth = 300,
    this.spacing = NileSpacing.s12,
    this.maxColumns = 4,
  });

  final List<Widget> children;
  final double minItemWidth;
  final double spacing;
  final int maxColumns;

  /// How many columns of [minItemWidth] fit in [width]. At least 1.
  static int columnsFor(
    double width, {
    double minItemWidth = 300,
    double spacing = NileSpacing.s12,
    int maxColumns = 4,
  }) {
    if (!width.isFinite || width <= 0) return 1;
    var n = ((width + spacing) / (minItemWidth + spacing)).floor();
    if (n < 1) n = 1;
    if (n > maxColumns) n = maxColumns;
    return n;
  }

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = columnsFor(
          constraints.maxWidth,
          minItemWidth: minItemWidth,
          spacing: spacing,
          maxColumns: maxColumns,
        );
        final itemWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final child in children)
              SizedBox(width: itemWidth, child: child),
          ],
        );
      },
    );
  }
}
