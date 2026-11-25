import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/layout_templates.dart';
import '../services/live_elements.dart';
import '../services/studio_graphics.dart';
import '../services/studio_layouts.dart';
import '../services/studio_layouts_controller.dart';
import '../theme.dart';
import 'nile_graphics_layer.dart';
import 'nile_studio.dart' show NileCuedChip;
import 'studio_layout_editor.dart';
import 'studio_graphics_panel.dart' show StudioGraphicsHotkeys, StudioSlotRef;

/// The Studio toolbar's Layouts panel (docs/plans/studio-layouts.md, phase
/// 4): saved show setups. Cue one to see what it would change on each camera,
/// then Apply (here, Enter, or the Studio's cue bar). ⌥1–9 cue the first nine
/// from anywhere in the Studio.
Future<void> showLayoutsPanel(
  BuildContext context, {
  required StudioLayoutsController controller,
  required List<StudioSlotRef> slots,
  List<LayoutTemplate> templates = const [],
}) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    backgroundColor: NileColors.bgSurface,
    insetPadding: const EdgeInsets.all(NileSpacing.s24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600, maxHeight: 720),
      child: LayoutsPanel(
        controller: controller,
        slots: slots,
        templates: templates,
      ),
    ),
  ),
);

/// What to tell the host after an Apply.
String appliedMessage(StudioLayout l, ResolvedLayout r) {
  final notes = [
    if (r.missingCount > 0)
      '${r.missingCount} ${r.missingCount == 1 ? 'item was' : 'items were'} '
          'deleted from your library and skipped',
    if (r.skippedCameras > 0)
      'it has ${r.skippedCameras} more '
          '${r.skippedCameras == 1 ? 'camera' : 'cameras'} than this show',
  ];
  return notes.isEmpty
      ? '“${l.name}” is on air.'
      : '“${l.name}” is on air — ${notes.join('; ')}.';
}

class LayoutsPanel extends StatefulWidget {
  const LayoutsPanel({
    super.key,
    required this.controller,
    required this.slots,
    this.templates = const [],
  });

  final StudioLayoutsController controller;
  final List<StudioSlotRef> slots;

  /// "New from template" choices (with the host's brand logo and name).
  final List<LayoutTemplate> templates;

  @override
  State<LayoutsPanel> createState() => _LayoutsPanelState();
}

class _LayoutsPanelState extends State<LayoutsPanel> {
  bool _loading = true;
  String? _error;
  String? _message;

