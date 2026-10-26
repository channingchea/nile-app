import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/live_elements.dart';
import '../../services/overlay_clock.dart';
import '../../services/server_clock.dart';
import '../../theme.dart';
import '../overlay_look.dart';
import 'element_kinds.dart';

/// Polls (docs/plans/studio-poll.md): multiple choice, yes/no, rating 1–5 and
/// pick several. A card on a camera or its own angle; viewers vote on the
/// card (larger screens) or from a sheet (phones); the Studio opens, closes,
/// times, reveals and resets.

final pollUi = ElementKindUi(
  render: (e, u, {required full, interaction}) =>
      PollView(e: e, u: u, full: full, interaction: interaction),
  editor: (config, onChanged, {required locked}) =>
      _PollEditor(config: config, onChanged: onChanged, locked: locked),
  controls: (e, act, tally) => _PollControls(e: e, act: act, tally: tally),
  shortcuts: [
    ElementShortcut(
      const [SingleActivator(LogicalKeyboardKey.keyO)],
      'Open / close',
      pollToggleOpen,
    ),
    ElementShortcut(
      const [SingleActivator(LogicalKeyboardKey.keyV)],
      'Reveal / hide results',
      pollReveal,
    ),
    ElementShortcut(
      const [SingleActivator(LogicalKeyboardKey.keyT)],
      'Start timer',
      (e) => pollStartTimer(e),
    ),
  ],
);

PollConfig _config(LiveElement e) => PollConfig.fromJson(e.config);
PollState _state(LiveElement e) => PollState.of(e.state);

/// Taking votes right now (open, timer not run out).
bool pollOpenNow(LiveElement e, [int? now]) =>
    _state(e).openAt(now ?? ServerClock.now());

/// Timer length to use: the poll's default, else a minute.
int _timerSec(LiveElement e) => _config(e).timerSec ?? 60;

// ── Studio changes ───────────────────────────────────────────────────────────

/// Open (starting its default timer, if it has one) or close. Reopening keeps
/// the votes.
ElementChange pollToggleOpen(LiveElement e) {
  final open = pollOpenNow(e);
  final timer = _config(e).timerSec;
  return (
    change: (cur) {
      final s = {...cur.state};
      open ? s.remove('open') : s['open'] = true;
      return cur.copyWith(state: s);
    },
    clockOps: const {},
    // Closing (or reopening after the timer ran out) drops the countdown.
    ops: !open && timer != null
        ? ElementOps(timer: true, timerSec: timer)
        : _state(e).closesAt != null
        ? const ElementOps(timer: false)
        : ElementOps.none,
  );
}

/// Start (or restart) the countdown; it opens the poll if it isn't.
ElementChange pollStartTimer(LiveElement e, [int? sec]) => (
  change: (cur) => cur.copyWith(state: {...cur.state, 'open': true}),
  clockOps: const {},
  ops: ElementOps(timer: true, timerSec: sec ?? _timerSec(e)),
);

ElementChange _cancelTimer(LiveElement e) => (
  change: (cur) => cur,
  clockOps: const {},
  ops: const ElementOps(timer: false),
);

/// Live results: viewers always see the totals, so there's nothing to reveal.
bool _alwaysShown(LiveElement e) => _config(e).results == PollResultsMode.live;

/// Show the totals to every viewer, or hide them again. "After you vote"
/// polls reveal to people who haven't voted too; live ones always show.
ElementChange pollReveal(LiveElement e) => (
  change: (cur) {
    if (_alwaysShown(cur)) return cur;
    final s = {...cur.state};
    s['revealed'] == true ? s.remove('revealed') : s['revealed'] = true;
    return cur.copyWith(state: s);
  },
  clockOps: const {},
  ops: ElementOps.none,
);

/// Clear every vote and start again: closed, hidden, no timer.
ElementChange _reset(LiveElement e) => (
  change: (cur) => cur.copyWith(state: const {}),
  clockOps: const {},
  ops: const ElementOps(reset: true),
);

// ── On screen ────────────────────────────────────────────────────────────────

/// A poll over the video ([full] = its own angle). Scales off [u] (1% of the
/// picture's width) so it reads the same on a phone, desktop and a replay tile.
class PollView extends StatefulWidget {
  const PollView({
    super.key,
    required this.e,
    required this.u,
    this.full = false,
    this.interaction,
  });

