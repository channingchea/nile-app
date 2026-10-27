import 'package:flutter/material.dart';

import '../services/analytics.dart';
import '../services/element_hud.dart';
import '../services/live_elements.dart';
import '../services/server_clock.dart';
import '../services/studio_elements_controller.dart';
import '../services/studio_graphics.dart';
import '../theme.dart';
import 'elements/element_kinds.dart';
import 'nile_studio.dart' show NileCuedChip;

/// The Studio's element HUD (docs/plans/studio-element-hud.md): a strip of
/// cards between the monitor and the control bar, one per element that is on
/// air, on its own angle, or cued. Each card is drawn from its kind's HUD
/// items — data, so plugin elements will get the same card.
class ElementHudStrip extends StatelessWidget {
  const ElementHudStrip({
    super.key,
    required this.controller,
    required this.cue,
    required this.cameraSummary,
    required this.onTakeOne,
    required this.onOpenPanel,
  });

  final StudioElementsController controller;
  final ValueNotifier<CueSet> cue;

  /// "All cameras", "Cam 1, Cam 2" for a cued element's targets.
  final String Function(GraphicTargets targets) cameraSummary;

  /// Take just this cued element.
  final Future<void> Function(ElementCue cue) onTakeOne;

  /// The Elements panel, opened on this element.
  final ValueChanged<String> onOpenPanel;

  /// Card height; the strip adds its padding around it.
  static const cardHeight = 120.0;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, cue]),
    builder: (context, _) {
      final c = controller;
      final live = c.liveElements;
      final liveIds = {for (final e in live) e.id};
      final cued = [
        for (final q in cue.value.elements)
          if (!liveIds.contains(q.id)) q,
      ];
      final hidden = <({String id, String name})>[
        for (final e in live)
          if (c.hudHidden(e.id)) (id: e.id, name: e.name),
        for (final q in cued)
          if (c.hudHidden(q.id)) (id: q.id, name: q.name),
      ];
      final cards = <Widget>[
        for (final e in live)
          if (!c.hudHidden(e.id))
            HudCard(
              key: ValueKey('hud-${e.id}'),
              element: e,
              tally: c.tally(e.id),
              onAct: (change, {clockOps = const {}, ops = ElementOps.none}) =>
                  c.update(e.id, change, clockOps: clockOps, ops: ops),
              onAction: (a) => NileAnalytics.capture(
                NileEvent.elementHudAction,
                {'kind': e.kind, 'action': a, 'preview': c.rehearsal},
              ),
              onOpenPanel: () => onOpenPanel(e.id),
              onOffAir: () => _offAir(context, e),
              onHide: () => c.setHudHidden(e.id, true),
            ),
        for (final q in cued)
          if (!c.hudHidden(q.id))
            HudCuedCard(
              key: ValueKey('hud-cue-${q.id}'),
              cue: q,
              cameras: cameraSummary(q.targets),
              onTake: () => onTakeOne(q),
              onRemove: () => cue.value = cue.value.without(q.id),
              onHide: () => c.setHudHidden(q.id, true),
            ),
      ];
      final empty = cards.isEmpty && hidden.isEmpty;
      return AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: Alignment.bottomCenter,
        child: empty
            ? const SizedBox(width: double.infinity)
            : Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: NileSpacing.s16,
                  vertical: NileSpacing.s12,
                ),
                decoration: BoxDecoration(
                  color: NileColors.bgSurface,
                  border: Border.symmetric(
                    horizontal: BorderSide(color: NileColors.border),
                  ),
                ),
                child: SizedBox(
                  height: cardHeight,
                  child: Row(
                    children: [
                      Expanded(
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: cards.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(width: NileSpacing.s12),
                          itemBuilder: (_, i) => cards[i],
                        ),
                      ),
                      if (hidden.isNotEmpty) ...[
                        const SizedBox(width: NileSpacing.s12),
                        _HiddenChip(
                          hidden: hidden,
                          onShow: (id) => c.setHudHidden(id, false),
                          onShowAll: c.showAllHud,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
      );
    },
  );

  /// Off every camera and its angle, with Undo to put it back.
  Future<void> _offAir(BuildContext context, LiveElement e) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final was = (targets: e.targets, angle: e.angle);
    final ok = await controller.takeOffAir(e.id);
    if (!ok || messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            e.choices.isEmpty
                ? '“${e.name}” taken off air.'
                : '“${e.name}” taken off air. Votes kept.',
          ),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => controller.putBack(e.id, was.targets, was.angle),
          ),
        ),
      );
  }
}