  StudioLayoutsController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
    HardwareKeyboard.instance.addHandler(_onKey);
    _load();
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _c.load(force: true);
    } catch (_) {
      _error = 'Couldn’t load your layouts. Try again.';
    }
    if (mounted) setState(() => _loading = false);
  }

  /// ⌥1–9 cue, Enter applies — while this panel is the top route.
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || !mounted) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (StudioGraphicsHotkeys.typing()) return false;
    final kb = HardwareKeyboard.instance;
    final digit = StudioGraphicsHotkeys.altDigit(e);
    if (digit != null) {
      _c.cueNumber(digit);
      return true;
    }
    if ((e.logicalKey == LogicalKeyboardKey.enter ||
            e.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        !kb.isMetaPressed &&
        !kb.isControlPressed &&
        !kb.isAltPressed &&
        _c.cued != null) {
      _apply(_c.cued!);
      return true;
    }
    return false;
  }

  Future<void> _run(Future<String?> Function() action) async {
    setState(() => _message = null);
    try {
      final msg = await action();
      if (mounted) setState(() => _message = msg);
    } on ArgumentError catch (e) {
      if (mounted) setState(() => _message = e.message.toString());
    } catch (e) {
      final s = e.toString().replaceFirst('Exception: ', '');
      if (mounted) {
        setState(
          () => _message = s.startsWith('AppError')
              ? 'Something went wrong. Try again.'
              : s,
        );
      }
    }
  }

  Future<void> _apply(StudioLayout l) => _run(() async {
    final r = await _c.apply(l);
    return r == null ? null : appliedMessage(l, r);
  });

  Future<String?> _askName(String title, {String initial = ''}) {
    final ctl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text(title, style: NileTextStyles.headingMd()),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(hintText: 'Name'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    ).whenComplete(ctl.dispose);
  }

  String _leftOutNote(List<String> leftOut) => leftOut.isEmpty
      ? ''
      : ' Not saved (not in your library): ${leftOut.join(', ')}.';

  Future<void> _saveCurrent() async {
    final name = (await _askName(
      'Save current look',
      initial: 'Layout ${_c.layouts.length + 1}',
    ))?.trim();
    if (name == null || name.isEmpty || !mounted) return;
    await _run(() async {
      final r = await _c.saveCurrent(name);
      return 'Saved “${r.layout.name}”.${_leftOutNote(r.leftOut)}';
    });
  }

  Future<void> _edit(StudioLayout l) async {
    final next = await showLayoutEditor(
      context,
      layout: l,
      controller: _c,
      onAir: _c.isOnAir(l),
    );
    if (next == null || !mounted) return;
    await _run(() async {
      final saved = await _c.save(next);
      return _c.isOnAir(saved)
          ? 'Saved “${saved.name}”. Apply it again to send it.'
          : 'Saved “${saved.name}”.';
    });
  }

  /// A blank layout with one camera per camera in this show.
  Future<void> _newLayout() {
    final n = _c.current().positions.length;
    return _edit(
      StudioLayout(
        name: 'Layout ${_c.layouts.length + 1}',
        cameras: List.filled(n < 1 ? 1 : n, const LayoutCamera()),
      ),
    );
  }

  Future<void> _fromTemplate(LayoutTemplate t) => _run(() async {
    final saved = await _c.newFromTemplate(t);
    return 'Added “${saved.name}”. Cue it to see what it changes.';
  });

  Future<void> _menu(StudioLayout l, _CardAction a) async {
    switch (a) {
      case _CardAction.edit:
        await _edit(l);
      case _CardAction.update:
        await _run(() async {
          final left = await _c.updateFromCurrent(l);
          final reapply = _c.isOnAir(l) ? ' Apply it again to send it.' : '';
          return 'Updated “${l.name}”.$reapply${_leftOutNote(left)}';
        });
      case _CardAction.rename:
        final name = (await _askName('Rename layout', initial: l.name))?.trim();
        if (name == null || name.isEmpty || name == l.name) return;
        await _run(() async {
          await _c.rename(l, name);
          return null;
        });
      case _CardAction.duplicate:
        await _run(() async {
          await _c.duplicate(l);
          return null;
        });
      case _CardAction.delete:
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: NileColors.bgSurface,
            title: Text(
              'Delete “${l.name}”?',
              style: NileTextStyles.headingMd(),
            ),
            content: Text(
              'The layout goes; your graphics and elements stay in the library.',
              style: NileTextStyles.bodyMd().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(
                  'Delete',
                  style: NileTextStyles.labelMd().copyWith(
                    color: NileColors.error,
                  ),
                ),
              ),
            ],
          ),
        );
        if (ok != true) return;
        await _run(() async {
          await _c.delete(l);
          return null;
        });
    }
  }

  String _labelOf(String slotId) =>
      widget.slots.where((s) => s.id == slotId).firstOrNull?.label ?? 'Camera';

  @override
  Widget build(BuildContext context) {
    final layouts = _c.layouts;
    return Column(
      mainAxisSize: MainAxisSize.min,
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
                child: Text('Layouts', style: NileTextStyles.headingMd()),
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
            'Saved show setups. Cue one to see what changes, then Apply. '
            '⌥1–9 cue your first nine from anywhere in the Studio; Enter '
            'applies.',
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NileSpacing.s24,
            NileSpacing.s12,
            NileSpacing.s24,
            NileSpacing.s8,
          ),
          child: Wrap(
            spacing: NileSpacing.s8,
            runSpacing: NileSpacing.s8,
            children: [
              OutlinedButton.icon(
                onPressed: _loading || _error != null ? null : _saveCurrent,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Save current look'),
              ),
              OutlinedButton.icon(
                onPressed: _loading || _error != null ? null : _newLayout,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('New layout'),
              ),
              if (widget.templates.isNotEmpty)
                PopupMenuButton<LayoutTemplate>(
                  enabled: !_loading && _error == null,
                  tooltip: 'New from template',
                  onSelected: _fromTemplate,
                  itemBuilder: (_) => [
                    for (final t in widget.templates)
                      PopupMenuItem(
                        value: t,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(t.name),
                          subtitle: Text(t.description),
                        ),
                      ),
                  ],
                  child: IgnorePointer(
                    child: OutlinedButton.icon(
                      onPressed: _loading || _error != null ? null : () {},
                      icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                      label: const Text('From template'),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Flexible(
          child: _loading
              ? const Padding(
                  padding: EdgeInsets.all(NileSpacing.s24),
                  child: Center(child: CircularProgressIndicator()),
                )
              : _error != null
              ? _note(
                  _error!,
                  action: TextButton(
                    onPressed: _load,
                    child: const Text('Retry'),
                  ),
                )
              : layouts.isEmpty
              ? _note(
                  'No layouts yet. Set the show up the way you like it, then '
                  'Save current look.',
                )
              : ReorderableListView.builder(
                  shrinkWrap: true,
                  buildDefaultDragHandles: false,
                  padding: const EdgeInsets.fromLTRB(
                    NileSpacing.s24,
                    0,
                    NileSpacing.s24,
                    NileSpacing.s12,
                  ),
                  itemCount: layouts.length,
                  onReorderItem: (a, b) => _run(() async {
                    await _c.move(a, b);
                    return null;
                  }),
                  itemBuilder: (_, i) => _card(i, layouts[i]),
                ),
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NileSpacing.s24,
              0,
              NileSpacing.s24,
              NileSpacing.s16,
            ),
            child: Text(
              _message!,
              style: NileTextStyles.bodySm().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
          ),
      ],
    );
  }

  Widget _note(String text, {Widget? action}) => Padding(
    padding: const EdgeInsets.all(NileSpacing.s24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          style: NileTextStyles.bodyMd().copyWith(
            color: NileColors.txtSecondary,
          ),
        ),
        ?action,
      ],
    ),
  );

  Widget _card(int i, StudioLayout l) {
    final cued = _c.cued?.id == l.id;
    final missing = _c.resolve(l).missingCount;
    return Padding(
      key: ValueKey(l.id),
      padding: const EdgeInsets.only(bottom: NileSpacing.s8),
      child: Container(
        padding: const EdgeInsets.all(NileSpacing.s12),
        decoration: BoxDecoration(
          color: NileColors.bgRaised,
          borderRadius: BorderRadius.circular(NileRadius.md),
          border: Border.all(color: cued ? NileColors.volt : NileColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ReorderableDragStartListener(
                  index: i,
                  child: Icon(
                    Icons.drag_indicator,
                    color: NileColors.txtTertiary,
                  ),
                ),
                const SizedBox(width: NileSpacing.s8),
                SizedBox(
                  width: 112,
                  child: LayoutThumbnail(layout: l, controller: _c),
                ),
                const SizedBox(width: NileSpacing.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.name,
                        style: NileTextStyles.labelLg(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: NileSpacing.s4),
                      Wrap(
                        spacing: NileSpacing.s6,
                        runSpacing: NileSpacing.s4,
                        children: [
                          if (_c.isOnAir(l))
                            _badge('ON AIR', NileColors.success),
                          if (cued) const NileCuedChip(),
                          if (_c.isChanged(l))
                            _badge('CHANGED SINCE APPLIED', NileColors.warning),
                          if (missing > 0)
                            _badge('$missing MISSING', NileColors.error),
                          Text(
                            '${l.cameras.length} '
                            '${l.cameras.length == 1 ? 'camera' : 'cameras'}'
                            '${i < 9 ? '  ·  ⌥${i + 1}' : ''}',
                            style: NileTextStyles.caption().copyWith(
                              color: NileColors.txtTertiary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                cued
                    ? FilledButton(
                        onPressed: () => _c.cue(null),
                        style: FilledButton.styleFrom(
                          backgroundColor: NileColors.volt,
                          foregroundColor: NileColors.onVolt,
                        ),
                        child: const Text('Cued'),
                      )
                    : OutlinedButton(
                        onPressed: () => _c.cue(l),
                        child: const Text('Cue'),
                      ),
                PopupMenuButton<_CardAction>(
                  tooltip: 'More',
                  icon: Icon(Icons.more_vert, color: NileColors.txtSecondary),
                  onSelected: (a) => _menu(l, a),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: _CardAction.edit,
                      child: Text('Edit…'),
                    ),
                    PopupMenuItem(
                      value: _CardAction.update,
                      child: Text('Update from current look'),
                    ),
                    PopupMenuItem(
                      value: _CardAction.rename,
                      child: Text('Rename…'),
                    ),
                    PopupMenuItem(
                      value: _CardAction.duplicate,
                      child: Text('Duplicate'),
                    ),
                    PopupMenuItem(
                      value: _CardAction.delete,
                      child: Text('Delete…'),
                    ),
                  ],
                ),
              ],
            ),
            if (cued) _cueSummary(l),
          ],
        ),
      ),
    );
  }

  Widget _cueSummary(StudioLayout l) {
    final changes = _c.changesFor(l, labelOf: _labelOf);
    return Padding(
      padding: const EdgeInsets.only(top: NileSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (changes.isEmpty)
            Text(
              'Nothing changes — the show already looks like this.',
              style: NileTextStyles.bodySm().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
          for (final c in changes)
            Text(
              describeChange(c),
              style: NileTextStyles.bodySm().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
          const SizedBox(height: NileSpacing.s8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _c.busy ? null : () => _apply(l),
              style: FilledButton.styleFrom(
                backgroundColor: NileColors.volt,
                foregroundColor: NileColors.onVolt,
              ),
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Apply (Enter)'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: NileSpacing.s6,
      vertical: NileSpacing.s2,
    ),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(NileRadius.xs),
    ),
    child: Text(
      text,
      style: NileTextStyles.labelSm().copyWith(
        color: color,
        letterSpacing: 1.2,
      ),
    ),
  );
}

enum _CardAction { edit, update, rename, duplicate, delete }

/// One camera of a layout (Camera 1 by default), drawn the way viewers would
/// see it (on a dark video frame, scaled down from 640×360).
class LayoutThumbnail extends StatelessWidget {
  const LayoutThumbnail({
    super.key,
    required this.layout,
    required this.controller,
    this.camera = 0,
  });

  final StudioLayout layout;
  final StudioLayoutsController controller;

  /// Position index (0 = Camera 1).
  final int camera;

  @override
  Widget build(BuildContext context) {
    final cam = camera < layout.cameras.length
        ? layout.cameras[camera]
        : const LayoutCamera();
    final graphics = <LiveGraphic>[];
    final elements = <LiveElement>[];
    for (final item in cam.items) {
      if (item.isGraphic) {
        final g = controller.graphicsLibrary[item.ref];
        if (g != null) graphics.add(controller.build(g, 0));
      } else {
        final e = controller.elementsLibrary[item.ref];
        if (e != null) {
          elements.add(
            LiveElement.fromLibrary(
              e,
              kit: controller.kit?.call(),
            ).copyWith(targets: const GraphicTargets.all()),
          );
        }
      }
    }
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(NileRadius.sm),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video is dark in both themes.
            ColoredBox(color: NilePalette.dark.bgRaised),
            FittedBox(
              child: SizedBox(
                width: 640,
                height: 360,
                child: IgnorePointer(
                  child: NileGraphicsLayer(
                    graphics: graphics,
                    elements: elements,
                    layers: [for (final i in cam.items) i.layer],
                  ),
                ),
              ),
            ),
            if (!cam.onAir)
              ColoredBox(
                color: NilePalette.dark.bgPage.withValues(alpha: 0.6),
                child: Center(
                  child: Icon(
                    Icons.videocam_off_outlined,
                    color: NileColors.txtSecondary,
                    size: 18,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