  final LiveElement e;
  final double u;
  final bool full;
  final ElementInteraction? interaction;

  @override
  State<PollView> createState() => _PollViewState();
}

class _PollViewState extends State<PollView> {
  /// Pick several, on the card: what this viewer has ticked so far.
  Set<String>? _picking;

  @override
  void didUpdateWidget(PollView old) {
    super.didUpdateWidget(old);
    if (_state(widget.e).round != _state(old.e).round) _picking = null;
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.e;
    final s = _state(e);
    return Ticking(
      running: s.open && s.closesAt != null,
      builder: (context) => _build(context, OverlayClock.nowOf(context)),
    );
  }

  Widget _build(BuildContext context, int now) {
    final e = widget.e, c = _config(e), s = _state(e);
    final i = widget.interaction;
    final look = OverlayLook(e.style);
    final k = widget.full ? 2.0 : 1.0;
    final u = widget.u * k;
    final open = s.openAt(now) && e.live;
    final audience = i?.audience ?? ElementAudience.staff;
    final visible = pollResultsVisible(
      c,
      s,
      audience: audience,
      voted: i?.voted ?? false,
    );
    final results = PollResults(c, i?.tally ?? ElementTally.empty);
    final mine = {...?i?.mine};
    final canVote = open && (i?.onTap != null || (i?.needsSignIn ?? false));
    // A phone's short side is under a tablet's (the same line the shell uses).
    final phone =
        (MediaQuery.maybeSizeOf(context)?.shortestSide ?? double.infinity) <
        NileBreakpoints.minHeightForRail;
    // Phones vote from a sheet; larger screens tap the card itself.
    final onCard = canVote && !phone && !(i?.needsSignIn ?? false);
    final several = c.type == PollType.several;

    void pick(String id) {
      if (!onCard) return;
      if (several) {
        setState(() {
          final p = _picking ??= {...mine};
          p.contains(id) ? p.remove(id) : p.add(id);
        });
      } else {
        i!.onTap!([id]);
      }
    }

    final picking = _picking ?? mine;
    TextStyle small(Color color) => look.font(
      NileTextStyles.labelMd().copyWith(
        fontSize: u * 1.5,
        color: color,
        height: 1.2,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );

    final left = s.secondsLeft(now);
    final status = !open
        ? (s.open || s.round > 0 || !results.isEmpty ? 'Closed' : 'Opens soon')
        : left != null
        ? formatClock(left * 1000)
        : null;
    final hint = !visible
        ? (c.results == PollResultsMode.voted && open
              ? 'Results after you vote'
              : 'Results soon')
        : null;

    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          c.question.isEmpty ? 'Your question' : c.question,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: look.font(
            NileTextStyles.headingSm().copyWith(
              fontSize: u * 2.1,
              color: look.text,
              height: 1.2,
            ),
          ),
        ),
        SizedBox(height: u * 1),
        if (c.type == PollType.rating)
          _Rating(
            results: results,
            visible: visible,
            mine: mine,
            look: look,
            u: u,
            onTap: onCard ? pick : null,
          )
        else
          for (final a in c.items) ...[
            _AnswerRow(
              text: a.text.isEmpty ? 'Answer' : a.text,
              share: visible ? results.share(a.id) : null,
              percent: results.percent(a.id),
              mine: (several && onCard ? picking : mine).contains(a.id),
              look: look,
              u: u,
              onTap: onCard ? () => pick(a.id) : null,
            ),
            SizedBox(height: u * 0.6),
          ],
        if (several && onCard)
          Padding(
            padding: EdgeInsets.only(top: u * 0.4),
            child: _CardButton(
              label: picking.length > c.pickLimit
                  ? 'Pick up to ${c.pickLimit}'
                  : 'Submit',
              look: look,
              u: u,
              onTap:
                  picking.isEmpty ||
                      picking.length > c.pickLimit ||
                      _sameSet(picking, mine)
                  ? null
                  : () {
                      i!.onTap!([
                        for (final a in c.items)
                          if (picking.contains(a.id)) a.id,
                      ]);
                      setState(() => _picking = null);
                    },
            ),
          ),
        SizedBox(height: u * 0.4),
        Row(
          children: [
            Expanded(
              child: Text(
                [
                  if (visible) results.votesLabel,
                  if (audience == ElementAudience.staff &&
                      c.results == PollResultsMode.reveal &&
                      !s.revealed)
                    'Hidden from viewers',
                  ?hint,
                  if (canVote && phone) 'Tap to vote',
                  if (several && open && c.maxPicks != null)
                    'Pick up to ${c.pickLimit}',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: small(look.textDim),
              ),
            ),
            if (status != null)
              Text(status, style: small(open ? look.accent : look.textDim)),
          ],
        ),
      ],
    );