/// One live element's card: where it is, its quick controls, and Open in
/// panel / Off air / hide.
class HudCard extends StatelessWidget {
  const HudCard({
    super.key,
    required this.element,
    required this.tally,
    required this.onAct,
    required this.onOpenPanel,
    required this.onOffAir,
    required this.onHide,
    this.onAction,
  });

  final LiveElement element;
  final ElementTally? tally;
  final ElementAct onAct;
  final VoidCallback onOpenPanel;
  final VoidCallback onOffAir;
  final VoidCallback onHide;
  final ValueChanged<String>? onAction;

  @override
  Widget build(BuildContext context) {
    final e = element;
    return _CardFrame(
      live: true,
      header: [
        if (e.onAir)
          _StateChip(label: 'ON AIR', color: NileColors.volt, dot: true),
        if (e.angle) ...[
          if (e.onAir) const SizedBox(width: NileSpacing.s4),
          _StateChip(label: 'ANGLE', color: NileColors.azure),
        ],
        const SizedBox(width: NileSpacing.s8),
        Flexible(child: _CardName(e.name)),
        const SizedBox(width: NileSpacing.s8),
        _CardIcon(
          tooltip: 'Open in Elements panel',
          icon: Icons.open_in_new,
          onPressed: onOpenPanel,
        ),
        TextButton(
          onPressed: onOffAir,
          style: _compactText,
          child: const Text('Off air'),
        ),
        _CardIcon(
          tooltip: 'Hide this card',
          icon: Icons.close,
          onPressed: onHide,
        ),
      ],
      body: ElementHudControls(
        element: e,
        tally: tally,
        act: onAct,
        onAction: onAction,
      ),
    );
  }
}

/// A cued element: dimmed, with Take for just this one.
class HudCuedCard extends StatelessWidget {
  const HudCuedCard({
    super.key,
    required this.cue,
    required this.cameras,
    required this.onTake,
    required this.onRemove,
    required this.onHide,
  });

  final ElementCue cue;
  final String cameras;
  final VoidCallback onTake;
  final VoidCallback onRemove;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) => _CardFrame(
    live: false,
    header: [
      const NileCuedChip(),
      const SizedBox(width: NileSpacing.s8),
      Flexible(child: _CardName(cue.name, dim: true)),
      const SizedBox(width: NileSpacing.s8),
      _CardIcon(
        tooltip: 'Hide this card',
        icon: Icons.close,
        onPressed: onHide,
      ),
    ],
    body: HudItemsView(
      items: [
        const HudButton(action: 'take', label: 'Take', style: HudStyle.primary),
        const HudButton(
          action: 'remove',
          label: 'Remove from cue',
          style: HudStyle.text,
        ),
        HudReadout('Goes on $cameras', tone: HudTone.dim),
      ],
      onAction: (a, _) => a == 'take' ? onTake() : onRemove(),
    ),
  );
}

/// A kind's HUD items, live: rebuilt while one of its timers runs; an action
/// becomes the kind's change and goes to [act]. Also the Elements panel's
/// controls for a kind with none of its own.
class ElementHudControls extends StatelessWidget {
  const ElementHudControls({
    super.key,
    required this.element,
    required this.tally,
    required this.act,
    this.wrap = false,
    this.onAction,
  });

  final LiveElement element;
  final ElementTally? tally;
  final ElementAct act;

  /// Wrap onto more rows (the panel) instead of one row (a card).
  final bool wrap;

  /// Told each action id that ran (analytics).
  final ValueChanged<String>? onAction;

