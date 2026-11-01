import 'package:flutter/material.dart';

import '../services/live_elements.dart';
import '../services/overlay_layout.dart';
import '../services/studio_layouts.dart';
import '../services/studio_layouts_controller.dart';
import '../theme.dart';
import 'nile_studio.dart' show graphicKindIcon;
import 'studio_layers_sheet.dart' show SpotGrid;
import 'studio_layouts_panel.dart' show LayoutThumbnail;

/// The layout editor (docs/plans/studio-layouts.md, phase 5): a tab per camera
/// position with a live preview, its graphics and elements as a layer list
/// (spot, hide, remove, drag to reorder), on/off air, and the layout-wide
/// settings — element angles, default angle and camera order. Returns the
/// edited layout, or null when cancelled; the caller saves it.
Future<StudioLayout?> showLayoutEditor(
  BuildContext context, {
  required StudioLayout layout,
  required StudioLayoutsController controller,
  bool onAir = false,
}) => showDialog<StudioLayout>(
  context: context,
  builder: (_) => Dialog(
    backgroundColor: NileColors.bgSurface,
    insetPadding: const EdgeInsets.all(NileSpacing.s24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720, maxHeight: 820),
      child: LayoutEditor(layout: layout, controller: controller, onAir: onAir),
    ),
  ),
);

class LayoutEditor extends StatefulWidget {
  const LayoutEditor({
    super.key,
    required this.layout,
    required this.controller,
    this.onAir = false,
  });

  final StudioLayout layout;
  final StudioLayoutsController controller;

  /// It is on air: saving doesn't change the show until it is applied again.
  final bool onAir;

  @override
  State<LayoutEditor> createState() => _LayoutEditorState();
}

class _LayoutEditorState extends State<LayoutEditor> {
  late final _name = TextEditingController(text: widget.layout.name);
  late List<LayoutCamera> _cameras = widget.layout.cameras.isEmpty
      ? const [LayoutCamera()]
      : [...widget.layout.cameras];
  late final Set<String> _angles = {...widget.layout.angles};
  late AngleRef? _default = widget.layout.defaultAngle;
  late List<AngleRef> _order = [...widget.layout.order];
  late bool _setOrder = widget.layout.order.isNotEmpty;
  int _tab = 0;
  String? _error;

  StudioLayoutsController get _c => widget.controller;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  StudioLayout get _draft => widget.layout.copyWith(
    name: _name.text,
    cameras: _cameras,
    angles: [
      for (final e in _c.elementsLibrary.keys)
        if (_angles.contains(e)) e,
      // Angles whose element was deleted stay until removed here.
      for (final a in widget.layout.angles)
        if (_angles.contains(a) && !_c.elementsLibrary.containsKey(a)) a,
    ],
    defaultAngle: _validDefault,
    clearDefault: _validDefault == null,
    order: _setOrder ? _normalizedOrder : const [],
  );

  AngleRef? get _validDefault {
    final d = _default;
    if (d == null) return null;
    if (d.camera != null) return d.camera! <= _cameras.length ? d : null;
    return _angles.contains(d.element) ? d : null;
  }

  /// Every camera and angle once, in the order chosen so far.
  List<AngleRef> get _normalizedOrder {
    final all = [
      for (var i = 1; i <= _cameras.length; i++) AngleRef.camera(i),
      for (final a in _angles) AngleRef.element(a),
    ];
    return [
      for (final r in _order)
        if (all.contains(r)) r,
      for (final r in all)
        if (!_order.contains(r)) r,
    ];
  }

  void _setCamera(int i, LayoutCamera cam) =>
      setState(() => _cameras = [..._cameras]..[i] = cam);

  LayoutCamera get _cam => _cameras[_tab];

  void _setItems(List<LayoutItem> items) =>
      _setCamera(_tab, LayoutCamera(items: items, onAir: _cam.onAir));

