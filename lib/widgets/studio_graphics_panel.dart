import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/brand_kit.dart';
import '../services/graphics_service.dart';
import '../services/studio_graphics.dart';
import '../theme.dart';
import 'brand_kit_editor.dart';
import 'nile_graphics_layer.dart';
import 'nile_studio.dart' show graphicKindIcon;

IconData graphicIcon(GraphicKind k) => graphicKindIcon(k);

/// A camera slot as the graphics panel lists it: every slot of the event,
/// connected or not, in display order.
typedef StudioSlotRef = ({String id, String label});

String _sizeLabel(Object? s) => switch (s) {
  's' => 'Small',
  'l' => 'Large',
  _ => 'Medium',
};

/// "Lower third · 8 s", "Logo · Top right, Large", "Slate · countdown"…
String graphicSubtitle(StudioGraphic g) {
  final p = g.payload;
  final parts = <String>[g.kind.label];
  String place(String fallback) =>
      '${logoCornerLabels[p['corner']] ?? fallback}, ${_sizeLabel(p['size'])}';
  if (g.kind == GraphicKind.logo || g.kind == GraphicKind.sponsor) {
    parts.add(place('Top right'));
  }
  if (g.kind == GraphicKind.qr) {
    final source = p['source'] as String? ?? 'custom';
    final host = Uri.tryParse(p['url'] as String? ?? '')?.host ?? '';
    parts
      ..add(place('Bottom right'))
      ..add(
        source == 'custom'
            ? (host.isEmpty ? 'no link' : host)
            : qrSources[source] ?? source,
      );
  }
  if (g.kind == GraphicKind.banner && p['scrolling'] == true)
    parts.add('ticker');
  if (g.kind == GraphicKind.slate) {
    final cd = p['countdown'];
    final mode = cd is Map ? CountdownMode.fromWire(cd['mode']) : null;
    if (mode == CountdownMode.clock) {
      parts.add('counts to ${cd['at']}');
    } else if (mode == CountdownMode.showStart) {
      parts.add('counts to show start');
    } else if (mode == CountdownMode.duration ||
        p['countdownSeconds'] != null) {
      final secs =
          ((cd is Map ? cd['seconds'] : p['countdownSeconds']) as num?)
              ?.toInt() ??
          0;
      parts.add('${(secs / 60).round()} min countdown');
    }
  }
  if (g.autoHideSeconds > 0) parts.add('hides after ${g.autoHideSeconds} s');
  if (g.nileStyle) parts.add('Nile style');
  return parts.join(' · ');
}

// ── Hotkeys ──────────────────────────────────────────────────────────────────

/// Keys 1–9 act on the first nine items of the host's library (see
/// [graphicsHotkeyAction]); Enter takes the cue, Escape clears it. Wrap the
/// Studio in this; it ignores keys while a text field has focus and any key
/// with ⌘/Ctrl/Alt held (⌘1–⌘9 belong to the nav rail).
class StudioGraphicsHotkeys extends StatefulWidget {
  const StudioGraphicsHotkeys({
    super.key,
    required this.onDigit,
    required this.child,
    this.onTake,
    this.onClear,
    this.enabled = true,
  });

  /// 1-9.
  final ValueChanged<int> onDigit;

  /// Enter / numpad Enter. Null = the key passes through.
  final VoidCallback? onTake;

  /// Escape. Null = the key passes through.
  final VoidCallback? onClear;
  final Widget child;
  final bool enabled;

  /// True when typing would go to a text field right now.
  static bool typing() =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<EditableTextState>() !=
      null;

  @override
  State<StudioGraphicsHotkeys> createState() => _StudioGraphicsHotkeysState();
}

class _StudioGraphicsHotkeysState extends State<StudioGraphicsHotkeys> {
  static final _digits = {
    LogicalKeyboardKey.digit1: 1,
    LogicalKeyboardKey.digit2: 2,
    LogicalKeyboardKey.digit3: 3,
    LogicalKeyboardKey.digit4: 4,
    LogicalKeyboardKey.digit5: 5,
    LogicalKeyboardKey.digit6: 6,
    LogicalKeyboardKey.digit7: 7,
    LogicalKeyboardKey.digit8: 8,
    LogicalKeyboardKey.digit9: 9,
    LogicalKeyboardKey.numpad1: 1,
    LogicalKeyboardKey.numpad2: 2,
    LogicalKeyboardKey.numpad3: 3,
    LogicalKeyboardKey.numpad4: 4,
    LogicalKeyboardKey.numpad5: 5,
    LogicalKeyboardKey.numpad6: 6,
    LogicalKeyboardKey.numpad7: 7,
    LogicalKeyboardKey.numpad8: 8,
    LogicalKeyboardKey.numpad9: 9,
  };