  @override
  Widget build(BuildContext context) {
    final ui = elementKindUis[element.kind];
    final hud = ui?.hud;
    if (ui == null || hud == null) return const SizedBox.shrink();
    List<HudItem> items() => hud(element, tally, ServerClock.now());
    return Ticking(
      running: items().any((i) => i is HudTimer && i.running),
      builder: (_) => HudItemsView(
        items: items(),
        wrap: wrap,
        onAction: (action, value) {
          final c = ui.hudAct?.call(element, action, value);
          if (c == null) return;
          onAction?.call(action);
          act(c.change, clockOps: c.clockOps, ops: c.ops);
        },
      ),
    );
  }
}

/// Draws HUD items: buttons, timers and inputs in a row, readouts on the
/// line below. The one renderer for native and plugin elements alike.
class HudItemsView extends StatelessWidget {
  const HudItemsView({
    super.key,
    required this.items,
    required this.onAction,
    this.wrap = false,
  });

  final List<HudItem> items;
  final void Function(String action, Object? value) onAction;
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final controls = [for (final i in items) ?_control(context, i)];
    final readouts = items.whereType<HudReadout>().toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (controls.isNotEmpty)
          wrap
              ? Wrap(
                  spacing: NileSpacing.s8,
                  runSpacing: NileSpacing.s8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: controls,
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (i, w) in controls.indexed) ...[
                      if (i > 0) const SizedBox(width: NileSpacing.s8),
                      w,
                    ],
                  ],
                ),
        if (readouts.isNotEmpty) ...[
          const SizedBox(height: NileSpacing.s8),
          Text.rich(
            TextSpan(
              children: [
                for (final (i, r) in readouts.indexed) ...[
                  if (i > 0) TextSpan(text: ' · ', style: _readoutStyle()),
                  TextSpan(text: r.text, style: _readoutStyle(r)),
                ],
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }

  static TextStyle _readoutStyle([HudReadout? r]) {
    final base = NileTextStyles.bodySm().copyWith(
      color: NileColors.txtSecondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    if (r == null) return base;
    return base.copyWith(
      color: switch (r.tone) {
        HudTone.accent => NileColors.volt,
        HudTone.dim => NileColors.txtSecondary,
        HudTone.normal => r.strong ? NileColors.txtPrimary : null,
      },
      fontWeight: r.strong ? FontWeight.w600 : null,
    );
  }

  Widget? _control(BuildContext context, HudItem i) => switch (i) {
    HudButton b => _button(context, b),
    HudTimer t => _timer(t),
    HudInput f => _HudInputField(
      key: ValueKey('hud-input-${f.action}'),
      item: f,
      onSubmit: (v) => onAction(f.action, v),
    ),
    HudReadout _ => null,
  };

  Widget _button(BuildContext context, HudButton b) {
    Future<void> run() async {
      if (b.confirm case final q?) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: NileColors.bgSurface,
            content: Text(q, style: NileTextStyles.bodyMd()),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(b.label),
              ),
            ],
          ),
        );
        if (ok != true) return;
      }
      onAction(b.action, null);
    }

    final onPressed = b.enabled ? run : null;
    final icon = _icons[b.icon];
    final label = Text(b.label);
    if (b.active case final on?) {
      if (on) {
        return FilledButton.icon(
          onPressed: onPressed,
          style: _filled(NileColors.volt, NileColors.onVolt),
          icon: Icon(icon ?? Icons.check, size: _iconSize),
          label: label,
        );
      }
      return OutlinedButton.icon(
        onPressed: onPressed,
        style: _outlined,
        icon: Icon(icon ?? Icons.circle_outlined, size: _iconSize),
        label: label,
      );
    }
    final child = icon == null
        ? label
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: _iconSize),
              const SizedBox(width: NileSpacing.s6),
              label,
            ],
          );
    return switch (b.style) {
      HudStyle.primary => FilledButton(
        onPressed: onPressed,
        style: _filled(NileColors.volt, NileColors.onVolt),
        child: child,
      ),
      HudStyle.danger => FilledButton(
        onPressed: onPressed,
        style: _filled(NileColors.error, Colors.white),
        child: child,
      ),
      HudStyle.outlined => OutlinedButton(
        onPressed: onPressed,
        style: _outlined,
        child: child,
      ),
      HudStyle.text => TextButton(
        onPressed: onPressed,
        style: _compactText,
        child: child,
      ),
    };
  }

  Widget _timer(HudTimer t) {
    final reading = t.ms == null
        ? null
        : Text(
            formatClock(t.ms!),
            style: NileTextStyles.labelLg().copyWith(
              color: t.running ? NileColors.volt : NileColors.txtSecondary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          );
    if (t.running) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?reading,
          TextButton(
            onPressed: () => onAction(t.stop ?? t.start, null),
            style: _compactText,
            child: Text(t.stopLabel),
          ),
        ],
      );
    }
    final start = t.presets.isEmpty
        ? TextButton.icon(
            onPressed: () => onAction(t.start, null),
            style: _compactText,
            icon: Icon(
              Icons.play_arrow,
              size: _iconSize,
              color: NileColors.volt,
            ),
            label: Text(t.startLabel),
          )
        : PopupMenuButton<int>(
            tooltip: 'Start a countdown',
            color: NileColors.bgRaised,
            onSelected: (sec) => onAction(t.start, sec),
            itemBuilder: (_) => [
              for (final sec in t.presets)
                PopupMenuItem(
                  value: sec,
                  child: Text(
                    sec == t.defaultSec
                        ? '${_secLabel(sec)} (default)'
                        : _secLabel(sec),
                  ),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: NileSpacing.s8,
                vertical: NileSpacing.s6,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.timer_outlined,
                    size: _iconSize,
                    color: NileColors.volt,
                  ),
                  const SizedBox(width: NileSpacing.s4),
                  Text(t.startLabel, style: NileTextStyles.labelMd()),
                ],
              ),
            ),
          );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (reading != null && (t.ms ?? 0) > 0) ...[
          reading,
          const SizedBox(width: NileSpacing.s4),
        ],
        start,
      ],
    );
  }

  static String _secLabel(int sec) => sec < 60
      ? '$sec s'
      : sec % 60 == 0
      ? '${sec ~/ 60} min'
      : formatClock(sec * 1000);

  /// The HUD's icon set — plugins name one of these.
  static const _icons = <String, IconData>{
    'check': Icons.check,
    'visibility': Icons.visibility_outlined,
    'timer': Icons.timer_outlined,
    'add': Icons.add,
    'remove': Icons.remove,
    'play': Icons.play_arrow,
    'pause': Icons.pause,
    'stop': Icons.stop,
    'next': Icons.skip_next,
    'refresh': Icons.refresh,
    'star': Icons.star_outline,
  };
}

