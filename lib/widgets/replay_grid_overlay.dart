import 'package:flutter/material.dart';

import '../services/live_elements.dart';
import '../services/replay_timeline.dart';
import 'elements/element_kinds.dart';
import 'nile_graphics_layer.dart';

/// Graphics and elements over a grid replay (studio live elements, phase 6):
/// each tile gets what viewers of that angle saw, in layer order. Results show;
/// nothing is tappable (QR codes included).
class ReplayGridOverlay extends StatelessWidget {
  const ReplayGridOverlay({super.key, required this.frame});

  final ReplayFrame frame;

  ElementInteraction? _results(LiveElement e) {
    final t = frame.tallies[e.id];
    return ElementInteraction(tally: t, audience: ElementAudience.replay);
  }

  Widget _tile(ReplayTile t) {
    final id = t.elementId;
    if (id != null) {
      final e = frame.elements.byId(id);
      return e == null
          ? const SizedBox.shrink()
          : NileElementAngle(element: e, interaction: _results(e));
    }
    return NileGraphicsLayer(
      graphics: frame.graphics.forSlot(t.slot),
      elements: frame.elements.forSlot(t.slot),
      layers: frame.layout.layersFor(t.slot),
      interactionFor: _results,
    );
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth, h = box.maxHeight;
          return Stack(
            children: [
              for (final t in frame.tiles)
                Positioned(
                  key: ValueKey('${t.slot}|${t.elementId}'),
                  left: t.rect.left * w,
                  top: t.rect.top * h,
                  width: t.rect.width * w,
                  height: t.rect.height * h,
                  child: _tile(t),
                ),
            ],
          );
        },
      ),
    );
  }
}
