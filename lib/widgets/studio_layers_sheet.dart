import 'package:flutter/material.dart';

import '../services/live_elements.dart';
import '../services/overlay_layout.dart';
import '../services/studio_graphics.dart';
import '../theme.dart';
import 'nile_graphics_layer.dart';
import 'nile_studio.dart' show graphicKindIcon;

/// What the Layers sheet came back with.
typedef LayersChoice = ({List<LayerEntry> layers, bool copyToAll});

/// A camera tile's "Layers…" (studio live elements, phase 2): a small screen
/// preview, and every graphic and element on that camera as a layer list —
/// drag to reorder (top = front), pick a spot, eye to hide. "Copy to all"
/// gives every camera the same layers. The Studio warns when something covers
/// something else but never blocks it.
///
/// Returns null when cancelled.
Future<LayersChoice?> showLayersSheet(
  BuildContext context, {
  required String cameraLabel,
  required List<LiveGraphic> graphics,
  List<LiveElement> elements = const [],
  required List<LayerEntry> layers,
}) => showDialog<LayersChoice>(
  context: context,
  builder: (_) => Dialog(
    backgroundColor: NileColors.bgSurface,
    insetPadding: const EdgeInsets.all(NileSpacing.s24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
      child: _LayersSheet(
        cameraLabel: cameraLabel,
        graphics: graphics,
        elements: elements,
        layers: layers,
      ),
    ),
  ),
);

/// The layer list the sheet starts from: everything on this camera, front to
/// back as it is drawn now (hidden items included, where they would be).
/// Entries for items not on this camera right now are kept, after the rest, so
/// a graphic that comes back returns to its spot.
List<LayerEntry> initialLayers({
  required List<LiveGraphic> graphics,
  required List<LiveElement> elements,
  required List<LayerEntry> layers,
}) {
  final byId = {for (final l in layers) l.id: l};
  final placed = placeOverlay(
    graphics: graphics,
    elements: elements,
    layers: [for (final l in layers) l.copyWith(hidden: false)],
  ).reversed.toList();
  final shown = {for (final p in placed) p.id};
  return [
    for (final p in placed)
      LayerEntry(
        p.id,
        spot: byId[p.id]?.spot,
        hidden: byId[p.id]?.hidden ?? false,
      ),
    for (final l in layers)
      if (!shown.contains(l.id)) l,
  ];
}

class _LayersSheet extends StatefulWidget {
  const _LayersSheet({
    required this.cameraLabel,
    required this.graphics,
    required this.elements,
    required this.layers,
  });

  final String cameraLabel;
  final List<LiveGraphic> graphics;
  final List<LiveElement> elements;
  final List<LayerEntry> layers;

  @override
  State<_LayersSheet> createState() => _LayersSheetState();
}

class _LayersSheetState extends State<_LayersSheet> {
  late List<LayerEntry> _draft = initialLayers(
    graphics: widget.graphics,
    elements: widget.elements,
    layers: widget.layers,
  );

  /// Every item on this camera, by id.
  late final Map<String, PlacedItem> _items = {
    for (final p in placeOverlay(
      graphics: widget.graphics,
      elements: widget.elements,
    ))
      p.id: p,
  };

  List<LayerEntry> get _visibleRows => [
    for (final l in _draft)
      if (_items.containsKey(l.id)) l,
  ];

  void _set(LayerEntry next) => setState(
    () => _draft = [for (final l in _draft) l.id == next.id ? next : l],
  );

  void _reorder(int from, int to) {
    final rows = _visibleRows;
    final moved = rows.removeAt(from);
    rows.insert(to, moved);
    final rest = [
      for (final l in _draft)
        if (!_items.containsKey(l.id)) l,
    ];
    setState(() => _draft = [...rows, ...rest]);
  }

  Future<void> _pickSpot(
    LayerEntry entry,
    List<LayoutSpot> allowed,
    LayoutSpot current,
  ) async {
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
    if (s != null && mounted) _set(entry.copyWith(spot: s));
  }

  List<LayoutSpot> _allowed(PlacedItem p) => p.graphic != null
      ? allowedGraphicSpots(p.graphic!.kind)
      : allowedElementSpots;