  bool _onKey(KeyEvent e) {
    if (!widget.enabled || e is! KeyDownEvent) return false;
    final key = e.logicalKey;
    final digit = _digits[key];
    final VoidCallback? action = digit != null
        ? () => widget.onDigit(digit)
        : key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.numpadEnter
        ? widget.onTake
        : key == LogicalKeyboardKey.escape
        ? widget.onClear
        : null;
    if (action == null) return false;
    final kb = HardwareKeyboard.instance;
    if (kb.isMetaPressed || kb.isControlPressed || kb.isAltPressed)
      return false;
    if (StudioGraphicsHotkeys.typing()) return false;
    // Not while a dialog sits on top (the graphics panel, a confirm): a key
    // there would change graphics behind it and leave the two out of step.
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    action();
    return true;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Hotkey [digit]: library item `digit - 1`. On air anywhere → `off` is the
/// state with it taken off everywhere (removals skip the cue). Otherwise `cue`
/// is that item cued onto its last-used cameras (all cameras the first time).
/// Null when the key has no graphic.
({GraphicsState? off, GraphicCue? cue})? graphicsHotkeyAction({
  required int digit,
  required List<StudioGraphic> library,
  required GraphicsState current,
  required Map<String, GraphicTargets> lastTargets,
  DateTime? showStartAt,
  String? Function(String source)? resolveLink,
}) {
  if (digit < 1 || digit > library.length || digit > 9) return null;
  final g = library[digit - 1];
  if (current.onAnywhere(g.id)) {
    return (off: current.withoutEverywhere(g.id), cue: null);
  }
  return (
    off: null,
    cue: GraphicCue.of(
      g,
      targets: lastTargets[g.id] ?? const GraphicTargets.all(),
      publicUrl: GraphicsService.publicUrl,
      showStartAt: showStartAt,
      resolveLink: resolveLink,
    ),
  );
}

// ── Cameras / timer chooser ──────────────────────────────────────────────────

/// What the Cameras checklist came back with.
typedef GraphicTargetsChoice = ({GraphicTargets targets, int autoHideSeconds});

/// The checklist behind each graphic's "Cameras" button (and chat's "Show on
/// screen — cameras & timer…"): All cameras, each slot, and how long it stays
/// up. Returns null when cancelled; `GraphicTargets.none` means "Remove from
/// all".
Future<GraphicTargetsChoice?> showGraphicTargetsDialog(
  BuildContext context, {
  required String title,
  required List<StudioSlotRef> slots,
  required GraphicTargets initial,
  required int autoHideSeconds,
  bool canRemove = false,
  String confirmLabel = 'Put on air',
}) => showDialog<GraphicTargetsChoice>(
  context: context,
  builder: (_) => _TargetsDialog(
    title: title,
    slots: slots,
    initial: initial.isNone ? const GraphicTargets.all() : initial,
    autoHide: autoHideSeconds,
    canRemove: canRemove,
    confirmLabel: confirmLabel,
  ),
);

class _TargetsDialog extends StatefulWidget {
  const _TargetsDialog({
    required this.title,
    required this.slots,
    required this.initial,
    required this.autoHide,
    required this.canRemove,
    required this.confirmLabel,
  });

  final String title;
  final List<StudioSlotRef> slots;
  final GraphicTargets initial;
  final int autoHide;
  final bool canRemove;
  final String confirmLabel;

  @override
  State<_TargetsDialog> createState() => _TargetsDialogState();
}

class _TargetsDialogState extends State<_TargetsDialog> {
  late bool _all = widget.initial.all;
  late final Set<String> _on = {
    for (final s in widget.slots)
      if (widget.initial.includes(s.id)) s.id,
  };
  late int _hide = widget.autoHide;
  late final _custom = TextEditingController(
    text: autoHideChoices.contains(widget.autoHide) ? '' : '${widget.autoHide}',
  );

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  GraphicTargets get _targets => _all
      ? GraphicTargets.all(
          except: {
            for (final s in widget.slots)
              if (!_on.contains(s.id)) s.id,
          },
        )
      : GraphicTargets.only({..._on});

  @override
  Widget build(BuildContext context) {
    final isCustom = !autoHideChoices.contains(_hide);
    return AlertDialog(
      backgroundColor: NileColors.bgSurface,
      title: Text(widget.title, style: NileTextStyles.headingMd()),
      content: SizedBox(
        width: 360,
        child: ListView(
          shrinkWrap: true,
          children: [
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('All cameras', style: NileTextStyles.bodyMd()),
              subtitle: Text(
                'Includes cameras that join later',
                style: NileTextStyles.caption().copyWith(
                  color: NileColors.txtTertiary,
                ),
              ),
              value: _all,
              activeColor: NileColors.volt,
              checkColor: NileColors.onVolt,
              onChanged: (v) => setState(() {
                _all = v ?? false;
                if (_all) _on.addAll(widget.slots.map((s) => s.id));
              }),
            ),
            const Divider(height: 1),
            for (final s in widget.slots)
              CheckboxListTile(
                contentPadding: const EdgeInsets.only(left: NileSpacing.s16),
                dense: true,
                title: Text(s.label, style: NileTextStyles.bodyMd()),
                value: _on.contains(s.id),
                activeColor: NileColors.volt,
                checkColor: NileColors.onVolt,
                onChanged: (v) => setState(() {
                  v == true ? _on.add(s.id) : _on.remove(s.id);
                }),
              ),
            const SizedBox(height: NileSpacing.s12),
            Row(
              children: [
                Text('Hide after', style: NileTextStyles.bodyMd()),
                const Spacer(),
                DropdownButton<int>(
                  value: isCustom ? -1 : _hide,
                  dropdownColor: NileColors.bgRaised,
                  items: [
                    for (final c in autoHideChoices)
                      DropdownMenuItem(value: c, child: Text(autoHideLabel(c))),
                    const DropdownMenuItem(value: -1, child: Text('Custom…')),
                  ],
                  onChanged: (v) => setState(() {
                    if (v == null) return;
                    _hide = v == -1 ? (int.tryParse(_custom.text) ?? 20) : v;
                    if (v == -1 && _custom.text.isEmpty)
                      _custom.text = '$_hide';
                  }),
                ),
              ],
            ),
            if (isCustom)
              TextField(
                controller: _custom,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Seconds (1–3600)',
                ),
                onChanged: (v) => setState(
                  () => _hide = (int.tryParse(v) ?? 1).clamp(1, 3600),
                ),
              ),
          ],
        ),
      ),
      actions: [
        if (widget.canRemove)
          TextButton(
            onPressed: () => Navigator.pop(context, (
              targets: GraphicTargets.none,
              autoHideSeconds: _hide,
            )),
            child: Text(
              'Remove from all',
              style: TextStyle(color: NileColors.error),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _targets.isNone
              ? null
              : () => Navigator.pop(context, (
                  targets: _targets,
                  autoHideSeconds: _hide,
                )),
          style: FilledButton.styleFrom(
            backgroundColor: NileColors.volt,
            foregroundColor: NileColors.onVolt,
          ),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

// ── Push panel ───────────────────────────────────────────────────────────────

/// The Studio toolbar's Graphics panel: the show's sponsor (when it has one),
/// every preset and library item with a "Cameras" button saying where it is on
/// air (Off / All cameras / All but Cam 2 / Cam 1, Cam 3), plus Clear all and
/// ways into the library and brand kit editors. Library items 1–9 show their
/// hotkey.
///
/// Cue before air: picking cameras for a graphic that is off CUES it in [cue]
/// (only the Studio sees it); Take — the footer button or Enter — puts it on
/// air. Re-targeting or removing a graphic already on air is immediate.
///
/// [push] sends a whole new [GraphicsState] (the `set-graphics` action in the
/// real Studio, a local setState in Studio Preview) and returns whether it
/// stuck. [onTargetsUsed] remembers where each graphic last went, for its
/// hotkey. [onLibrary] hands back the library once loaded (hotkeys need it).
/// [resolveLink] turns a QR code's `event` / `profile` source into its link.
/// [onBrandKit] hears the brand kit editor's result (null = kit removed);
/// [brandKitDemo] keeps that editor from saving (Studio Preview).
Future<void> showGraphicsPushPanel(
  BuildContext context, {
  required GraphicsState current,
  required List<StudioSlotRef> slots,
  required Future<bool> Function(GraphicsState next) push,
  required ValueNotifier<GraphicCue?> cue,
  void Function(String graphicId, GraphicTargets targets)? onTargetsUsed,
  ValueChanged<List<StudioGraphic>>? onLibrary,
  DateTime? showStartAt,
  bool isLive = false,
  StudioGraphic? sponsor,
  String? Function(String source)? resolveLink,
  BrandKit? brandKit,
  ValueChanged<BrandKit?>? onBrandKit,
  bool brandKitDemo = false,
}) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    backgroundColor: NileColors.bgSurface,
    insetPadding: const EdgeInsets.all(NileSpacing.s24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
      child: _PushPanel(
        initial: current,
        slots: slots,
        push: push,
        cue: cue,
        onTargetsUsed: onTargetsUsed,
        onLibrary: onLibrary,
        showStartAt: showStartAt,
        isLive: isLive,
        sponsor: sponsor,
        resolveLink: resolveLink,
        brandKit: brandKit,
        onBrandKit: onBrandKit,
        brandKitDemo: brandKitDemo,
      ),
    ),
  ),
);

class _PushPanel extends StatefulWidget {
  const _PushPanel({
    required this.initial,
    required this.slots,
    required this.push,
    required this.cue,
    required this.isLive,
    required this.brandKitDemo,
    this.onTargetsUsed,
    this.onLibrary,
    this.showStartAt,
    this.sponsor,
    this.resolveLink,
    this.brandKit,
    this.onBrandKit,
  });

  final GraphicsState initial;
  final List<StudioSlotRef> slots;
  final Future<bool> Function(GraphicsState next) push;
  final ValueNotifier<GraphicCue?> cue;
  final void Function(String graphicId, GraphicTargets targets)? onTargetsUsed;
  final ValueChanged<List<StudioGraphic>>? onLibrary;
  final DateTime? showStartAt;
  final bool isLive;
  final StudioGraphic? sponsor;
  final String? Function(String source)? resolveLink;
  final BrandKit? brandKit;
  final ValueChanged<BrandKit?>? onBrandKit;
  final bool brandKitDemo;

  @override
  State<_PushPanel> createState() => _PushPanelState();
}

class _PushPanelState extends State<_PushPanel> {
  late GraphicsState _state = widget.initial;
  late BrandKit? _brandKit = widget.brandKit;
  late String _sponsorCorner =
      widget.sponsor?.payload['corner'] as String? ?? 'tr';
  late String _sponsorSize = widget.sponsor?.payload['size'] as String? ?? 'm';
  List<StudioGraphic>? _library;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.cue.addListener(_onCue);
    _loadLibrary();
  }

  @override
  void dispose() {
    widget.cue.removeListener(_onCue);
    super.dispose();
  }

  void _onCue() {
    if (mounted) setState(() {});
  }

  /// The sponsor item in the corner and size picked here.
  StudioGraphic? get _sponsor {
    final p = widget.sponsor?.payload;
    if (p == null) return null;
    return StudioGraphic.sponsor(
      campaignId: p['campaignId'] as String,
      sponsorName: p['sponsorName'] as String,
      logoUrl: p['logoUrl'] as String?,
      corner: _sponsorCorner,
      size: _sponsorSize,
    );
  }

  GraphicCue _cueOf(StudioGraphic g, GraphicTargets targets, int? autoHide) =>
      GraphicCue.of(
        g,
        targets: targets,
        publicUrl: GraphicsService.publicUrl,
        autoHideSeconds: autoHide,
        showStartAt: widget.showStartAt,
        resolveLink: widget.resolveLink,
      );

  Future<void> _loadLibrary() async {
    try {
      final items = await GraphicsService.list();
      if (!mounted) return;
      setState(() => _library = items);
      widget.onLibrary?.call(items);
    } catch (_) {
      if (mounted) {
        setState(() {
          _library = const [];
          _error = 'Couldn’t load your library — presets still work.';
        });
      }
    }
  }

  Future<bool> _apply(GraphicsState next) async {
    if (_busy) return false;
    // The panel holds a copy from when it opened; anything that auto-hid in
    // the meantime must not go back up with this push.
    next = next.withoutExpired(DateTime.now().millisecondsSinceEpoch);
    setState(() => _busy = true);
    final ok = await widget.push(next);
    if (!mounted) return ok;
    setState(() {
      _busy = false;
      if (ok) {
        _state = next;
        _error = null;
      } else {
        _error = 'Couldn’t update the show’s graphics. Try again.';
      }
    });
    return ok;
  }

  String _labelOf(String slotId) =>
      widget.slots.where((s) => s.id == slotId).firstOrNull?.label ?? 'Camera';

  Future<void> _chooseCameras(StudioGraphic g) async {
    final current = _state.targetsOf(g.id);
    final cued = widget.cue.value?.id == g.id ? widget.cue.value : null;
    final choice = await showGraphicTargetsDialog(
      context,
      title: g.name,
      slots: widget.slots,
      initial: current.isNone ? cued?.targets ?? current : current,
      autoHideSeconds: g.autoHideSeconds,
      canRemove: !current.isNone,
      confirmLabel: current.isNone ? 'Cue' : 'Put on air',
    );
    if (choice == null || !mounted) return;
    if (choice.targets.isNone) {
      await _apply(_state.withoutEverywhere(g.id));
      return;
    }
    widget.onTargetsUsed?.call(g.id, choice.targets);
    final next = _cueOf(g, choice.targets, choice.autoHideSeconds);
    // Off → cue it; Take puts it on air. Already on air → change it now.
    if (current.isNone) {
      widget.cue.value = next;
    } else {
      await _apply(next.take(_state, DateTime.now()));
    }
  }

  Future<void> _take() async {
    final c = widget.cue.value;
    if (c == null || _busy) return;
    final ok = await _apply(c.take(_state, DateTime.now()));
    if (ok && widget.cue.value == c) widget.cue.value = null;
  }

  Future<void> _editBrandKit() async {
    final result = await showBrandKitEditor(
      context,
      initial: _brandKit,
      demo: widget.brandKitDemo,
    );
    if (result == null || !mounted) return;
    setState(() => _brandKit = result.kit);
    widget.onBrandKit?.call(result.kit);
  }

  Future<void> _clearAll() async {
    if (widget.isLive) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: NileColors.bgSurface,
          title: Text(
            'Clear every graphic?',
            style: NileTextStyles.headingMd(),
          ),
          content: Text(
            'Everything comes off every camera, for every viewer.',
            style: NileTextStyles.bodyMd(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                'Clear all',
                style: TextStyle(color: NileColors.error),
              ),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _apply(GraphicsState.empty);
  }

  @override
  Widget build(BuildContext context) {
    final lib = _library;
    final order = [for (final s in widget.slots) s.id];
    final cue = widget.cue.value;
    final sponsor = _sponsor;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): _take,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _take,
      },
      child: Focus(
        autofocus: true,
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
                    child: Text('Graphics', style: NileTextStyles.headingMd()),
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
                'Pick cameras to cue a graphic, then Take to put it on air. '
                'Keys 1–9 cue your first nine; Enter takes.',
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
              child: ListView(
                children: [
                  if (sponsor != null) ...[
                    _header('SPONSOR'),
                    _row(sponsor, order, null, extra: _sponsorPlacement()),
                  ],
                  _header('NILE PRESETS'),
                  for (final g in StudioGraphicPresets.all)
                    _row(g, order, null),
                  _header('YOUR LIBRARY'),
                  if (lib == null)
                    const Padding(
                      padding: EdgeInsets.all(NileSpacing.s16),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (lib.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: NileSpacing.s24,
                        vertical: NileSpacing.s8,
                      ),
                      child: Text(
                        'Nothing saved yet. Add lower thirds, logos, banners, '
                        'slates and QR codes in the library.',
                        style: NileTextStyles.bodySm().copyWith(
                          color: NileColors.txtTertiary,
                        ),
                      ),
                    )
                  else
                    for (var i = 0; i < lib.length; i++)
                      _row(lib[i], order, i < 9 ? i + 1 : null),
                ],
              ),
            ),
            const Divider(height: 1),
            if (cue != null)
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
                        'Cued: ${cue.name} → ${cue.targets.summary(_labelOf, order)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NileTextStyles.bodyMd(),
                      ),
                    ),
                    TextButton(
                      onPressed: () => widget.cue.value = null,
                      child: const Text('Clear'),
                    ),
                    const SizedBox(width: NileSpacing.s8),
                    FilledButton(
                      onPressed: _busy ? null : _take,
                      style: FilledButton.styleFrom(
                        backgroundColor: NileColors.volt,
                        foregroundColor: NileColors.onVolt,
                      ),
                      child: const Text('Take'),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(NileSpacing.s12),
              child: Row(
                children: [
                  // Wraps rather than overflows in a narrow panel.
                  Expanded(
                    child: Wrap(
                      children: [
                        TextButton.icon(
                          onPressed: () async {
                            await showGraphicsLibrary(
                              context,
                              brandKit: _brandKit,
                              resolveLink: widget.resolveLink,
                            );
                            _loadLibrary();
                          },
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('Edit library'),
                        ),
                        TextButton.icon(
                          onPressed: _editBrandKit,
                          icon: const Icon(Icons.palette_outlined),
                          label: const Text('Brand kit'),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: _state.isEmpty || _busy ? null : _clearAll,
                    child: Text(
                      'Clear all',
                      style: NileTextStyles.labelMd().copyWith(
                        color: _state.isEmpty
                            ? NileColors.txtTertiary
                            : NileColors.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The sponsor's corner and size. A cued sponsor is re-cued to match.
  Widget _sponsorPlacement() => PopupMenuButton<(String, String)>(
    tooltip: 'Corner and size',
    icon: const Icon(Icons.open_with, size: 18),
    iconColor: NileColors.txtSecondary,
    color: NileColors.bgSurface,
    onSelected: (v) {
      setState(() {
        _sponsorCorner = v.$1;
        _sponsorSize = v.$2;
      });
      final s = _sponsor!, c = widget.cue.value;
      if (c != null && c.id == s.id)
        widget.cue.value = _cueOf(s, c.targets, null);
    },
    itemBuilder: (_) => [
      for (final c in logoCorners)
        CheckedPopupMenuItem(
          value: (c, _sponsorSize),
          checked: c == _sponsorCorner,
          child: Text(logoCornerLabels[c]!, style: NileTextStyles.bodyMd()),
        ),
      const PopupMenuDivider(),
      for (final s in const ['s', 'm', 'l'])
        CheckedPopupMenuItem(
          value: (_sponsorCorner, s),
          checked: s == _sponsorSize,
          child: Text(_sizeLabel(s), style: NileTextStyles.bodyMd()),
        ),
    ],
  );

  Widget _header(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(
      NileSpacing.s24,
      NileSpacing.s16,
      NileSpacing.s24,
      NileSpacing.s4,
    ),
    child: Text(
      text,
      style: NileTextStyles.labelSm().copyWith(
        color: NileColors.txtTertiary,
        letterSpacing: 1.5,
      ),
    ),
  );

  Widget _row(
    StudioGraphic g,
    List<String> order,
    int? hotkey, {
    Widget? extra,
  }) {
    final targets = _state.targetsOf(g.id);
    final on = !targets.isNone;
    final cue = widget.cue.value;
    final cued = cue != null && cue.id == g.id;
    final shown = cued && !on ? cue.targets : targets;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: NileSpacing.s24),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(
            graphicIcon(g.kind),
            color: on ? NileColors.volt : NileColors.txtSecondary,
          ),
          if (hotkey != null)
            Positioned(
              right: -8,
              bottom: -6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: NileColors.bgRaised,
                  border: Border.all(color: NileColors.borderStrong),
                  borderRadius: BorderRadius.circular(NileRadius.xs),
                ),
                child: Text(
                  '$hotkey',
                  style: NileTextStyles.caption().copyWith(
                    color: NileColors.txtPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              g.name,
              style: NileTextStyles.bodyMd(),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (cued) ...[
            const SizedBox(width: NileSpacing.s8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s4),
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
          ],
        ],
      ),
      subtitle: Text(
        graphicSubtitle(g),
        style: NileTextStyles.bodySm().copyWith(color: NileColors.txtTertiary),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?extra,
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _chooseCameras(g),
            icon: Icon(
              on
                  ? Icons.videocam
                  : cued
                  ? Icons.videocam_outlined
                  : Icons.videocam_off_outlined,
              size: 16,
              color: on
                  ? NileColors.volt
                  : cued
                  ? NileColors.txtSecondary
                  : NileColors.txtTertiary,
            ),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Text(
                shown.summary(_labelOf, order),
                overflow: TextOverflow.ellipsis,
                style: NileTextStyles.labelSm().copyWith(
                  color: on || cued
                      ? NileColors.txtPrimary
                      : NileColors.txtTertiary,
                ),
              ),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(
                color: on
                    ? NileColors.volt
                    : cued
                    ? NileColors.borderStrong
                    : NileColors.border,
              ),
              padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s8),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Library editor ───────────────────────────────────────────────────────────

/// Create, edit, reorder and delete the account's saved graphics. Reachable
/// from the Studio's Graphics panel and from Studio Preview. [brandKit] styles
/// the previews and gives new logos their image; [resolveLink] fills a QR
/// preview's `event` / `profile` link.
Future<void> showGraphicsLibrary(
  BuildContext context, {
  BrandKit? brandKit,
  String? Function(String source)? resolveLink,
}) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    backgroundColor: NileColors.bgSurface,
    insetPadding: const EdgeInsets.all(NileSpacing.s24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 860, maxHeight: 640),
      child: _LibraryEditor(brandKit: brandKit, resolveLink: resolveLink),
    ),
  ),
);

class _LibraryEditor extends StatefulWidget {
  const _LibraryEditor({this.brandKit, this.resolveLink});

  final BrandKit? brandKit;
  final String? Function(String source)? resolveLink;

  @override
  State<_LibraryEditor> createState() => _LibraryEditorState();
}

class _LibraryEditorState extends State<_LibraryEditor> {
  List<StudioGraphic>? _items;
  StudioGraphic? _editing; // the item, or a draft with id '' for a new one
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await GraphicsService.list();
      if (mounted) setState(() => _items = items);
    } catch (_) {
      if (mounted) {
        setState(() {
          _items = const [];
          _error = 'Couldn’t load your library.';
        });
      }
    }
  }

  void _newDraft(StudioGraphic template) {
    final logo = widget.brandKit?.logoPath;
    setState(
      () => _editing = StudioGraphic(
        id: '',
        kind: template.kind,
        name: template.name,
        payload: {
          ...template.payload,
          if (template.kind == GraphicKind.logo &&
              logo != null &&
              logo.isNotEmpty)
            'imagePath': logo,
        },
      ),
    );
  }

  /// A copy of [g] saved straight away, right after the original.
  Future<void> _duplicate(StudioGraphic g) async {
    final items = [...?_items];
    final at = items.indexWhere((x) => x.id == g.id) + 1;
    try {
      final name = g.name.length > 53 ? g.name.substring(0, 53) : g.name;
      final copy = await GraphicsService.create(
        kind: g.kind,
        name: '$name (copy)',
        payload: {...g.payload},
        sort: at,
      );
      items.insert(at, copy);
      await GraphicsService.reorder(items);
      if (!mounted) return;
      setState(() {
        _items = [
          for (var i = 0; i < items.length; i++) items[i].copyWith(sort: i),
        ];
        _editing = copy;
      });
    } catch (e) {
      if (mounted) {
        setState(
          () => _error =
              'Couldn’t duplicate it.${e is ArgumentError ? ' ${e.message}' : ''}',
        );
      }
    }
  }

  Future<void> _reorder(int from, int to) async {
    final items = [...?_items];
    items.insert(to, items.removeAt(from));
    setState(() => _items = items);
    try {
      await GraphicsService.reorder(items);
      _items = [
        for (var i = 0; i < items.length; i++) items[i].copyWith(sort: i),
      ];
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t save the new order.');
    }
  }

  Future<void> _saved() async {
    setState(() => _editing = null);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 640;
        final list = _buildList();
        final editor = _editing == null
            ? Center(
                child: Text(
                  'Pick a graphic to edit, or add a new one.',
                  style: NileTextStyles.bodyMd().copyWith(
                    color: NileColors.txtTertiary,
                  ),
                ),
              )
            : _GraphicEditor(
                key: ValueKey(_editing!.id.isEmpty ? _editing : _editing!.id),
                graphic: _editing!,
                brandKit: widget.brandKit,
                resolveLink: widget.resolveLink,
                nextSort: _items?.length ?? 0,
                onSaved: _saved,
                onCancel: () => setState(() => _editing = null),
                onDuplicate: _editing!.id.isEmpty
                    ? null
                    : () => _duplicate(_editing!),
              );
        if (!wide) return _editing == null ? list : editor;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 300, child: list),
            Container(width: 1, color: NileColors.border),
            Expanded(child: editor),
          ],
        );
      },
    );
  }

  Widget _buildList() {
    final items = _items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NileSpacing.s24,
            NileSpacing.s24,
            NileSpacing.s8,
            NileSpacing.s8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Graphics library',
                  style: NileTextStyles.headingMd(),
                ),
              ),
              PopupMenuButton<StudioGraphic>(
                tooltip: 'New graphic',
                icon: const Icon(Icons.add),
                iconColor: NileColors.volt,
                color: NileColors.bgSurface,
                onSelected: _newDraft,
                itemBuilder: (_) => [
                  for (final t in _templates)
                    PopupMenuItem(
                      value: t,
                      child: Row(
                        children: [
                          Icon(graphicIcon(t.kind), size: 18),
                          const SizedBox(width: NileSpacing.s8),
                          Text(t.name, style: NileTextStyles.bodyMd()),
                        ],
                      ),
                    ),
                ],
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
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s24),
            child: Text(
              _error!,
              style: NileTextStyles.bodySm().copyWith(color: NileColors.error),
            ),
          ),
        Expanded(
          child: items == null
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(NileSpacing.s24),
                  child: Text(
                    'Nothing here yet. Use + to add a lower third, logo, '
                    'banner, slate or QR code.',
                    style: NileTextStyles.bodySm().copyWith(
                      color: NileColors.txtTertiary,
                    ),
                  ),
                )
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: items.length,
                  onReorderItem: _reorder,
                  itemBuilder: (context, i) {
                    final g = items[i];
                    return ListTile(
                      key: ValueKey(g.id),
                      selected: _editing?.id == g.id,
                      selectedTileColor: NileColors.volt.withValues(
                        alpha: 0.08,
                      ),
                      leading: Icon(graphicIcon(g.kind)),
                      title: Text(
                        g.name,
                        style: NileTextStyles.bodyMd(),
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        graphicSubtitle(g),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: NileTextStyles.bodySm().copyWith(
                          color: NileColors.txtTertiary,
                        ),
                      ),
                      trailing: ReorderableDragStartListener(
                        index: i,
                        child: Icon(
                          Icons.drag_handle,
                          color: NileColors.txtTertiary,
                        ),
                      ),
                      onTap: () => setState(() => _editing = g),
                    );
                  },
                ),
        ),
      ],
    );
  }

  static const _templates = [
    StudioGraphic(
      id: '',
      kind: GraphicKind.lowerThird,
      name: 'Lower third',
      // New lower thirds come down by themselves; everything else stays up.
      payload: {
        'title': 'Name',
        'subtitle': 'Title or handle',
        'autoHideSeconds': 8,
      },
    ),
    StudioGraphic(
      id: '',
      kind: GraphicKind.logo,
      name: 'Logo / image',
      payload: {'corner': 'tr', 'size': 'm'},
    ),
    StudioGraphic(
      id: '',
      kind: GraphicKind.banner,
      name: 'Banner',
      payload: {'text': 'Your message here', 'scrolling': false},
    ),
    StudioGraphic(
      id: '',
      kind: GraphicKind.banner,
      name: 'Ticker (scrolling)',
      payload: {'text': 'Your message here', 'scrolling': true},
    ),
    StudioGraphic(
      id: '',
      kind: GraphicKind.slate,
      name: 'Slate',
      payload: {'title': 'Starting soon'},
    ),
    StudioGraphic(
      id: '',
      kind: GraphicKind.slate,
      name: 'Countdown slate',
      payload: {
        'title': 'Starting in',
        'countdown': {'mode': 'duration', 'seconds': 300},
      },
    ),
    StudioGraphic(
      id: '',
      kind: GraphicKind.qr,
      name: 'QR code',
      payload: {'source': 'event', 'corner': 'br', 'size': 'm'},
    ),
  ];
}

