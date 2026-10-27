import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/element_hud.dart';
import '../../services/live_elements.dart';
import '../../services/overlay_clock.dart';
import '../../services/server_clock.dart';
import '../../theme.dart';
import '../overlay_look.dart';
import 'poll.dart';

/// One change to a live element: its new values, clock commands, and timer
/// or reset commands (polls).
typedef ElementChange = ({
  LiveElement Function(LiveElement current) change,
  Map<String, ClockOp> clockOps,
  ElementOps ops,
});

/// Applies an [ElementChange] (the Elements panel pushes it).
typedef ElementAct =
    void Function(
      LiveElement Function(LiveElement current) change, {
      Map<String, ClockOp> clockOps,
      ElementOps ops,
    });

/// What a viewer (or the Studio) can do with an element on screen: their own
/// vote, the totals, and — viewers only — voting (phase 5).
@immutable
class ElementInteraction {
  const ElementInteraction({
    this.mine = const [],
    this.tally,
    this.onTap,
    this.audience = ElementAudience.viewer,
    this.needsSignIn = false,
  });

  /// The choices this viewer's vote holds. Empty = hasn't voted.
  final List<String> mine;
  final ElementTally? tally;

  /// Votes these picks (replacing any earlier vote). Null = nothing is
  /// tappable here (Studio, replays, under a slate, closed).
  final ValueChanged<List<String>>? onTap;

  /// Who is looking — decides whether a poll's totals show.
  final ElementAudience audience;

  /// A signed-out viewer: tapping says "Sign in to vote".
  final bool needsSignIn;

  bool get voted => mine.isNotEmpty;

  /// Something here reacts to a tap.
  bool get tappable => onTap != null || needsSignIn;

  /// The same, with nothing tappable.
  ElementInteraction get readOnly =>
      ElementInteraction(mine: mine, tally: tally, audience: audience);
}

/// A key that works while the Elements panel has focus.
@immutable
class ElementShortcut {
  const ElementShortcut(this.keys, this.label, this.run);

  final List<SingleActivator> keys;

  /// "+1", "Start/stop clock" — shown in the panel.
  final String label;
  final ElementChange Function(LiveElement e) run;
}

/// Everything the Studio and viewers need for one kind (studio live elements,
/// phase 3). Adding a kind = an [ElementKindSpec] in live_elements.dart, its
/// server rule, and one of these.
@immutable
class ElementKindUi {
  const ElementKindUi({
    required this.render,
    required this.editor,
    this.controls,
    this.hud,
    this.hudAct,
    this.shortcuts = const [],
  });

  /// Draws it over the video; [u] is 1% of the picture's width. [full] = on
  /// its own, filling the picture. [interaction] carries votes and taps.
  final Widget Function(
    LiveElement e,
    double u, {
    required bool full,
    ElementInteraction? interaction,
  })
  render;

  /// Edits a library item's settings. [locked] = it is running with votes
  /// (or open), so only its wording may change.
  final Widget Function(
    Map<String, dynamic> config,
    ValueChanged<Map<String, dynamic>> onChanged, {
    required bool locked,
  })
  editor;

  /// The live controls in the Elements panel; [tally] = its totals, if any.
  /// Null = the panel draws the [hud] items instead (plugin kinds).
  final Widget Function(LiveElement e, ElementAct act, ElementTally? tally)?
  controls;

  /// Its HUD card's quick controls, as data (docs/plans/studio-element-hud.md);
  /// [now] is server ms. Null = no card controls.
  final List<HudItem> Function(LiveElement e, ElementTally? tally, int now)?
  hud;

  /// Runs a HUD action by id, with a timer's seconds or an input's value.
  /// Null = an action this kind doesn't know.
  final ElementChange? Function(LiveElement e, String action, Object? value)?
  hudAct;
  final List<ElementShortcut> shortcuts;
}

final Map<String, ElementKindUi> elementKindUis = {
  ElementKinds.counter.wire: _counterUi,
  ElementKinds.poll.wire: pollUi,
};

