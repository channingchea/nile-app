import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/live_elements.dart';
import '../../services/server_clock.dart';
import '../../theme.dart';
import '../overlay_look.dart';

/// One change to a live element: its new values and any clock commands.
typedef ElementChange = ({
  LiveElement Function(LiveElement current) change,
  Map<String, ClockOp> clockOps,
});

/// Applies an [ElementChange] (the Elements panel pushes it).
typedef ElementAct =
    void Function(
      LiveElement Function(LiveElement current) change, {
      Map<String, ClockOp> clockOps,
    });

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
    required this.controls,
    this.shortcuts = const [],
  });

  /// Draws it over the video; [u] is 1% of the picture's width. [full] = on
  /// its own, filling the picture.
  final Widget Function(LiveElement e, double u, {required bool full}) render;

  /// Edits a library item's settings.
  final Widget Function(
    Map<String, dynamic> config,
    ValueChanged<Map<String, dynamic>> onChanged,
  )
  editor;

  /// The live controls in the Elements panel.
  final Widget Function(LiveElement e, ElementAct act) controls;
  final List<ElementShortcut> shortcuts;
}

final Map<String, ElementKindUi> elementKindUis = {
  ElementKinds.counter.wire: _counterUi,
};

/// Draws [e] (nothing for a kind this build has no drawing for).
Widget buildElement(LiveElement e, double u, {bool full = false}) =>
    elementKindUis[e.kind]?.render(e, u, full: full) ?? const SizedBox.shrink();

// ── Counter (hidden test kind) ───────────────────────────────────────────────

int _value(LiveElement e) => (e.state['value'] as num?)?.toInt() ?? 0;
int _step(LiveElement e) => (e.config['step'] as num?)?.toInt() ?? 1;

ElementChange _bump(LiveElement e, int by) => (
  change: (cur) => cur.copyWith(
    state: {...cur.state, 'value': (_value(cur) + by).clamp(-99999, 99999)},
  ),
  clockOps: const {},
);

ElementChange _toggleClock(LiveElement e) => (
  change: (cur) => cur,
  clockOps: {'main': e.clock('main').running ? ClockOp.pause : ClockOp.start},
);

final _counterUi = ElementKindUi(
  render: (e, u, {required full}) => _CounterView(e: e, u: u, full: full),
  editor: (config, onChanged) =>
      _CounterEditor(config: config, onChanged: onChanged),
  controls: (e, act) => _CounterControls(e: e, act: act),
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

/// Rebuilds every [period] while [running] — for anything showing a clock.
class _Ticking extends StatefulWidget {
  const _Ticking({required this.running, required this.builder});
  final bool running;
  final WidgetBuilder builder;

  @override
  State<_Ticking> createState() => _TickingState();
}

class _TickingState extends State<_Ticking> {
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
  void didUpdateWidget(_Ticking old) {
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
  const _CounterView({required this.e, required this.u, required this.full});
  final LiveElement e;
  final double u;
  final bool full;

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
          _Ticking(
            running: clock.running,
            builder: (_) => Text(
              formatClock(clock.valueAt(ServerClock.now())),
              style: look.font(
                NileTextStyles.labelLg().copyWith(
                  fontSize: u * 2.2 * s,
                  color: look.accent,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
      ],
    );
    if (full) {
      return Container(color: look.page, alignment: Alignment.center, child: body);
    }
    return Container(
      constraints: BoxConstraints(minWidth: u * 12, maxWidth: u * 30),
      padding: EdgeInsets.symmetric(horizontal: u * 1.6, vertical: u * 1),
      decoration: BoxDecoration(
        color: look.panel.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(u * 1.2),
        border: Border(top: BorderSide(color: look.accent, width: u * 0.5)),
      ),
      child: body,
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
      ],
    );
  }
}

class _CounterControls extends StatelessWidget {
  const _CounterControls({required this.e, required this.act});
  final LiveElement e;
  final ElementAct act;

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
          child: Text('${_value(e)}', textAlign: TextAlign.center, style: value),
        ),
        IconButton.outlined(
          tooltip: '+$step  ( + )',
          onPressed: () => _run(_bump(e, step)),
          icon: const Icon(Icons.add),
        ),
        TextButton(
          onPressed: () => act(
            (cur) => cur.copyWith(state: {...cur.state, 'value': 0}),
          ),
          child: const Text('Reset'),
        ),
        const SizedBox(width: NileSpacing.s8),
        _Ticking(
          running: clock.running,
          builder: (_) => Text(
            formatClock(clock.valueAt(ServerClock.now())),
            style: value,
          ),
        ),
        IconButton(
          tooltip: clock.running ? 'Pause clock (space)' : 'Start clock (space)',
          onPressed: () => _run(_toggleClock(e)),
          icon: Icon(clock.running ? Icons.pause : Icons.play_arrow),
          color: NileColors.volt,
        ),
        IconButton(
          tooltip: 'Reset clock',
          onPressed: () => act((cur) => cur, clockOps: {'main': ClockOp.reset}),
          icon: const Icon(Icons.restart_alt),
        ),
      ],
    );
  }
}