class _GraphicEditor extends StatefulWidget {
  const _GraphicEditor({
    super.key,
    required this.graphic,
    required this.nextSort,
    required this.onSaved,
    required this.onCancel,
    this.onDuplicate,
    this.brandKit,
    this.resolveLink,
  });

  final StudioGraphic graphic;
  final BrandKit? brandKit;
  final String? Function(String source)? resolveLink;
  final int nextSort;
  final VoidCallback onSaved;
  final VoidCallback onCancel;
  final VoidCallback? onDuplicate;

  @override
  State<_GraphicEditor> createState() => _GraphicEditorState();
}

class _GraphicEditorState extends State<_GraphicEditor> {
  late final _name = TextEditingController(text: widget.graphic.name);
  late final Map<String, dynamic> _p = {...widget.graphic.payload};
  late final _title = TextEditingController(text: _p['title'] as String? ?? '');
  late final _subtitle = TextEditingController(
    text: _p['subtitle'] as String? ?? '',
  );
  late final _text = TextEditingController(text: _p['text'] as String? ?? '');
  late final _url = TextEditingController(text: _p['url'] as String? ?? '');
  late final _caption = TextEditingController(
    text: _p['caption'] as String? ?? '',
  );

  // Countdown (slates). Older items carry countdownSeconds; it reads as a
  // length and is saved back in the new shape.
  late CountdownMode? _cdMode = switch (_p['countdown']) {
    Map cd => CountdownMode.fromWire(cd['mode']),
    _ => _p['countdownSeconds'] == null ? null : CountdownMode.duration,
  };
  late final _minutes = TextEditingController(
    text: switch (_p['countdown']) {
      {'seconds': final num s} => (s / 60).toStringAsFixed(0),
      _ =>
        _p['countdownSeconds'] == null
            ? '5'
            : ((_p['countdownSeconds'] as num) / 60).toStringAsFixed(0),
    },
  );
  late String _clockAt = switch (_p['countdown']) {
    {'at': final String at} => at,
    _ => '19:00',
  };
  late int _autoHide = (_p['autoHideSeconds'] as num?)?.toInt() ?? 0;
  bool _busy = false;
  String? _error;