/// Draws [e] (nothing for a kind this build has no drawing for).
Widget buildElement(
  LiveElement e,
  double u, {
  bool full = false,
  ElementInteraction? interaction,
}) =>
    elementKindUis[e.kind]?.render(
      e,
      u,
      full: full,
      interaction: interaction,
    ) ??
    const SizedBox.shrink();

// ── Counter (hidden test kind) ───────────────────────────────────────────────

int _value(LiveElement e) => (e.state['value'] as num?)?.toInt() ?? 0;
int _step(LiveElement e) => (e.config['step'] as num?)?.toInt() ?? 1;

ElementChange _bump(LiveElement e, int by) => (
  change: (cur) => cur.copyWith(
    state: {...cur.state, 'value': (_value(cur) + by).clamp(-99999, 99999)},
  ),
  clockOps: const {},
  ops: ElementOps.none,
);

ElementChange _toggleTaps(LiveElement e) => (
  change: (cur) {
    final next = {...cur.state};
    cur.open ? next.remove('open') : next['open'] = true;
    return cur.copyWith(state: next);
  },
  clockOps: const {},
  ops: ElementOps.none,
);

ElementChange _toggleClock(LiveElement e) => (
  change: (cur) => cur,
  clockOps: {'main': e.clock('main').running ? ClockOp.pause : ClockOp.start},
  ops: ElementOps.none,
);

/// The test counter's card uses every HUD block: buttons, a readout, an
/// input and a clock.
List<HudItem> _counterHud(LiveElement e, ElementTally? tally, int now) {
  final step = _step(e);
  final clock = e.clock('main');
  return [
    HudButton(action: 'down', label: '−$step'),
    HudButton(action: 'up', label: '+$step', style: HudStyle.primary),
    const HudInput(
      action: 'set',
      label: 'Set to',
      number: true,
      min: -99999,
      max: 99999,
    ),
    HudTimer(
      start: 'clock',
      stop: 'clock',
      running: clock.running,
      ms: clock.valueAt(now),
      startLabel: 'Start clock',
      stopLabel: 'Pause',
    ),
    if (e.choices.isNotEmpty)
      HudButton(action: 'taps', label: 'Taps open', active: e.open),
    HudReadout('Value ${_value(e)}', strong: true),
    if (e.choices.isNotEmpty)
      HudReadout(
        [
          for (final c in e.choices)
            '${c == 'up' ? '▲' : '▼'} ${tally?[c] ?? 0}',
        ].join('  '),
      ),
  ];
}

ElementChange? _counterHudAct(LiveElement e, String action, Object? value) =>
    switch (action) {
      'down' => _bump(e, -_step(e)),
      'up' => _bump(e, _step(e)),
      'set' when value is num => (
        change: (cur) => cur.copyWith(
          state: {...cur.state, 'value': value.toInt().clamp(-99999, 99999)},
        ),
        clockOps: const {},
        ops: ElementOps.none,
      ),
      'clock' => _toggleClock(e),
      'taps' => _toggleTaps(e),
      _ => null,
    };

final _counterUi = ElementKindUi(
  render: (e, u, {required full, interaction}) =>
      _CounterView(e: e, u: u, full: full, interaction: interaction),
  editor: (config, onChanged, {required locked}) =>
      _CounterEditor(config: config, onChanged: onChanged),
  controls: (e, act, tally) => _CounterControls(e: e, act: act, tally: tally),
  hud: _counterHud,
  hudAct: _counterHudAct,
  shortcuts: [
    ElementShortcut(
      const [
        SingleActivator(LogicalKeyboardKey.equal),
        SingleActivator(LogicalKeyboardKey.numpadAdd),
      ],
      '+ step',
      (e) => _bump(e, _step(e)),
    ),
    ElementShortcut(
      const [
        SingleActivator(LogicalKeyboardKey.minus),
        SingleActivator(LogicalKeyboardKey.numpadSubtract),
      ],
      '− step',
      (e) => _bump(e, -_step(e)),
    ),
    ElementShortcut(
      const [SingleActivator(LogicalKeyboardKey.space)],
      'Start / pause clock',
      _toggleClock,
    ),
  ],
);

