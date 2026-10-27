import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/analytics.dart';
import '../services/brand_kit.dart';
import '../services/elements_service.dart';
import '../services/live_elements.dart';
import '../services/studio_elements_controller.dart';
import '../services/studio_graphics.dart';
import '../theme.dart';
import 'elements/element_kinds.dart';
import 'nile_graphics_layer.dart';
import 'studio_element_hud.dart' show ElementHudControls;
import 'studio_graphics_panel.dart'
    show StudioGraphicsHotkeys, StudioSlotRef, showGraphicTargetsDialog;

/// Where saved elements live: the account's library, or an in-memory one
/// (Studio Preview, tests).
class ElementLibrary {
  const ElementLibrary();

  Future<List<StudioElement>> list() => ElementsService.list();

  Future<StudioElement> create(StudioElement draft) => ElementsService.create(
    kind: draft.kind,
    name: draft.name,
    config: draft.config,
    style: draft.style,
  );

  Future<void> update(StudioElement e) => ElementsService.update(e);
  Future<void> delete(StudioElement e) => ElementsService.delete(e);
}

/// Nothing saved anywhere — for Studio Preview and tests.
class MemoryElementLibrary extends ElementLibrary {
  MemoryElementLibrary([List<StudioElement> items = const []])
    : _items = [...items];

  final List<StudioElement> _items;
  int _next = 0;

  @override
  Future<List<StudioElement>> list() async => [..._items];

  @override
  Future<StudioElement> create(StudioElement draft) async {
    final e = StudioElement(
      id: 'local-${_next++}',
      kind: draft.kind,
      name: draft.name.trim(),
      config: draft.config,
      style: draft.style,
    );
    _items.add(e);
    return e;
  }

  @override
  Future<void> update(StudioElement e) async {
    final i = _items.indexWhere((x) => x.id == e.id);
    if (i >= 0) _items[i] = e;
  }

  @override
  Future<void> delete(StudioElement e) async =>
      _items.removeWhere((x) => x.id == e.id);
}

/// Studio Preview's library: starts from your saved elements (read once,
/// best-effort) and keeps every create, edit and delete in memory — a
/// rehearsal never changes your account.
class PreviewElementLibrary extends MemoryElementLibrary {
  PreviewElementLibrary([this._saved = _account]);

  static Future<List<StudioElement>> _account() =>
      const ElementLibrary().list();

  final Future<List<StudioElement>> Function() _saved;
  Future<void>? _seeded;

  Future<void> _seed() => _seeded ??= _saved().then(
    (items) => _items.insertAll(0, items),
    onError: (_) {}, // Offline or signed out: start empty.
  );

  @override
  Future<List<StudioElement>> list() async {
    await _seed();
    return super.list();
  }

  @override
  Future<StudioElement> create(StudioElement draft) async {
    await _seed();
    return super.create(draft);
  }

  @override
  Future<void> update(StudioElement e) async {
    await _seed();
    return super.update(e);
  }

  @override
  Future<void> delete(StudioElement e) async {
    await _seed();
    return super.delete(e);
  }
}

/// The Studio toolbar's Elements panel (studio live elements, phase 3): every
/// saved element with a "Cameras" button and, for the selected one, its live
/// controls. Picking cameras for an element that is off air cues it — Take
/// (here, Enter, or the Studio's cue bar) puts it on air with any cued
/// graphics. Live controls and re-targeting act at once.
///
/// The selected element's shortcut keys work only while this panel is open;
/// ⌘Z / Ctrl+Z undoes its last change (up to 10).
Future<void> showElementsPanel(
  BuildContext context, {
  required StudioElementsController controller,
  required List<StudioSlotRef> slots,
  required ValueNotifier<CueSet> cue,
  required Future<void> Function() onTake,
  ElementLibrary library = const ElementLibrary(),
  BrandStyle? kit,
  String? initialSelected,
}) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    backgroundColor: NileColors.bgSurface,
    insetPadding: const EdgeInsets.all(NileSpacing.s24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600, maxHeight: 720),
      child: ElementsPanel(
        controller: controller,
        slots: slots,
        cue: cue,
        onTake: onTake,
        library: library,
        kit: kit,
        initialSelected: initialSelected,
      ),
    ),
  ),
);