const _iconSize = 16.0;

const _buttonSize = Size(0, NileSpacing.s32);
const _buttonPadding = EdgeInsets.symmetric(horizontal: NileSpacing.s12);

ButtonStyle _filled(Color bg, Color fg) => FilledButton.styleFrom(
  backgroundColor: bg,
  foregroundColor: fg,
  disabledBackgroundColor: bg.withValues(alpha: 0.5),
  disabledForegroundColor: fg,
  minimumSize: _buttonSize,
  padding: _buttonPadding,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.compact,
);

final _outlined = OutlinedButton.styleFrom(
  minimumSize: _buttonSize,
  padding: _buttonPadding,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.compact,
);

final _compactText = TextButton.styleFrom(
  foregroundColor: NileColors.txtSecondary,
  minimumSize: _buttonSize,
  padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s8),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.compact,
);

/// A compact field: sends on Enter or when focus leaves, then lets go of the
/// keyboard so Studio hotkeys work again.
class _HudInputField extends StatefulWidget {
  const _HudInputField({super.key, required this.item, required this.onSubmit});

  final HudInput item;
  final ValueChanged<Object> onSubmit;

  @override
  State<_HudInputField> createState() => _HudInputFieldState();
}

class _HudInputFieldState extends State<_HudInputField> {
  late final _text = TextEditingController(text: widget.item.value);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _send();
    });
  }

  @override
  void didUpdateWidget(_HudInputField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && old.item.value != widget.item.value) {
      _text.text = widget.item.value;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final v = widget.item.parse(_text.text);
    if (v == null || _text.text == widget.item.value) return;
    widget.onSubmit(v);
    _text.text = widget.item.value;
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.item.number ? 88 : 160,
    height: NileSpacing.s32,
    child: TextField(
      controller: _text,
      focusNode: _focus,
      maxLength: widget.item.maxLength,
      keyboardType: widget.item.number
          ? const TextInputType.numberWithOptions(signed: true, decimal: true)
          : TextInputType.text,
      style: NileTextStyles.bodySm(),
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _focus.unfocus(),
      decoration: InputDecoration(
        isDense: true,
        counterText: '',
        hintText: widget.item.label,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: NileSpacing.s8,
          vertical: NileSpacing.s8,
        ),
      ),
    ),
  );
}