/// Rebuilds four times a second while [running] — for anything showing a
/// clock or countdown.
class Ticking extends StatefulWidget {
  const Ticking({super.key, required this.running, required this.builder});
  final bool running;
  final WidgetBuilder builder;

  @override
  State<Ticking> createState() => _TickingState();
}

class _TickingState extends State<Ticking> {
  Timer? _t;

  void _arm() {
    _t?.cancel();
    _t = widget.running
        ? Timer.periodic(const Duration(milliseconds: 250), (_) {
            if (mounted) setState(() {});
          })
        : null;
  }

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(Ticking old) {
    super.didUpdateWidget(old);
    if (old.running != widget.running) _arm();
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

class _CounterView extends StatelessWidget {
  const _CounterView({
    required this.e,
    required this.u,
    required this.full,
    this.interaction,
  });
  final LiveElement e;
  final double u;
  final bool full;
  final ElementInteraction? interaction;

  @override
  Widget build(BuildContext context) {
    final look = OverlayLook(e.style);
    final clock = e.clock('main');
    final showClock = clock.running || clock.elapsedMs > 0;
    final s = full ? 2.5 : 1.0;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          (e.config['label'] as String?) ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: look.font(
            NileTextStyles.labelLg().copyWith(
              fontSize: u * 1.8 * s,
              color: look.textDim,
              height: 1.2,
            ),
          ),
        ),
        Text(
          '${_value(e)}',
          style: look.font(
            NileTextStyles.headingLg().copyWith(
              fontSize: u * 5 * s,
              color: look.text,
              height: 1.1,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        if (showClock)
          Ticking(
            running: clock.running,
            builder: (context) => Text(
              formatClock(clock.valueAt(OverlayClock.nowOf(context))),
              style: look.font(
                NileTextStyles.labelLg().copyWith(
                  fontSize: u * 2.2 * s,
                  color: look.accent,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        if (e.choices.isNotEmpty) ...[
          SizedBox(height: u * 0.8 * s),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, c) in e.choices.indexed) ...[
                if (i > 0) SizedBox(width: u * 0.8 * s),
                _TapChip(
                  icon: c == 'up' ? Icons.arrow_upward : Icons.arrow_downward,
                  count: interaction?.tally?[c],
                  mine: interaction?.mine.contains(c) ?? false,
                  look: look,
                  u: u * s,
                  onTap: e.openChoices.contains(c)
                      ? interaction?.onTap == null
                            ? null
                            : () => interaction!.onTap!([c])
                      : null,
                ),
              ],
            ],
          ),
        ],
      ],
    );
    if (full) {
      return Container(
        color: look.page,
        alignment: Alignment.center,
        child: body,
      );
    }
    return Container(
      constraints: BoxConstraints(minWidth: u * 12, maxWidth: u * 30),
      padding: EdgeInsets.symmetric(horizontal: u * 1.6, vertical: u * 1),
      decoration: BoxDecoration(
        color: look.panel.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(u * 1.2),
        border: Border(
          top: BorderSide(color: look.accent, width: u * 0.5),
        ),
      ),
      child: body,
    );
  }
}

/// One tappable choice: an icon, its count, and a ring when it is yours.
class _TapChip extends StatelessWidget {
  const _TapChip({
    required this.icon,
    required this.count,
    required this.mine,
    required this.look,
    required this.u,
    this.onTap,
  });

  final IconData icon;
  final int? count;
  final bool mine;
  final OverlayLook look;
  final double u;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: EdgeInsets.symmetric(horizontal: u * 1.2, vertical: u * 0.5),
      decoration: BoxDecoration(
        color: mine ? look.accent : look.text.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(u * 3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: u * 2, color: mine ? look.onAccent : look.text),
          if (count != null) ...[
            SizedBox(width: u * 0.5),
            Text(
              '$count',
              style: look.font(
                NileTextStyles.labelLg().copyWith(
                  fontSize: u * 1.8,
                  color: mine ? look.onAccent : look.text,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return chip;
    return Semantics(
      button: true,
      selected: mine,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: chip,
        ),
      ),
    );
  }
}

class _CounterEditor extends StatefulWidget {
  const _CounterEditor({required this.config, required this.onChanged});
  final Map<String, dynamic> config;
  final ValueChanged<Map<String, dynamic>> onChanged;

  @override
  State<_CounterEditor> createState() => _CounterEditorState();
}

class _CounterEditorState extends State<_CounterEditor> {
  late final _label = TextEditingController(
    text: widget.config['label'] as String? ?? '',
  );

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final step = (widget.config['step'] as num?)?.toInt() ?? 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _label,
          maxLength: 40,
          decoration: const InputDecoration(labelText: 'Label'),
          onChanged: (v) => widget.onChanged({...widget.config, 'label': v}),
        ),
        Row(
          children: [
            Text('Each press adds', style: NileTextStyles.bodyMd()),
            const Spacer(),
            DropdownButton<int>(
              value: const [1, 2, 3, 5, 10].contains(step) ? step : 1,
              dropdownColor: NileColors.bgRaised,
              items: [
                for (final v in const [1, 2, 3, 5, 10])
                  DropdownMenuItem(value: v, child: Text('$v')),
              ],
              onChanged: (v) =>
                  widget.onChanged({...widget.config, 'step': v ?? 1}),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Viewers can tap ▲ / ▼', style: NileTextStyles.bodyMd()),
          subtitle: Text(
            'Open taps from the live controls; one vote each, changeable '
            'until you close them.',
            style: NileTextStyles.caption().copyWith(
              color: NileColors.txtTertiary,
            ),
          ),
          value: widget.config['taps'] == true,
          activeThumbColor: NileColors.volt,
          onChanged: (v) {
            final next = {...widget.config};
            v ? next['taps'] = true : next.remove('taps');
            widget.onChanged(next);
          },
        ),
      ],
    );
  }
}

class _CounterControls extends StatelessWidget {
  const _CounterControls({required this.e, required this.act, this.tally});
  final LiveElement e;
  final ElementAct act;
  final ElementTally? tally;

  void _run(ElementChange c) => act(c.change, clockOps: c.clockOps);

  @override
  Widget build(BuildContext context) {
    final step = _step(e);
    final clock = e.clock('main');
    final value = NileTextStyles.headingMd().copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Wrap(
      spacing: NileSpacing.s8,
      runSpacing: NileSpacing.s8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        IconButton.outlined(
          tooltip: '−$step  ( − )',
          onPressed: () => _run(_bump(e, -step)),
          icon: const Icon(Icons.remove),
        ),
        SizedBox(
          width: 64,
          child: Text(
            '${_value(e)}',
            textAlign: TextAlign.center,
            style: value,
          ),
        ),
        IconButton.outlined(
          tooltip: '+$step  ( + )',
          onPressed: () => _run(_bump(e, step)),
          icon: const Icon(Icons.add),
        ),
        TextButton(
          onPressed: () =>
              act((cur) => cur.copyWith(state: {...cur.state, 'value': 0})),
          child: const Text('Reset'),
        ),
        const SizedBox(width: NileSpacing.s8),
        Ticking(
          running: clock.running,
          builder: (_) =>
              Text(formatClock(clock.valueAt(ServerClock.now())), style: value),
        ),
        IconButton(
          tooltip: clock.running
              ? 'Pause clock (space)'
              : 'Start clock (space)',
          onPressed: () => _run(_toggleClock(e)),
          icon: Icon(clock.running ? Icons.pause : Icons.play_arrow),
          color: NileColors.volt,
        ),
        IconButton(
          tooltip: 'Reset clock',
          onPressed: () => act((cur) => cur, clockOps: {'main': ClockOp.reset}),
          icon: const Icon(Icons.restart_alt),
        ),
        if (e.choices.isNotEmpty) ...[
          const SizedBox(width: NileSpacing.s8),
          OutlinedButton(
            onPressed: () => act(_toggleTaps(e).change),
            child: Text(e.open ? 'Close taps' : 'Open taps'),
          ),
          Text(
            [
              for (final c in e.choices)
                '${c == 'up' ? '▲' : '▼'} ${tally?[c] ?? 0}',
            ].join('   '),
            style: value.copyWith(fontSize: NileTextStyles.bodyMd().fontSize),
          ),
        ],
      ],
    );
  }
}