  void _save() {
    final l = _draft;
    final error = l.error;
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, l);
  }

  // ── Items ──────────────────────────────────────────────────────────────────

  String _nameOf(LayoutItem i) =>
      (i.isGraphic
          ? _c.graphicsLibrary[i.ref]?.name
          : _c.elementsLibrary[i.ref]?.name) ??
      'Deleted from your library';

  List<LayoutSpot> _allowed(LayoutItem i) {
    final g = _c.graphicsLibrary[i.ref];
    return i.isGraphic
        ? (g == null ? const [] : allowedGraphicSpots(g.kind))
        : allowedElementSpots;
  }

  LayoutSpot? _defaultSpot(LayoutItem i) {
    if (i.isGraphic) {
      final g = _c.graphicsLibrary[i.ref];
      return g == null ? null : defaultGraphicSpot(_c.build(g, 0));
    }
    final e = _c.elementsLibrary[i.ref];
    return e == null ? null : ElementKinds.of(e.kind)?.defaultSpot;
  }

  Future<void> _pickSpot(int index, LayoutItem item) async {
    final allowed = _allowed(item);
    final current = item.spot ?? _defaultSpot(item) ?? LayoutSpot.tr;
    final s = await showDialog<LayoutSpot>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text('Where it sits', style: NileTextStyles.headingMd()),
        content: SpotGrid(
          allowed: allowed,
          selected: current,
          onPick: (s) => Navigator.pop(ctx, s),
        ),
      ),
    );
    if (s == null || !mounted) return;
    _replaceItem(index, _with(item, spot: s));
  }

  LayoutItem _with(LayoutItem i, {LayoutSpot? spot, bool? hidden}) =>
      i.isGraphic
      ? LayoutItem.graphic(
          i.ref,
          spot: spot ?? i.spot,
          hidden: hidden ?? i.hidden,
          autoHide: i.autoHide,
        )
      : LayoutItem.element(
          i.ref,
          spot: spot ?? i.spot,
          hidden: hidden ?? i.hidden,
        );

  void _replaceItem(int index, LayoutItem item) =>
      _setItems([..._cam.items]..[index] = item);

  void _add(LayoutItem item) => _setItems([item, ..._cam.items]);

  void _copyToAll() => setState(
    () => _cameras = [
      for (final c in _cameras) LayoutCamera(items: _cam.items, onAir: c.onAir),
    ],
  );

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NileSpacing.s24,
            NileSpacing.s16,
            NileSpacing.s12,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _name,
                  maxLength: 60,
                  style: NileTextStyles.headingMd(),
                  decoration: const InputDecoration(
                    hintText: 'Layout name',
                    counterText: '',
                    border: InputBorder.none,
                  ),
                ),
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
        if (widget.onAir)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s24),
            child: Text(
              'This layout is on air. Saving doesn’t change the show — Apply '
              'it again to send your changes.',
              style: NileTextStyles.bodySm().copyWith(
                color: NileColors.warning,
              ),
            ),
          ),
        _tabs(),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(NileSpacing.s24),
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: LayoutThumbnail(
                  layout: _draft,
                  controller: _c,
                  camera: _tab,
                ),
              ),
              const SizedBox(height: NileSpacing.s8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('On air'),
                subtitle: const Text(
                  'Off air: viewers can’t pick this camera while the layout '
                  'is up.',
                ),
                value: _cam.onAir,
                activeThumbColor: NileColors.volt,
                onChanged: (v) =>
                    _setCamera(_tab, LayoutCamera(items: _cam.items, onAir: v)),
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'ON THIS CAMERA',
                      style: NileTextStyles.labelSm().copyWith(
                        color: NileColors.txtTertiary,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  if (_cameras.length > 1)
                    TextButton.icon(
                      onPressed: _copyToAll,
                      icon: const Icon(Icons.copy_all_outlined, size: 18),
                      label: const Text('Copy to all cameras'),
                    ),
                  _addMenu(),
                ],
              ),
              if (_cam.items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: NileSpacing.s12,
                  ),
                  child: Text(
                    'Nothing on this camera. Add graphics or elements from '
                    'your library.',
                    style: NileTextStyles.bodySm().copyWith(
                      color: NileColors.txtSecondary,
                    ),
                  ),
                )
              else
                ReorderableListView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  onReorderItem: (from, to) {
                    final items = [..._cam.items];
                    items.insert(to, items.removeAt(from));
                    _setItems(items);
                  },
                  children: [
                    for (final (i, item) in _cam.items.indexed) _row(i, item),
                  ],
                ),
              const SizedBox(height: NileSpacing.s16),
              const Divider(height: 1),
              const SizedBox(height: NileSpacing.s16),
              ..._showSettings(),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(NileSpacing.s12),
          child: Row(
            children: [
              if (_error != null)
                Expanded(
                  child: Text(
                    _error!,
                    style: NileTextStyles.bodySm().copyWith(
                      color: NileColors.error,
                    ),
                  ),
                )
              else
                const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: NileSpacing.s8),
              FilledButton(
                onPressed: _save,
                style: FilledButton.styleFrom(
                  backgroundColor: NileColors.volt,
                  foregroundColor: NileColors.onVolt,
                ),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tabs() => Padding(
    padding: const EdgeInsets.fromLTRB(
      NileSpacing.s24,
      NileSpacing.s8,
      NileSpacing.s24,
      NileSpacing.s8,
    ),
    child: Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < _cameras.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: NileSpacing.s8),
                    child: ChoiceChip(
                      label: Text(
                        'Camera ${i + 1}${_cameras[i].onAir ? '' : ' · off'}',
                      ),
                      selected: i == _tab,
                      onSelected: (_) => setState(() => _tab = i),
                    ),
                  ),
              ],
            ),
          ),
        ),
        IconButton(
          tooltip: 'Remove the last camera',
          icon: const Icon(Icons.remove),
          onPressed: _cameras.length <= 1
              ? null
              : () => setState(() {
                  _cameras = _cameras.sublist(0, _cameras.length - 1);
                  if (_tab >= _cameras.length) _tab = _cameras.length - 1;
                }),
        ),
        IconButton(
          tooltip: 'Add a camera',
          icon: const Icon(Icons.add),
          onPressed: _cameras.length >= StudioLayout.maxCameras
              ? null
              : () => setState(() {
                  _cameras = [..._cameras, const LayoutCamera()];
                  _tab = _cameras.length - 1;
                }),
        ),
      ],
    ),
  );

  Widget _addMenu() {
    final on = {for (final i in _cam.items) i.ref};
    final graphics = [
      for (final g in _c.graphicsLibrary.values)
        if (!on.contains(g.id)) g,
    ];
    final elements = [
      for (final e in _c.elementsLibrary.values)
        if (!on.contains(e.id)) e,
    ];
    return PopupMenuButton<LayoutItem>(
      tooltip: 'Add from your library',
      enabled: graphics.isNotEmpty || elements.isNotEmpty,
      onSelected: _add,
      itemBuilder: (_) => [
        for (final g in graphics)
          PopupMenuItem(
            value: LayoutItem.graphic(g.id),
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(graphicKindIcon(g.kind)),
              title: Text(g.name),
            ),
          ),
        if (graphics.isNotEmpty && elements.isNotEmpty)
          const PopupMenuDivider(),
        for (final e in elements)
          PopupMenuItem(
            value: LayoutItem.element(e.id),
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.widgets_outlined),
              title: Text(e.name),
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NileSpacing.s8,
          vertical: NileSpacing.s8,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 18, color: NileColors.volt),
            const SizedBox(width: NileSpacing.s4),
            Text(
              'Add',
              style: NileTextStyles.labelMd().copyWith(color: NileColors.volt),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(int index, LayoutItem item) {
    final g = item.isGraphic ? _c.graphicsLibrary[item.ref] : null;
    final known = item.isGraphic
        ? g != null
        : _c.elementsLibrary.containsKey(item.ref);
    final spot = item.spot ?? _defaultSpot(item);
    final allowed = _allowed(item);
    final dim = item.hidden || !known;
    return ListTile(
      key: ValueKey('${item.type.name}:${item.ref}'),
      contentPadding: EdgeInsets.zero,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ReorderableDragStartListener(
            index: index,
            child: Icon(
              Icons.drag_indicator,
              color: NileColors.txtTertiary,
              semanticLabel: 'Drag to reorder',
            ),
          ),
          const SizedBox(width: NileSpacing.s8),
          Icon(
            g != null ? graphicKindIcon(g.kind) : Icons.widgets_outlined,
            color: dim ? NileColors.txtTertiary : NileColors.txtSecondary,
          ),
        ],
      ),
      title: Text(
        _nameOf(item),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: NileTextStyles.bodyMd().copyWith(
          color: dim ? NileColors.txtTertiary : null,
        ),
      ),
      subtitle: Text(
        index == 0 ? 'Front' : 'Layer ${index + 1}',
        style: NileTextStyles.caption().copyWith(color: NileColors.txtTertiary),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (spot != null)
            TextButton(
              onPressed: allowed.length > 1
                  ? () => _pickSpot(index, item)
                  : null,
              child: Text(spot.label, style: NileTextStyles.labelSm()),
            ),
          IconButton(
            tooltip: item.hidden ? 'Show' : 'Hide',
            icon: Icon(
              item.hidden
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
            color: NileColors.txtSecondary,
            onPressed: () =>
                _replaceItem(index, _with(item, hidden: !item.hidden)),
          ),
          IconButton(
            tooltip: 'Remove from this camera',
            icon: const Icon(Icons.close),
            color: NileColors.txtSecondary,
            onPressed: () => _setItems([..._cam.items]..removeAt(index)),
          ),
        ],
      ),
    );
  }

  List<Widget> _showSettings() {
    String label(AngleRef r) => r.camera != null
        ? 'Camera ${r.camera}'
        : '${_c.elementsLibrary[r.element]?.name ?? 'Element'} (angle)';
    final defaults = <AngleRef?>[
      null,
      for (var i = 1; i <= _cameras.length; i++) AngleRef.camera(i),
      for (final a in _angles) AngleRef.element(a),
    ];
    final heading = NileTextStyles.labelSm().copyWith(
      color: NileColors.txtTertiary,
      letterSpacing: 1.2,
    );
    return [
      Text('ELEMENTS AS THEIR OWN ANGLE', style: heading),
      const SizedBox(height: NileSpacing.s8),
      if (_c.elementsLibrary.isEmpty)
        Text(
          'No elements in your library.',
          style: NileTextStyles.bodySm().copyWith(
            color: NileColors.txtSecondary,
          ),
        )
      else
        Wrap(
          spacing: NileSpacing.s8,
          runSpacing: NileSpacing.s8,
          children: [
            for (final e in _c.elementsLibrary.values)
              FilterChip(
                label: Text(e.name),
                selected: _angles.contains(e.id),
                onSelected: (on) => setState(
                  () => on ? _angles.add(e.id) : _angles.remove(e.id),
                ),
              ),
          ],
        ),
      const SizedBox(height: NileSpacing.s16),
      Text('NEW VIEWERS START ON', style: heading),
      DropdownButton<AngleRef?>(
        value: defaults.contains(_validDefault) ? _validDefault : null,
        isExpanded: true,
        items: [
          for (final r in defaults)
            DropdownMenuItem(
              value: r,
              child: Text(r == null ? 'The first camera on air' : label(r)),
            ),
        ],
        onChanged: (r) => setState(() => _default = r),
      ),
      const SizedBox(height: NileSpacing.s8),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Set the camera order'),
        subtitle: const Text('Off: Apply leaves the order as it is.'),
        value: _setOrder,
        activeThumbColor: NileColors.volt,
        onChanged: (v) => setState(() {
          _setOrder = v;
          if (v) _order = _normalizedOrder;
        }),
      ),
      if (_setOrder)
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: (from, to) => setState(() {
            final list = _normalizedOrder;
            list.insert(to, list.removeAt(from));
            _order = list;
          }),
          children: [
            for (final (i, r) in _normalizedOrder.indexed)
              ListTile(
                key: ValueKey(r),
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: ReorderableDragStartListener(
                  index: i,
                  child: Icon(
                    Icons.drag_indicator,
                    color: NileColors.txtTertiary,
                  ),
                ),
                title: Text(label(r)),
              ),
          ],
        ),
    ];
  }
}