// ── Card pieces ──────────────────────────────────────────────────────────────

class _CardFrame extends StatelessWidget {
  const _CardFrame({
    required this.live,
    required this.header,
    required this.body,
  });

  final bool live;
  final List<Widget> header;
  final Widget body;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minWidth: 280, maxWidth: 520),
    child: IntrinsicWidth(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: NileSpacing.s12,
          vertical: NileSpacing.s8,
        ),
        decoration: BoxDecoration(
          color: live ? NileColors.bgRaised : NileColors.bgSurface,
          borderRadius: BorderRadius.circular(NileRadius.md),
          border: Border.all(
            color: live
                ? NileColors.volt.withValues(alpha: 0.35)
                : NileColors.borderStrong,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              height: NileSpacing.s32,
              child: Row(children: header),
            ),
            const SizedBox(height: NileSpacing.s8),
            Align(alignment: Alignment.centerLeft, child: body),
          ],
        ),
      ),
    ),
  );
}

class _CardName extends StatelessWidget {
  const _CardName(this.name, {this.dim = false});
  final String name;
  final bool dim;

  @override
  Widget build(BuildContext context) => Text(
    name,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: NileTextStyles.labelLg().copyWith(
      color: dim ? NileColors.txtSecondary : NileColors.txtPrimary,
    ),
  );
}

class _CardIcon extends StatelessWidget {
  const _CardIcon({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon, size: _iconSize),
    color: NileColors.txtSecondary,
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(
      width: NileSpacing.s32,
      height: NileSpacing.s32,
    ),
  );
}

class _StateChip extends StatelessWidget {
  const _StateChip({
    required this.label,
    required this.color,
    this.dot = false,
  });

  final String label;
  final Color color;
  final bool dot;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: NileSpacing.s8,
      vertical: NileSpacing.s2,
    ),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(NileRadius.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dot) ...[
          Container(
            width: NileSpacing.s6,
            height: NileSpacing.s6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: NileSpacing.s4),
        ],
        Text(
          label,
          style: NileTextStyles.labelSm().copyWith(
            color: color,
            letterSpacing: 0.6,
          ),
        ),
      ],
    ),
  );
}

/// "2 hidden": brings back cards closed with ✕.
class _HiddenChip extends StatelessWidget {
  const _HiddenChip({
    required this.hidden,
    required this.onShow,
    required this.onShowAll,
  });

  final List<({String id, String name})> hidden;
  final ValueChanged<String> onShow;
  final VoidCallback onShowAll;

  static const _all = '*';

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Hidden cards',
    color: NileColors.bgRaised,
    onSelected: (id) => id == _all ? onShowAll() : onShow(id),
    itemBuilder: (_) => [
      for (final h in hidden)
        PopupMenuItem(value: h.id, child: Text('Show “${h.name}”')),
      if (hidden.length > 1)
        const PopupMenuItem(value: _all, child: Text('Show all')),
    ],
    child: Container(
      padding: const EdgeInsets.symmetric(
        horizontal: NileSpacing.s12,
        vertical: NileSpacing.s6,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: NileColors.borderStrong),
        borderRadius: BorderRadius.circular(NileRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.visibility_off_outlined,
            size: _iconSize,
            color: NileColors.txtSecondary,
          ),
          const SizedBox(width: NileSpacing.s6),
          Text(
            '${hidden.length} hidden',
            style: NileTextStyles.labelMd().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
        ],
      ),
    ),
  );
}