class ElementsPanel extends StatefulWidget {
  const ElementsPanel({
    super.key,
    required this.controller,
    required this.slots,
    required this.cue,
    required this.onTake,
    this.library = const ElementLibrary(),
    this.kit,
    this.initialSelected,
  });

  /// Opened from a HUD card: that element, expanded.
  final String? initialSelected;

  final StudioElementsController controller;
  final List<StudioSlotRef> slots;
  final ValueNotifier<CueSet> cue;
  final Future<void> Function() onTake;
  final ElementLibrary library;
  final BrandStyle? kit;

  @override
  State<ElementsPanel> createState() => _ElementsPanelState();
}

class _ElementsPanelState extends State<ElementsPanel> {
  bool _loading = true;
  String? _error;
  late String? _selected = widget.initialSelected;
  bool _taking = false;

  StudioElementsController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
    widget.cue.addListener(_changed);
    _load();
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    widget.cue.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final items = await widget.library.list();
      if (!mounted) return;
      _c.setLibrary(items, kit: widget.kit);
      setState(() {
        _loading = false;
        _selected ??= items.firstOrNull?.id;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Couldn’t load your elements. Try again.';
        });
      }
    }
  }

  String _labelOf(String slotId) =>
      widget.slots.where((s) => s.id == slotId).firstOrNull?.label ?? 'Camera';

  List<String> get _order => [for (final s in widget.slots) s.id];

  Future<void> _take() async {
    if (_taking || widget.cue.value.isEmpty) return;
    setState(() => _taking = true);
    await widget.onTake();
    if (mounted) setState(() => _taking = false);
  }

  void _act(
    String id,
    LiveElement Function(LiveElement) change, {
    Map<String, ClockOp> clockOps = const {},
    ElementOps ops = ElementOps.none,
  }) => _c.update(id, change, clockOps: clockOps, ops: ops);

  Future<void> _chooseCameras(StudioElement e) async {
    final live = _c.current(e.id);
    if (live == null) return;
    final current = live.targets;
    final cued = widget.cue.value.elementById(e.id);
    final choice = await showGraphicTargetsDialog(
      context,
      title: e.name,
      slots: widget.slots,
      initial: current.isNone ? cued?.targets ?? current : current,
      autoHideSeconds: 0,
      canRemove: !current.isNone || cued != null,
      confirmLabel: current.isNone ? 'Cue' : 'Put on air',
      showAutoHide: false,
    );
    if (choice == null || !mounted) return;
    if (choice.targets.isNone) {
      widget.cue.value = widget.cue.value.without(e.id);
      if (!current.isNone) await _c.setTargets(e.id, GraphicTargets.none);
      return;
    }
    if (current.isNone) {
      widget.cue.value = widget.cue.value.addingElement(
        ElementCue(id: e.id, name: e.name, targets: choice.targets),
      );
    } else {
      await _c.setTargets(e.id, choice.targets);
    }
  }

  Future<void> _edit({StudioElement? existing, ElementKindSpec? kind}) async {
    final k = kind ?? existing?.spec;
    if (k == null) return;
    final live = existing == null ? null : _c.live(existing.id);
    final result = await showElementEditor(
      context,
      kind: k,
      existing: existing,
      library: widget.library,
      kit: widget.kit,
      // Running with votes: wording only, so the votes still mean the same.
      locked:
          live != null && (live.open || (_c.tally(live.id)?.people ?? 0) > 0),
    );
    if (result == null || !mounted) return;
    if (result.element case final saved?) {
      NileAnalytics.capture(NileEvent.elementSaved, {
        'kind': saved.kind,
        'new': existing == null,
        'preview': _c.rehearsal,
      });
    }
    if (result.deleted && existing != null) {
      widget.cue.value = widget.cue.value.without(existing.id);
      await _c.remove(existing.id);
    }
    await _load();
    if (result.element != null && mounted) {
      setState(() => _selected = result.element!.id);
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent ev) {
    if (ev is! KeyDownEvent && ev is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (StudioGraphicsHotkeys.typing()) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    final key = ev.logicalKey;
    if (ev is KeyDownEvent &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter)) {
      _take();
      return KeyEventResult.handled;
    }
    final id = _selected;
    final e = id == null ? null : _c.current(id);
    if (id == null || e == null) return KeyEventResult.ignored;
    if ((kb.isMetaPressed || kb.isControlPressed) &&
        key == LogicalKeyboardKey.keyZ) {
      _c.undo(id);
      return KeyEventResult.handled;
    }
    for (final sc
        in elementKindUis[e.kind]?.shortcuts ?? const <ElementShortcut>[]) {
      if (sc.keys.any((k) => k.accepts(ev, kb))) {
        final c = sc.run(e);
        _act(id, c.change, clockOps: c.clockOps, ops: c.ops);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final lib = _c.library;
    final cues = widget.cue.value;
    final kinds = ElementKinds.offered();
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NileSpacing.s24,
              NileSpacing.s24,
              NileSpacing.s12,
              NileSpacing.s4,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text('Elements', style: NileTextStyles.headingMd()),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  color: NileColors.txtSecondary,
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s24),
            child: Text(
              'Pick cameras to cue an element; Take puts it on air with any '
              'cued graphics. Live controls change it for every viewer at '
              'once. Keys work on the selected element while this panel is '
              'open.',
              style: NileTextStyles.bodySm().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NileSpacing.s24,
                NileSpacing.s8,
                NileSpacing.s24,
                0,
              ),
              child: Text(
                _error!,
                style: NileTextStyles.bodySm().copyWith(
                  color: NileColors.error,
                ),
              ),
            ),
          const SizedBox(height: NileSpacing.s8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : lib.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(NileSpacing.s24),
                      child: Text(
                        kinds.isEmpty
                            ? 'Scoreboards, polls and more are on the way.'
                            : 'Nothing saved yet — add one with New element.',
                        textAlign: TextAlign.center,
                        style: NileTextStyles.bodySm().copyWith(
                          color: NileColors.txtTertiary,
                        ),
                      ),
                    ),
                  )
                : ListView(children: [for (final e in lib) _row(e)]),
          ),
          const Divider(height: 1),
          if (cues.isNotEmpty)
            Container(
              color: NileColors.bgRaised,
              padding: const EdgeInsets.fromLTRB(
                NileSpacing.s24,
                NileSpacing.s8,
                NileSpacing.s12,
                NileSpacing.s8,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      cues.length == 1
                          ? 'Cued: ${cues.label} → '
                                '${cues.describe(_labelOf, _order).targets}'
                          : 'Cued (${cues.length}): '
                                '${cues.describe(_labelOf, _order).targets}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: NileTextStyles.bodyMd(),
                    ),
                  ),
                  TextButton(
                    onPressed: () => widget.cue.value = CueSet.empty,
                    child: Text(cues.length == 1 ? 'Clear' : 'Clear all'),
                  ),
                  const SizedBox(width: NileSpacing.s8),
                  FilledButton(
                    onPressed: _taking ? null : _take,
                    style: FilledButton.styleFrom(
                      backgroundColor: NileColors.volt,
                      foregroundColor: NileColors.onVolt,
                    ),
                    child: Text(cues.length == 1 ? 'Take' : 'Take all'),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(NileSpacing.s12),
            child: Row(
              children: [
                if (kinds.isNotEmpty)
                  PopupMenuButton<ElementKindSpec>(
                    tooltip: 'New element',
                    color: NileColors.bgSurface,
                    onSelected: (k) => _edit(kind: k),
                    itemBuilder: (_) => [
                      for (final k in kinds)
                        PopupMenuItem(
                          value: k,
                          child: Text(k.label, style: NileTextStyles.bodyMd()),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(NileSpacing.s8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add, color: NileColors.volt, size: 18),
                          const SizedBox(width: NileSpacing.s6),
                          Text(
                            'New element',
                            style: NileTextStyles.labelMd().copyWith(
                              color: NileColors.volt,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(StudioElement e) {
    final live = _c.current(e.id);
    final ui = elementKindUis[e.kind];
    if (live == null) return const SizedBox.shrink();
    final on = live.onAir;
    final cue = widget.cue.value.elementById(e.id);
    final shown = cue != null && !on ? cue.targets : live.targets;
    final selected = _selected == e.id;
    void act(
      LiveElement Function(LiveElement) change, {
      Map<String, ClockOp> clockOps = const {},
      ElementOps ops = ElementOps.none,
    }) => _act(e.id, change, clockOps: clockOps, ops: ops);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          selected: selected,
          selectedTileColor: NileColors.volt.withValues(alpha: 0.06),
          onTap: () => setState(() => _selected = selected ? null : e.id),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: NileSpacing.s24,
          ),
          leading: Icon(
            Icons.widgets_outlined,
            color: on ? NileColors.volt : NileColors.txtSecondary,
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  e.name,
                  overflow: TextOverflow.ellipsis,
                  style: NileTextStyles.bodyMd(),
                ),
              ),
              if (cue != null) ...[
                const SizedBox(width: NileSpacing.s8),
                Tooltip(
                  message: 'Remove from cue',
                  child: InkWell(
                    onTap: () =>
                        widget.cue.value = widget.cue.value.without(e.id),
                    borderRadius: BorderRadius.circular(NileRadius.xs),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: NileSpacing.s4,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: NileColors.volt),
                        borderRadius: BorderRadius.circular(NileRadius.xs),
                      ),
                      child: Text(
                        'CUED',
                        style: NileTextStyles.labelSm().copyWith(
                          color: NileColors.volt,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          subtitle: Text(
            [
              e.spec?.label ?? e.kind,
              if (live.angle) 'Own angle',
              if (e.style.nileStyle) 'Nile style',
            ].join(' · '),
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtTertiary,
            ),
          ),
          trailing: OutlinedButton.icon(
            onPressed: () => _chooseCameras(e),
            icon: Icon(
              on
                  ? Icons.videocam
                  : cue != null
                  ? Icons.videocam_outlined
                  : Icons.videocam_off_outlined,
              size: 16,
              color: on ? NileColors.volt : NileColors.txtTertiary,
            ),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Text(
                shown.summary(_labelOf, _order),
                overflow: TextOverflow.ellipsis,
                style: NileTextStyles.labelSm().copyWith(
                  color: on || cue != null
                      ? NileColors.txtPrimary
                      : NileColors.txtTertiary,
                ),
              ),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: on ? NileColors.volt : NileColors.border),
              padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s8),
            ),
          ),
        ),
        if (selected && ui != null)
          // Material, not a coloured box: the switch tile draws its ink here.
          Material(
            color: NileColors.bgRaised,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                NileSpacing.s24,
                NileSpacing.s12,
                NileSpacing.s24,
                NileSpacing.s12,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ui.controls?.call(live, act, _c.tally(e.id)) ??
                      ElementHudControls(
                        element: live,
                        tally: _c.tally(e.id),
                        act: act,
                        wrap: true,
                      ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      'Show as its own angle',
                      style: NileTextStyles.bodyMd(),
                    ),
                    subtitle: Text(
                      'Viewers can pick it like a camera — full screen on your '
                      'brand background. The sound stays as it is.',
                      style: NileTextStyles.caption().copyWith(
                        color: NileColors.txtTertiary,
                      ),
                    ),
                    value: live.angle,
                    activeThumbColor: NileColors.volt,
                    onChanged: (v) => _c.setAngle(e.id, v),
                  ),
                  const SizedBox(height: NileSpacing.s8),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: _c.canUndo(e.id)
                            ? () => _c.undo(e.id)
                            : null,
                        icon: const Icon(Icons.undo, size: 18),
                        label: const Text('Undo'),
                      ),
                      TextButton.icon(
                        onPressed: () => _edit(existing: e),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: const Text('Edit'),
                      ),
                      const Spacer(),
                      Flexible(
                        child: Text(
                          [
                            for (final s in ui.shortcuts)
                              '${_keyLabel(s.keys.first)} ${s.label}',
                          ].join(' · '),
                          textAlign: TextAlign.end,
                          maxLines: 2,
                          style: NileTextStyles.caption().copyWith(
                            color: NileColors.txtTertiary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  static String _keyLabel(SingleActivator k) => switch (k.trigger) {
    LogicalKeyboardKey.space => 'Space',
    LogicalKeyboardKey.equal => '+',
    LogicalKeyboardKey.minus => '−',
    final t => t.keyLabel,
  };
}

// ── Editor ───────────────────────────────────────────────────────────────────

/// What the editor did: saved (the item) or deleted.
typedef ElementEditResult = ({StudioElement? element, bool deleted});

/// Create or edit a saved element: name, the kind's settings, and its look —
/// the brand kit with optional colour overrides (e.g. team colours), or Nile
/// style. Contrast problems are flagged, never blocked.
Future<ElementEditResult?> showElementEditor(
  BuildContext context, {
  required ElementKindSpec kind,
  StudioElement? existing,
  ElementLibrary library = const ElementLibrary(),
  BrandStyle? kit,
  bool locked = false,
}) => showDialog<ElementEditResult>(
  context: context,
  builder: (_) => Dialog(
    backgroundColor: NileColors.bgSurface,
    insetPadding: const EdgeInsets.all(NileSpacing.s24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520, maxHeight: 760),
      child: _ElementEditor(
        kind: kind,
        existing: existing,
        library: library,
        kit: kit,
        locked: locked,
      ),
    ),
  ),
);

class _ElementEditor extends StatefulWidget {
  const _ElementEditor({
    required this.kind,
    required this.existing,
    required this.library,
    required this.kit,
    this.locked = false,
  });

  final ElementKindSpec kind;
  final StudioElement? existing;
  final ElementLibrary library;
  final BrandStyle? kit;
  final bool locked;

  @override
  State<_ElementEditor> createState() => _ElementEditorState();
}

class _ElementEditorState extends State<_ElementEditor> {
  late StudioElement _draft =
      widget.existing ??
      StudioElement(
        id: 'draft',
        kind: widget.kind.wire,
        name: widget.kind.label.replaceAll(' (test)', ''),
        config: Map.of(widget.kind.defaultConfig),
      );
  late final _name = TextEditingController(text: _draft.name);
  late final Map<String, TextEditingController> _hex = {
    'accent': TextEditingController(text: _draft.style.accent ?? ''),
    'panel': TextEditingController(text: _draft.style.panel ?? ''),
    'text': TextEditingController(text: _draft.style.text ?? ''),
  };
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    for (final c in _hex.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _setStyle() {
    String? v(String k) {
      final t = _hex[k]!.text.trim().toUpperCase();
      return t.isEmpty ? null : (t.startsWith('#') ? t : '#$t');
    }

    setState(
      () => _draft = _draft.copyWith(
        style: ElementStyle(
          nileStyle: _draft.style.nileStyle,
          accent: v('accent'),
          panel: v('panel'),
          text: v('text'),
        ),
      ),
    );
  }

  Future<void> _save() async {
    final draft = _draft.copyWith(name: _name.text.trim());
    final err = draft.error;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final StudioElement saved;
      if (widget.existing == null) {
        saved = await widget.library.create(draft);
      } else {
        await widget.library.update(draft);
        saved = draft;
      }
      if (mounted) Navigator.pop(context, (element: saved, deleted: false));
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is ArgumentError
              ? '${e.message}'
              : 'Couldn’t save that element. Try again.';
        });
      }
    }
  }

  Future<void> _delete() async {
    final e = widget.existing;
    if (e == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text('Delete “${e.name}”?', style: NileTextStyles.headingMd()),
        content: Text(
          'It comes off every camera and its live values are gone.',
          style: NileTextStyles.bodyMd(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(color: NileColors.error)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.library.delete(e);
      if (mounted) Navigator.pop(context, (element: null, deleted: true));
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Couldn’t delete that element. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ui = elementKindUis[widget.kind.wire];
    final style = _draft.style.resolve(widget.kit);
    final warnings = style?.contrastWarnings ?? const <String>[];
    final preview = LiveElement.fromLibrary(_draft, kit: widget.kit);
    return ListView(
      padding: const EdgeInsets.all(NileSpacing.s24),
      children: [
        Text(
          widget.existing == null ? 'New ${widget.kind.label}' : 'Edit element',
          style: NileTextStyles.headingMd(),
        ),
        const SizedBox(height: NileSpacing.s16),
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(NileRadius.md),
            child: ColoredBox(
              // Video is dark in both themes.
              color: NilePalette.dark.bgRaised,
              child: NileGraphicsLayer(graphics: const [], elements: [preview]),
            ),
          ),
        ),
        const SizedBox(height: NileSpacing.s16),
        TextField(
          controller: _name,
          maxLength: 60,
          decoration: const InputDecoration(labelText: 'Name'),
          onChanged: (_) => setState(() {}),
        ),
        if (ui != null)
          ui.editor(
            _draft.config,
            (c) => setState(() => _draft = _draft.copyWith(config: c)),
            locked: widget.locked,
          ),
        const SizedBox(height: NileSpacing.s8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Use Nile style', style: NileTextStyles.bodyMd()),
          subtitle: Text(
            widget.kit == null
                ? 'Off: your colours below'
                : 'Off: your brand kit, with any colours below',
            style: NileTextStyles.caption().copyWith(
              color: NileColors.txtTertiary,
            ),
          ),
          value: _draft.style.nileStyle,
          activeThumbColor: NileColors.volt,
          onChanged: (v) => setState(
            () => _draft = _draft.copyWith(
              style: ElementStyle(
                nileStyle: v,
                accent: _draft.style.accent,
                panel: _draft.style.panel,
                text: _draft.style.text,
              ),
            ),
          ),
        ),
        if (!_draft.style.nileStyle)
          for (final (key, label) in const [
            ('accent', 'Accent'),
            ('panel', 'Panel'),
            ('text', 'Text'),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: NileSpacing.s8),
              child: TextField(
                controller: _hex[key],
                maxLength: 7,
                decoration: InputDecoration(
                  labelText: '$label colour',
                  hintText: widget.kit == null
                      ? 'Nile default'
                      : 'From your kit',
                  counterText: '',
                  prefixIcon: Padding(
                    padding: const EdgeInsets.all(NileSpacing.s12),
                    child: _Dot(hex: _hex[key]!.text),
                  ),
                ),
                onChanged: (_) => _setStyle(),
              ),
            ),
        for (final w in warnings)
          Padding(
            padding: const EdgeInsets.only(top: NileSpacing.s4),
            child: Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: NileColors.warning,
                ),
                const SizedBox(width: NileSpacing.s6),
                Expanded(
                  child: Text(
                    w,
                    style: NileTextStyles.bodySm().copyWith(
                      color: NileColors.warning,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (_error != null) ...[
          const SizedBox(height: NileSpacing.s12),
          Text(
            _error!,
            style: NileTextStyles.bodySm().copyWith(color: NileColors.error),
          ),
        ],
        const SizedBox(height: NileSpacing.s24),
        Row(
          children: [
            if (widget.existing != null)
              TextButton(
                onPressed: _busy ? null : _delete,
                child: Text(
                  'Delete',
                  style: TextStyle(color: NileColors.error),
                ),
              ),
            const Spacer(),
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: NileSpacing.s8),
            FilledButton(
              onPressed: _busy ? null : _save,
              style: FilledButton.styleFrom(
                backgroundColor: NileColors.volt,
                foregroundColor: NileColors.onVolt,
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.hex});
  final String hex;

  @override
  Widget build(BuildContext context) {
    final h = hex.trim().startsWith('#') ? hex.trim() : '#${hex.trim()}';
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isBrandHex(h) ? colorFromHex(h) : Colors.transparent,
        border: Border.all(color: NileColors.borderStrong),
      ),
    );
  }
}