  @override
  Widget build(BuildContext context) {
    final placed = placeOverlay(
      graphics: widget.graphics,
      elements: widget.elements,
      layers: _draft,
    );
    final warnings = layoutWarnings(placed);
    final rows = _visibleRows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NileSpacing.s24,
            NileSpacing.s24,
            NileSpacing.s12,
            NileSpacing.s8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Layers · ${widget.cameraLabel}',
                  style: NileTextStyles.headingMd(),
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s24),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(NileRadius.md),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Video is dark in both themes.
                  ColoredBox(color: NilePalette.dark.bgRaised),
                  const _Grid(),
                  NileGraphicsLayer(
                    graphics: widget.graphics,
                    elements: widget.elements,
                    layers: _draft,
                  ),
                ],
              ),
            ),
          ),
        ),
        for (final w in warnings)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NileSpacing.s24,
              NileSpacing.s8,
              NileSpacing.s24,
              0,
            ),
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
        const SizedBox(height: NileSpacing.s8),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Text(
                    'Nothing on this camera yet. Put graphics or elements on '
                    'air, then arrange them here.',
                    textAlign: TextAlign.center,
                    style: NileTextStyles.bodySm().copyWith(
                      color: NileColors.txtTertiary,
                    ),
                  ),
                )
              : ReorderableListView(
                  buildDefaultDragHandles: false,
                  onReorderItem: _reorder,
                  children: [
                    for (var i = 0; i < rows.length; i++)
                      _row(i, rows[i], _items[rows[i].id]!),
                  ],
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(NileSpacing.s12),
          child: Row(
            children: [
              Tooltip(
                message: 'Every camera gets these layers',
                child: TextButton.icon(
                  onPressed: () =>
                      Navigator.pop(context, (layers: _draft, copyToAll: true)),
                  icon: const Icon(Icons.copy_all_outlined),
                  label: const Text('Copy to all'),
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: NileSpacing.s8),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(context, (layers: _draft, copyToAll: false)),
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

  Widget _row(int index, LayerEntry entry, PlacedItem item) {
    final allowed = _allowed(item);
    final spot = entry.spot != null && allowed.contains(entry.spot)
        ? entry.spot!
        : item.spot;
    final g = item.graphic;
    return ListTile(
      key: ValueKey(entry.id),
      contentPadding: const EdgeInsets.only(
        left: NileSpacing.s12,
        right: NileSpacing.s24,
      ),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ReorderableDragStartListener(
            index: index,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Icon(
                Icons.drag_indicator,
                color: NileColors.txtTertiary,
                semanticLabel: 'Drag to reorder',
              ),
            ),
          ),
          const SizedBox(width: NileSpacing.s8),
          Icon(
            g != null ? graphicKindIcon(g.kind) : Icons.widgets_outlined,
            color: entry.hidden
                ? NileColors.txtTertiary
                : NileColors.txtSecondary,
          ),
        ],
      ),
      title: Text(
        item.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: NileTextStyles.bodyMd().copyWith(
          color: entry.hidden ? NileColors.txtTertiary : null,
        ),
      ),
      subtitle: Text(
        index == 0 ? 'Front' : 'Layer ${index + 1}',
        style: NileTextStyles.caption().copyWith(color: NileColors.txtTertiary),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (allowed.length > 1)
            TextButton(
              onPressed: () => _pickSpot(entry, allowed, spot),
              child: Text(
                spot.label,
                style: NileTextStyles.labelSm().copyWith(
                  color: NileColors.txtPrimary,
                ),
              ),
            )
          else
            Text(
              spot.label,
              style: NileTextStyles.labelSm().copyWith(
                color: NileColors.txtTertiary,
              ),
            ),
          IconButton(
            tooltip: entry.hidden ? 'Show' : 'Hide',
            icon: Icon(
              entry.hidden
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
            color: entry.hidden
                ? NileColors.txtTertiary
                : NileColors.txtSecondary,
            onPressed: () => _set(entry.copyWith(hidden: !entry.hidden)),
          ),
        ],
      ),
    );
  }
}

/// A mini screen of spots to pick from: the 3×3 grid, plus full screen when
/// allowed. Spots not [allowed] are greyed out.
class SpotGrid extends StatelessWidget {
  const SpotGrid({
    super.key,
    required this.allowed,
    required this.selected,
    required this.onPick,
  });

  final List<LayoutSpot> allowed;
  final LayoutSpot selected;
  final ValueChanged<LayoutSpot> onPick;

  @override
  Widget build(BuildContext context) {
    Widget cell(LayoutSpot s) {
      final ok = allowed.contains(s);
      final on = s == selected;
      return Tooltip(
        message: s.label,
        child: InkWell(
          onTap: ok ? () => onPick(s) : null,
          borderRadius: BorderRadius.circular(NileRadius.xs),
          child: Container(
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: on
                  ? NileColors.volt
                  : ok
                  ? NileColors.bgRaised
                  : Colors.transparent,
              border: Border.all(
                color: ok ? NileColors.borderStrong : NileColors.border,
              ),
              borderRadius: BorderRadius.circular(NileRadius.xs),
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 160,
          height: 90,
          child: GridView.count(
            crossAxisCount: 3,
            childAspectRatio: 16 / 9,
            physics: const NeverScrollableScrollPhysics(),
            children: [for (final s in LayoutSpot.grid) cell(s)],
          ),
        ),
        if (allowed.contains(LayoutSpot.full))
          TextButton(
            onPressed: () => onPick(LayoutSpot.full),
            child: Text(
              selected == LayoutSpot.full ? 'Full screen ✓' : 'Full screen',
            ),
          ),
      ],
    );
  }
}

/// Faint thirds over the preview, so the spots read.
class _Grid extends StatelessWidget {
  const _Grid();

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(painter: _GridPainter(NileColors.border)),
  );
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(
        Offset(size.width * i / 3, 0),
        Offset(size.width * i / 3, size.height),
        p,
      );
      canvas.drawLine(
        Offset(0, size.height * i / 3),
        Offset(size.width, size.height * i / 3),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.color != color;
}