  GraphicKind get _kind => widget.graphic.kind;
  bool get _isNew => widget.graphic.id.isEmpty;

  @override
  void dispose() {
    for (final c in [
      _name,
      _title,
      _subtitle,
      _text,
      _url,
      _caption,
      _minutes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic>? get _countdown => switch (_cdMode) {
    CountdownMode.duration => {
      'mode': 'duration',
      'seconds': ((int.tryParse(_minutes.text.trim()) ?? 0) * 60).clamp(
        0,
        86400,
      ),
    },
    CountdownMode.clock => {'mode': 'clock', 'at': _clockAt},
    CountdownMode.showStart => {'mode': 'showStart'},
    null => null,
  };

  Map<String, dynamic> get _payload {
    String? opt(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    return {
      ..._kindPayload(opt),
      if (_autoHide > 0) 'autoHideSeconds': _autoHide,
      if (_p['nileStyle'] == true) 'nileStyle': true,
    };
  }

  /// A QR code's link source; saved items without one carry their own link.
  String get _qrSource => _p['source'] as String? ?? 'custom';

  Map<String, dynamic> _kindPayload(
    String? Function(TextEditingController) opt,
  ) {
    return switch (_kind) {
      GraphicKind.chat || GraphicKind.sponsor => const {},
      GraphicKind.qr => {
        'source': _qrSource,
        if (_qrSource == 'custom') 'url': ?opt(_url),
        'corner': _p['corner'] ?? 'br',
        'size': _p['size'] ?? 'm',
        'caption': ?opt(_caption),
      },
      GraphicKind.lowerThird => {
        'title': _title.text.trim(),
        'subtitle': ?opt(_subtitle),
      },
      GraphicKind.logo => {
        'imagePath': ?_p['imagePath'],
        'corner': _p['corner'] ?? 'tr',
        'size': _p['size'] ?? 'm',
      },
      GraphicKind.banner => {
        'text': _text.text.trim(),
        'scrolling': _p['scrolling'] == true,
      },
      GraphicKind.slate => {
        'title': _title.text.trim(),
        'subtitle': ?opt(_subtitle),
        'imagePath': ?_p['imagePath'],
        'countdown': ?_countdown,
      },
    };
  }

  Future<void> _pickClock() async {
    final hm = parseClock(_clockAt) ?? (19, 0);
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: hm.$1, minute: hm.$2),
    );
    if (t == null) return;
    setState(
      () => _clockAt =
          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
    );
  }

  Widget _countdownEditor() {
    final hm = parseClock(_clockAt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Countdown', style: NileTextStyles.labelMd()),
        const SizedBox(height: NileSpacing.s8),
        SegmentedButton<CountdownMode?>(
          segments: const [
            ButtonSegment(value: null, label: Text('None')),
            ButtonSegment(value: CountdownMode.duration, label: Text('Length')),
            ButtonSegment(
              value: CountdownMode.clock,
              label: Text('Time of day'),
            ),
            ButtonSegment(
              value: CountdownMode.showStart,
              label: Text('Show start'),
            ),
          ],
          selected: {_cdMode},
          onSelectionChanged: (s) => setState(() => _cdMode = s.first),
        ),
        const SizedBox(height: NileSpacing.s12),
        switch (_cdMode) {
          CountdownMode.duration => _field(
            _minutes,
            'Minutes',
            keyboard: TextInputType.number,
          ),
          CountdownMode.clock => Padding(
            padding: const EdgeInsets.only(bottom: NileSpacing.s12),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _pickClock,
                  icon: const Icon(Icons.schedule),
                  label: Text(
                    hm == null
                        ? 'Pick a time'
                        : TimeOfDay(hour: hm.$1, minute: hm.$2).format(context),
                  ),
                ),
                const SizedBox(width: NileSpacing.s12),
                Expanded(
                  child: Text(
                    'Counts to the next time your clock shows this. Viewers '
                    'see the time in their own time zone.',
                    style: NileTextStyles.bodySm().copyWith(
                      color: NileColors.txtTertiary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          CountdownMode.showStart => Padding(
            padding: const EdgeInsets.only(bottom: NileSpacing.s12),
            child: Text(
              'Counts to the show’s scheduled start time.',
              style: NileTextStyles.bodySm().copyWith(
                color: NileColors.txtTertiary,
              ),
            ),
          ),
          null => const SizedBox.shrink(),
        },
      ],
    );
  }

  Widget _autoHideRow() => Padding(
    padding: const EdgeInsets.only(bottom: NileSpacing.s12),
    child: Row(
      children: [
        Text('Hide after', style: NileTextStyles.bodyMd()),
        const SizedBox(width: NileSpacing.s12),
        DropdownButton<int>(
          value: autoHideChoices.contains(_autoHide) ? _autoHide : 0,
          dropdownColor: NileColors.bgRaised,
          items: [
            for (final c in autoHideChoices)
              DropdownMenuItem(value: c, child: Text(autoHideLabel(c))),
          ],
          onChanged: (v) => setState(() => _autoHide = v ?? 0),
        ),
        const SizedBox(width: NileSpacing.s12),
        Expanded(
          child: Text(
            'You can change it each time you put it on.',
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtTertiary,
            ),
          ),
        ),
      ],
    ),
  );

  Future<void> _upload() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final path = await GraphicsService.pickAndUploadImage();
      if (path != null) setState(() => _p['imagePath'] = path);
    } catch (e) {
      setState(
        () => _error = e is ArgumentError ? '${e.message}' : 'Upload failed.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final payload = _payload;
    final name = _name.text.trim();
    final error = name.isEmpty
        ? 'Give it a name.'
        : StudioGraphic.validate(_kind, payload);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() => _busy = true);
    try {
      if (_isNew) {
        await GraphicsService.create(
          kind: _kind,
          name: name,
          payload: payload,
          sort: widget.nextSort,
        );
      } else {
        await GraphicsService.update(
          widget.graphic.copyWith(name: name, payload: payload),
        );
      }
      widget.onSaved();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Couldn’t save. ${e is ArgumentError ? e.message : ''}';
        });
      }
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text(
          'Delete “${widget.graphic.name}”?',
          style: NileTextStyles.headingMd(),
        ),
        content: Text(
          'If it’s on screen in a show right now, it stays up until you turn '
          'it off.',
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
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await GraphicsService.delete(widget.graphic);
      widget.onSaved();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Couldn’t delete it.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = LiveGraphic.snapshot(
      StudioGraphic(id: 'preview', kind: _kind, name: '', payload: _payload),
      publicUrl: GraphicsService.publicUrl,
      now: DateTime.now(),
      // The preview stays up while you edit, whatever the auto-hide says.
      autoHideSeconds: 0,
      // A stand-in when the show's link isn't known here (preview only).
      resolveLink: (s) =>
          widget.resolveLink?.call(s) ?? 'https://links.joinnile.com',
    );
    return ListView(
      padding: const EdgeInsets.all(NileSpacing.s24),
      children: [
        Row(
          children: [
            Icon(graphicIcon(_kind), color: NileColors.txtSecondary),
            const SizedBox(width: NileSpacing.s8),
            Text(_kind.label, style: NileTextStyles.headingSm()),
          ],
        ),
        const SizedBox(height: NileSpacing.s12),
        // Live preview on a stand-in 16:9 frame.
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(NileRadius.md),
            child: Container(
              color: NileColors.bgRaised,
              child: NileGraphicsLayer(
                graphics: [preview.withBrand(widget.brandKit?.style)],
              ),
            ),
          ),
        ),
        const SizedBox(height: NileSpacing.s16),
        _field(_name, 'Name in your library', max: 60),
        ...switch (_kind) {
          GraphicKind.lowerThird => [
            _field(_title, 'Title', max: 60),
            _field(_subtitle, 'Subtitle (optional)', max: 80),
          ],
          GraphicKind.banner => [
            _field(_text, 'Banner text', max: 140),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Scroll like a ticker',
                style: NileTextStyles.bodyMd(),
              ),
              value: _p['scrolling'] == true,
              activeThumbColor: NileColors.volt,
              onChanged: (v) => setState(() => _p['scrolling'] = v),
            ),
          ],
          GraphicKind.logo => [
            _imageRow(required: true),
            const SizedBox(height: NileSpacing.s12),
            ..._placement('tr'),
          ],
          GraphicKind.qr => [
            DropdownButtonFormField<String>(
              initialValue: _qrSource,
              decoration: const InputDecoration(labelText: 'Link'),
              items: [
                for (final e in qrSources.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _p['source'] = v),
            ),
            const SizedBox(height: NileSpacing.s12),
            if (_qrSource == 'custom')
              _field(
                _url,
                'URL (https://…)',
                max: 500,
                keyboard: TextInputType.url,
              ),
            ..._placement('br'),
            const SizedBox(height: NileSpacing.s12),
            _field(_caption, 'Caption (optional)', max: 40),
          ],
          GraphicKind.slate => [
            _field(_title, 'Title', max: 60),
            _field(_subtitle, 'Subtitle (optional)', max: 120),
            _countdownEditor(),
            _imageRow(required: false),
          ],
          GraphicKind.chat || GraphicKind.sponsor => const <Widget>[],
        },
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Use Nile style', style: NileTextStyles.bodyMd()),
          subtitle: Text(
            'Ignore the brand kit for this graphic',
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtTertiary,
            ),
          ),
          value: _p['nileStyle'] == true,
          activeThumbColor: NileColors.volt,
          onChanged: (v) => setState(
            () => v ? _p['nileStyle'] = true : _p.remove('nileStyle'),
          ),
        ),
        const SizedBox(height: NileSpacing.s12),
        _autoHideRow(),
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
            if (!_isNew)
              TextButton(
                onPressed: _busy ? null : _delete,
                child: Text(
                  'Delete',
                  style: TextStyle(color: NileColors.error),
                ),
              ),
            if (widget.onDuplicate != null)
              TextButton.icon(
                onPressed: _busy ? null : widget.onDuplicate,
                icon: const Icon(Icons.copy_outlined, size: 16),
                label: const Text('Duplicate'),
              ),
            const Spacer(),
            TextButton(
              onPressed: _busy ? null : widget.onCancel,
              child: const Text('Cancel'),
            ),
            const SizedBox(width: NileSpacing.s8),
            FilledButton(
              onPressed: _busy ? null : _save,
              style: FilledButton.styleFrom(
                backgroundColor: NileColors.volt,
                foregroundColor: NileColors.onVolt,
              ),
              child: Text(_isNew ? 'Add to library' : 'Save'),
            ),
          ],
        ),
      ],
    );
  }

  /// Corner and size (logos and QR codes).
  List<Widget> _placement(String defaultCorner) => [
    DropdownButtonFormField<String>(
      initialValue: _p['corner'] as String? ?? defaultCorner,
      decoration: const InputDecoration(labelText: 'Corner'),
      items: [
        for (final c in logoCorners)
          DropdownMenuItem(value: c, child: Text(logoCornerLabels[c]!)),
      ],
      onChanged: (v) => setState(() => _p['corner'] = v),
    ),
    const SizedBox(height: NileSpacing.s12),
    SegmentedButton<String>(
      segments: [
        for (final s in const ['s', 'm', 'l'])
          ButtonSegment(value: s, label: Text(_sizeLabel(s))),
      ],
      selected: {_p['size'] as String? ?? 'm'},
      onSelectionChanged: (s) => setState(() => _p['size'] = s.first),
    ),
  ];

  Widget _field(
    TextEditingController c,
    String label, {
    int? max,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: NileSpacing.s12),
    child: TextField(
      controller: c,
      maxLength: max,
      keyboardType: keyboard,
      style: NileTextStyles.bodyLg(),
      decoration: InputDecoration(labelText: label, counterText: ''),
      onChanged: (_) => setState(() {}),
    ),
  );

  Widget _imageRow({required bool required}) {
    final has = (_p['imagePath'] as String?)?.isNotEmpty ?? false;
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: _busy ? null : _upload,
          icon: const Icon(Icons.upload_outlined),
          label: Text(has ? 'Replace image' : 'Upload image'),
        ),
        const SizedBox(width: NileSpacing.s12),
        Expanded(
          child: Text(
            has
                ? 'Image uploaded'
                : required
                ? 'PNG, JPG or WebP, up to 2 MB'
                : 'Optional background image',
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtTertiary,
            ),
          ),
        ),
        if (has && !required)
          IconButton(
            tooltip: 'Remove image',
            icon: const Icon(Icons.close),
            onPressed: () => setState(() => _p.remove('imagePath')),
          ),
      ],
    );
  }
}