    Widget card = widget.full
        ? Container(
            color: look.page,
            alignment: Alignment.center,
            padding: EdgeInsets.all(widget.u * 6),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(width: widget.u * 70, child: body),
            ),
          )
        : Container(
            width: widget.u * 30,
            padding: EdgeInsets.symmetric(
              horizontal: widget.u * 1.6,
              vertical: widget.u * 1.2,
            ),
            decoration: BoxDecoration(
              color: look.panel.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(widget.u * 1.2),
              border: Border(
                top: BorderSide(color: look.accent, width: widget.u * 0.5),
              ),
            ),
            child: body,
          );
    if (canVote && phone && i != null) {
      card = Semantics(
        button: true,
        label: 'Vote: ${c.question}',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => showPollVoteSheet(context, e, i),
          child: card,
        ),
      );
    }
    return card;
  }
}

bool _sameSet(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

/// One answer: its text, a bar filling to its share when results show, and a
/// tick when it is this viewer's.
class _AnswerRow extends StatelessWidget {
  const _AnswerRow({
    required this.text,
    required this.share,
    required this.percent,
    required this.mine,
    required this.look,
    required this.u,
    this.onTap,
  });

  final String text;

  /// Null = results hidden.
  final double? share;
  final int percent;
  final bool mine;
  final OverlayLook look;
  final double u;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(u * 0.8);
    final style = look.font(
      NileTextStyles.labelLg().copyWith(
        fontSize: u * 1.7,
        color: look.text,
        height: 1.2,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final row = Container(
      decoration: BoxDecoration(
        color: look.text.withValues(alpha: 0.08),
        borderRadius: r,
        border: Border.all(
          color: mine ? look.accent : Colors.transparent,
          width: u * 0.25,
        ),
      ),
      child: ClipRRect(
        borderRadius: r,
        child: Stack(
          children: [
            if (share != null)
              Positioned.fill(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: share!.clamp(0.0, 1.0),
                  child: ColoredBox(
                    color: look.accent.withValues(alpha: mine ? 0.55 : 0.3),
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: u * 1,
                vertical: u * 0.7,
              ),
              child: Row(
                children: [
                  if (mine) ...[
                    Icon(Icons.check_circle, size: u * 1.8, color: look.accent),
                    SizedBox(width: u * 0.6),
                  ],
                  Expanded(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                  if (share != null) ...[
                    SizedBox(width: u * 0.6),
                    Text('$percent%', style: style),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return _tappable(row, onTap, selected: mine);
  }
}

Widget _tappable(Widget child, VoidCallback? onTap, {bool selected = false}) =>
    onTap == null
    ? child
    : Semantics(
        button: true,
        selected: selected,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: child,
          ),
        ),
      );

class _CardButton extends StatelessWidget {
  const _CardButton({
    required this.label,
    required this.look,
    required this.u,
    this.onTap,
  });

  final String label;
  final OverlayLook look;
  final double u;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => _tappable(
    Container(
      alignment: Alignment.center,
      padding: EdgeInsets.symmetric(vertical: u * 0.8),
      decoration: BoxDecoration(
        color: onTap == null ? look.text.withValues(alpha: 0.12) : look.accent,
        borderRadius: BorderRadius.circular(u * 0.8),
      ),
      child: Text(
        label,
        style: look.font(
          NileTextStyles.labelLg().copyWith(
            fontSize: u * 1.7,
            color: onTap == null ? look.textDim : look.onAccent,
          ),
        ),
      ),
    ),
    onTap,
  );
}

/// Rating 1–5: five stars to tap while open; the average and a bar per star
/// when results show.
class _Rating extends StatelessWidget {
  const _Rating({
    required this.results,
    required this.visible,
    required this.mine,
    required this.look,
    required this.u,
    this.onTap,
  });

  final PollResults results;
  final bool visible;
  final Set<String> mine;
  final OverlayLook look;
  final double u;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) {
    final given = int.tryParse(mine.firstOrNull ?? '') ?? 0;
    final stars = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var n = 1; n <= 5; n++)
          _tappable(
            Padding(
              padding: EdgeInsets.symmetric(horizontal: u * 0.3),
              child: Icon(
                n <= given ? Icons.star_rounded : Icons.star_outline_rounded,
                size: u * 4,
                color: n <= given ? look.accent : look.textDim,
              ),
            ),
            onTap == null ? null : () => onTap!('$n'),
            selected: n == given,
          ),
      ],
    );
    final avg = results.average;
    final label = look.font(
      NileTextStyles.labelMd().copyWith(
        fontSize: u * 1.4,
        color: look.textDim,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!visible || onTap != null || avg == null) stars,
        if (visible && avg != null) ...[
          SizedBox(height: u * 0.6),
          Row(
            children: [
              Text(
                avg.toStringAsFixed(1),
                style: look.font(
                  NileTextStyles.headingLg().copyWith(
                    fontSize: u * 4.2,
                    color: look.text,
                    height: 1,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              SizedBox(width: u * 0.4),
              Icon(Icons.star_rounded, size: u * 3, color: look.accent),
              SizedBox(width: u * 1.2),
              Expanded(
                child: Column(
                  children: [
                    for (var n = 5; n >= 1; n--)
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: u * 0.15),
                        child: Row(
                          children: [
                            SizedBox(
                              width: u * 1.4,
                              child: Text('$n', style: label),
                            ),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(u),
                                child: LinearProgressIndicator(
                                  value: results.share('$n'),
                                  minHeight: u * 0.7,
                                  color: look.accent,
                                  backgroundColor: look.text.withValues(
                                    alpha: 0.12,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

// ── Voting from a sheet (phones, and the "Poll is live" pill) ────────────────

/// Big buttons for [e]: tap an answer (or a star) to vote; pick several
/// chooses, then Submit. Signed out, it says so.
Future<void> showPollVoteSheet(
  BuildContext context,
  LiveElement e,
  ElementInteraction i,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: NileColors.bgSurface,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
  ),
  builder: (_) => PollVoteSheet(e: e, interaction: i),
);

class PollVoteSheet extends StatefulWidget {
  const PollVoteSheet({super.key, required this.e, required this.interaction});

  final LiveElement e;
  final ElementInteraction interaction;

  @override
  State<PollVoteSheet> createState() => _PollVoteSheetState();
}

class _PollVoteSheetState extends State<PollVoteSheet> {
  late final Set<String> _picked = {...widget.interaction.mine};

  void _vote(List<String> picks) {
    widget.interaction.onTap?.call(picks);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = _config(widget.e);
    final i = widget.interaction;
    final mine = i.mine.toSet();
    final several = c.type == PollType.several;
    final over = _picked.length > c.pickLimit;
    final Widget answers;
    if (i.needsSignIn || i.onTap == null) {
      answers = Padding(
        padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
        child: Text(
          i.needsSignIn ? 'Sign in to vote' : 'Voting has closed',
          textAlign: TextAlign.center,
          style: NileTextStyles.bodyLg().copyWith(
            color: NileColors.txtSecondary,
          ),
        ),
      );
    } else if (c.type == PollType.rating) {
      final given = int.tryParse(mine.firstOrNull ?? '') ?? 0;
      answers = Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (var n = 1; n <= 5; n++)
            IconButton(
              tooltip: '$n star${n == 1 ? '' : 's'}',
              iconSize: 44,
              onPressed: () => _vote(['$n']),
              icon: Icon(
                n <= given ? Icons.star_rounded : Icons.star_outline_rounded,
                color: n <= given ? NileColors.volt : NileColors.txtSecondary,
              ),
            ),
        ],
      );
    } else {
      answers = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final a in c.items) ...[
            _SheetAnswer(
              text: a.text,
              selected: several ? _picked.contains(a.id) : mine.contains(a.id),
              check: several,
              onTap: several
                  ? () => setState(
                      () => _picked.contains(a.id)
                          ? _picked.remove(a.id)
                          : _picked.add(a.id),
                    )
                  : () => _vote([a.id]),
            ),
            const SizedBox(height: NileSpacing.s8),
          ],
          if (several) ...[
            const SizedBox(height: NileSpacing.s4),
            FilledButton(
              onPressed: _picked.isEmpty || over || _sameSet(_picked, mine)
                  ? null
                  : () => _vote([
                      for (final a in c.items)
                        if (_picked.contains(a.id)) a.id,
                    ]),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                backgroundColor: NileColors.volt,
                foregroundColor: NileColors.onVolt,
              ),
              child: Text(over ? 'Pick up to ${c.pickLimit}' : 'Submit'),
            ),
          ],
        ],
      );
    }
    return SafeArea(
      child: NileMaxWidth(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            NileSpacing.s24,
            NileSpacing.s16,
            NileSpacing.s24,
            NileSpacing.s24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(c.question, style: NileTextStyles.headingMd()),
              const SizedBox(height: NileSpacing.s4),
              Text(
                [
                  if (several)
                    c.maxPicks == null
                        ? 'Pick any number'
                        : 'Pick up to ${c.pickLimit}',
                  if (i.voted) 'You can change your vote until it closes',
                ].join(' · '),
                style: NileTextStyles.caption().copyWith(
                  color: NileColors.txtTertiary,
                ),
              ),
              const SizedBox(height: NileSpacing.s16),
              answers,
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetAnswer extends StatelessWidget {
  const _SheetAnswer({
    required this.text,
    required this.selected,
    required this.check,
    required this.onTap,
  });

  final String text;
  final bool selected;
  final bool check;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onTap,
    style: OutlinedButton.styleFrom(
      minimumSize: const Size.fromHeight(56),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16),
      backgroundColor: selected
          ? NileColors.volt.withValues(alpha: 0.15)
          : null,
      side: BorderSide(
        color: selected ? NileColors.volt : NileColors.border,
        width: selected ? 2 : 1,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NileRadius.md),
      ),
    ),
    child: Row(
      children: [
        if (check) ...[
          Icon(
            selected ? Icons.check_box : Icons.check_box_outline_blank,
            color: selected ? NileColors.volt : NileColors.txtSecondary,
          ),
          const SizedBox(width: NileSpacing.s12),
        ],
        Expanded(
          child: Text(
            text,
            style: NileTextStyles.bodyLg().copyWith(
              color: NileColors.txtPrimary,
            ),
          ),
        ),
        if (selected && !check)
          Icon(Icons.check_circle, color: NileColors.volt),
      ],
    ),
  );
}

/// "Poll is live": for a viewer watching an angle where an open poll isn't on
/// screen. Tapping it opens the vote sheet; ✕ hides it for that poll.
class PollLivePill extends StatelessWidget {
  const PollLivePill({
    super.key,
    required this.e,
    required this.onVote,
    required this.onDismiss,
  });

  final LiveElement e;
  final VoidCallback onVote;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Material(
    color: NileColors.volt,
    borderRadius: BorderRadius.circular(NileRadius.pill),
    child: InkWell(
      borderRadius: BorderRadius.circular(NileRadius.pill),
      onTap: onVote,
      child: Padding(
        padding: const EdgeInsets.only(left: NileSpacing.s12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.how_to_vote, size: 18, color: NileColors.onVolt),
            const SizedBox(width: NileSpacing.s6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                'Poll is live',
                overflow: TextOverflow.ellipsis,
                style: NileTextStyles.labelMd().copyWith(
                  color: NileColors.onVolt,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Hide',
              visualDensity: VisualDensity.compact,
              onPressed: onDismiss,
              icon: const Icon(Icons.close, size: 16, color: NileColors.onVolt),
            ),
          ],
        ),
      ),
    ),
  );
}

// ── Studio: live controls ────────────────────────────────────────────────────

class _PollControls extends StatelessWidget {
  const _PollControls({required this.e, required this.act, this.tally});

  final LiveElement e;
  final ElementAct act;
  final ElementTally? tally;

  void _run(ElementChange c) => act(c.change, clockOps: c.clockOps, ops: c.ops);

  Future<void> _confirmReset(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text('Reset this poll?', style: NileTextStyles.headingMd()),
        content: Text(
          'Every vote is cleared and it closes, ready to run again.',
          style: NileTextStyles.bodyMd(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Reset', style: TextStyle(color: NileColors.error)),
          ),
        ],
      ),
    );
    if (ok == true) _run(_reset(e));
  }

  @override
  Widget build(BuildContext context) {
    final c = _config(e), s = _state(e);
    final results = PollResults(c, tally ?? ElementTally.empty);
    final dim = NileTextStyles.caption().copyWith(
      color: NileColors.txtTertiary,
    );
    return Ticking(
      running: s.open && s.closesAt != null,
      builder: (context) {
        final now = ServerClock.now();
        final open = s.openAt(now);
        final left = s.secondsLeft(now);
        final started = s.open || !results.isEmpty;
        final hidden = c.results == PollResultsMode.reveal && !s.revealed;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: NileSpacing.s8,
              runSpacing: NileSpacing.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton(
                  onPressed: () => _run(pollToggleOpen(e)),
                  style: FilledButton.styleFrom(
                    backgroundColor: open ? NileColors.error : NileColors.volt,
                    foregroundColor: open ? Colors.white : NileColors.onVolt,
                  ),
                  child: Text(
                    open
                        ? 'Close  (O)'
                        : started
                        ? 'Reopen  (O)'
                        : 'Open  (O)',
                  ),
                ),
                if (open && left != null) ...[
                  Text(
                    '${formatClock(left * 1000)} left',
                    style: NileTextStyles.labelLg().copyWith(
                      color: NileColors.volt,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  TextButton(
                    onPressed: () => _run(_cancelTimer(e)),
                    child: const Text('Stop timer'),
                  ),
                ] else
                  PopupMenuButton<int>(
                    tooltip: 'Start a countdown (T)',
                    color: NileColors.bgRaised,
                    onSelected: (sec) => _run(pollStartTimer(e, sec)),
                    itemBuilder: (_) => [
                      for (final sec in {?c.timerSec, ..._timerChoices})
                        PopupMenuItem(
                          value: sec,
                          child: Text(
                            sec == c.timerSec
                                ? '${_timerLabel(sec)} (default)'
                                : _timerLabel(sec),
                          ),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(NileSpacing.s8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.timer_outlined,
                            size: 18,
                            color: NileColors.volt,
                          ),
                          const SizedBox(width: NileSpacing.s4),
                          Text('Timer', style: NileTextStyles.labelMd()),
                        ],
                      ),
                    ),
                  ),
                _RevealButton(
                  revealed: s.revealed || _alwaysShown(e),
                  fixed: _alwaysShown(e),
                  onPressed: () => _run(pollReveal(e)),
                ),
                if (started)
                  TextButton(
                    onPressed: () => _confirmReset(context),
                    child: const Text('Reset'),
                  ),
              ],
            ),
            const SizedBox(height: NileSpacing.s8),
            Text(
              [
                results.votesLabel,
                if (results.average case final avg?)
                  '★ ${avg.toStringAsFixed(1)} average',
                if (hidden) 'hidden from viewers until you reveal',
              ].join(' · '),
              style: NileTextStyles.labelMd(),
            ),
            for (final a in c.items)
              Padding(
                padding: const EdgeInsets.only(top: NileSpacing.s4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        a.text,
                        overflow: TextOverflow.ellipsis,
                        style: NileTextStyles.bodySm(),
                      ),
                    ),
                    Text(
                      '${results.count(a.id)} · ${results.percent(a.id)}%',
                      style: NileTextStyles.bodySm().copyWith(
                        color: NileColors.txtSecondary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            if (c.type == PollType.several)
              Padding(
                padding: const EdgeInsets.only(top: NileSpacing.s4),
                child: Text(
                  'Shares are of people who voted; each can pick '
                  '${c.maxPicks == null ? 'any number' : 'up to ${c.pickLimit}'}.',
                  style: dim,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Reveal, always in the row: outlined while viewers can't all see the
/// totals, filled volt with a tick once they can. Live polls show it filled
/// and fixed — their totals are never hidden.
class _RevealButton extends StatelessWidget {
  const _RevealButton({
    required this.revealed,
    required this.fixed,
    required this.onPressed,
  });

  final bool revealed;
  final bool fixed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (!revealed) {
      return Tooltip(
        message: 'Show the results to every viewer',
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: const Icon(Icons.visibility_outlined, size: 18),
          label: const Text('Reveal  (V)'),
        ),
      );
    }
    return Tooltip(
      message: fixed
          ? 'Live results: viewers always see them'
          : 'Viewers see the results. Press to hide them again',
      child: FilledButton.icon(
        onPressed: fixed ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: NileColors.volt,
          foregroundColor: NileColors.onVolt,
          disabledBackgroundColor: NileColors.volt.withValues(alpha: 0.5),
          disabledForegroundColor: NileColors.onVolt,
        ),
        icon: const Icon(Icons.check, size: 18),
        label: const Text('Revealed'),
      ),
    );
  }
}

const _timerChoices = [30, 60, 120, 300];

String _timerLabel(int sec) => sec < 60
    ? '$sec s'
    : sec % 60 == 0
    ? '${sec ~/ 60} min'
    : formatClock(sec * 1000);

// ── Studio: the settings ─────────────────────────────────────────────────────

class _PollEditor extends StatefulWidget {
  const _PollEditor({
    required this.config,
    required this.onChanged,
    required this.locked,
  });

  final Map<String, dynamic> config;
  final ValueChanged<Map<String, dynamic>> onChanged;

  /// Open or holding votes: wording only.
  final bool locked;

  @override
  State<_PollEditor> createState() => _PollEditorState();
}

class _PollEditorState extends State<_PollEditor> {
  late PollConfig _c = PollConfig.fromJson(widget.config);
  late final _question = TextEditingController(text: _c.question);
  final Map<String, TextEditingController> _answers = {};
  late final _customTimer = TextEditingController(
    text: _c.timerSec != null && !_timerChoices.contains(_c.timerSec)
        ? '${_c.timerSec}'
        : '',
  );
  late bool _custom = _customTimer.text.isNotEmpty;

  TextEditingController _answer(PollAnswer a) =>
      _answers.putIfAbsent(a.id, () => TextEditingController(text: a.text));

  @override
  void dispose() {
    _question.dispose();
    _customTimer.dispose();
    for (final c in _answers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _set(PollConfig c) {
    setState(() => _c = c);
    widget.onChanged(c.toJson());
  }

  void _move(int from, int to) {
    final list = [..._c.answers];
    list.insert(to, list.removeAt(from));
    _set(_c.copyWith(answers: list));
  }

  @override
  Widget build(BuildContext context) {
    final locked = widget.locked;
    final dim = NileTextStyles.caption().copyWith(
      color: NileColors.txtTertiary,
    );
    final warning = _c.error;
    final timerValue = _custom ? -1 : _c.timerSec ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (locked)
          Padding(
            padding: const EdgeInsets.only(bottom: NileSpacing.s8),
            child: Text(
              'This poll is open or has votes, so only its wording can change. '
              'Close and reset it to change the answers.',
              style: NileTextStyles.bodySm().copyWith(
                color: NileColors.warning,
              ),
            ),
          ),
        DropdownButtonFormField<PollType>(
          initialValue: _c.type,
          dropdownColor: NileColors.bgRaised,
          decoration: const InputDecoration(labelText: 'Type'),
          items: [
            for (final t in PollType.values)
              DropdownMenuItem(value: t, child: Text(t.label)),
          ],
          onChanged: locked
              ? null
              : (t) {
                  if (t == null) return;
                  var next = _c.copyWith(type: t);
                  // Own answers keep what was typed; start with two blanks.
                  if (next.ownAnswers &&
                      next.answers.length < PollConfig.minAnswers) {
                    next = next.copyWith(
                      answers: [
                        ...next.answers,
                        for (
                          var n = next.answers.length;
                          n < PollConfig.minAnswers;
                          n++
                        )
                          PollAnswer('a${n + 1}', ''),
                      ],
                    );
                  }
                  _set(next);
                },
        ),
        const SizedBox(height: NileSpacing.s8),
        TextField(
          controller: _question,
          maxLength: PollConfig.maxQuestion,
          decoration: const InputDecoration(labelText: 'Question'),
          onChanged: (v) => _set(_c.copyWith(question: v)),
        ),
        if (_c.ownAnswers) ...[
          Text('Answers', style: NileTextStyles.labelSm()),
          for (final (n, a) in _c.answers.indexed)
            Row(
              key: ValueKey('answer:${a.id}'),
              children: [
                Expanded(
                  child: TextField(
                    controller: _answer(a),
                    maxLength: PollConfig.maxAnswer,
                    decoration: InputDecoration(
                      hintText: 'Answer ${n + 1}',
                      counterText: '',
                    ),
                    onChanged: (v) => _set(
                      _c.copyWith(
                        answers: [
                          for (final x in _c.answers)
                            x.id == a.id ? PollAnswer(x.id, v) : x,
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Move up',
                  onPressed: locked || n == 0 ? null : () => _move(n, n - 1),
                  icon: const Icon(Icons.arrow_upward, size: 18),
                ),
                IconButton(
                  tooltip: 'Move down',
                  onPressed: locked || n == _c.answers.length - 1
                      ? null
                      : () => _move(n, n + 1),
                  icon: const Icon(Icons.arrow_downward, size: 18),
                ),
                IconButton(
                  tooltip: 'Remove',
                  onPressed:
                      locked || _c.answers.length <= PollConfig.minAnswers
                      ? null
                      : () => _set(
                          _c.copyWith(
                            answers: [
                              for (final x in _c.answers)
                                if (x.id != a.id) x,
                            ],
                            clearMaxPicks:
                                (_c.maxPicks ?? 0) >= _c.answers.length,
                          ),
                        ),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          if (!locked && _c.answers.length < PollConfig.maxAnswers)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _set(
                  _c.copyWith(
                    answers: [..._c.answers, PollAnswer(_c.nextAnswerId(), '')],
                  ),
                ),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add answer'),
              ),
            ),
        ],
        if (_c.type == PollType.several)
          Row(
            children: [
              Expanded(
                child: Text(
                  'Each viewer can pick',
                  style: NileTextStyles.bodyMd(),
                ),
              ),
              DropdownButton<int>(
                value: _c.maxPicks ?? 0,
                dropdownColor: NileColors.bgRaised,
                items: [
                  const DropdownMenuItem(value: 0, child: Text('Any number')),
                  for (var n = 1; n <= _c.answers.length; n++)
                    DropdownMenuItem(value: n, child: Text('Up to $n')),
                ],
                onChanged: (v) => _set(
                  v == null || v == 0
                      ? _c.copyWith(clearMaxPicks: true)
                      : _c.copyWith(maxPicks: v),
                ),
              ),
            ],
          ),
        const SizedBox(height: NileSpacing.s8),
        DropdownButtonFormField<PollResultsMode>(
          initialValue: _c.results,
          dropdownColor: NileColors.bgRaised,
          decoration: const InputDecoration(labelText: 'Results'),
          items: [
            for (final m in PollResultsMode.values)
              DropdownMenuItem(value: m, child: Text(m.label)),
          ],
          onChanged: (m) {
            if (m != null) _set(_c.copyWith(results: m));
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: NileSpacing.s4),
          child: Text(_c.results.hint, style: dim),
        ),
        const SizedBox(height: NileSpacing.s8),
        Row(
          children: [
            Expanded(
              child: Text(
                'Countdown when it opens',
                style: NileTextStyles.bodyMd(),
              ),
            ),
            DropdownButton<int>(
              value: timerValue,
              dropdownColor: NileColors.bgRaised,
              items: [
                const DropdownMenuItem(value: 0, child: Text('None')),
                for (final sec in _timerChoices)
                  DropdownMenuItem(value: sec, child: Text(_timerLabel(sec))),
                const DropdownMenuItem(value: -1, child: Text('Custom')),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _custom = v == -1);
                if (v == -1) return;
                _set(
                  v == 0
                      ? _c.copyWith(clearTimer: true)
                      : _c.copyWith(timerSec: v),
                );
              },
            ),
          ],
        ),
        if (_custom)
          TextField(
            controller: _customTimer,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Seconds (10 to 1800)',
            ),
            onChanged: (v) {
              final sec = int.tryParse(v);
              _set(
                sec == null
                    ? _c.copyWith(clearTimer: true)
                    : _c.copyWith(timerSec: sec),
              );
            },
          ),
        if (warning != null)
          Padding(
            padding: const EdgeInsets.only(top: NileSpacing.s8),
            child: Text(
              warning,
              style: NileTextStyles.bodySm().copyWith(
                color: NileColors.warning,
              ),
            ),
          ),
      ],
    );
  }
}
