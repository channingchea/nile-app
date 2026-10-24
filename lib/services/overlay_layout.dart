import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Alignment;

import 'live_elements.dart';
import 'studio_graphics.dart';

/// Where graphics and elements sit on a camera (studio live elements,
/// phase 2): a 3×3 grid of spots plus full screen, and a layer list per
/// camera (top = front). Room metadata `layout`, written by `set-layout`;
/// mirrors validateLayout in supabase/functions/_shared/elements.ts.
///
/// Positions are measured against the 16:9 video frame, not the screen, so
/// a layout reads the same upright, sideways, on a Studio thumbnail and in a
/// replay grid tile.

enum LayoutSpot {
  tl('Top left'),
  tc('Top centre'),
  tr('Top right'),
  ml('Middle left'),
  mc('Centre'),
  mr('Middle right'),
  bl('Bottom left'),
  bc('Bottom centre'),
  br('Bottom right'),
  full('Full screen');

  const LayoutSpot(this.label);
  final String label;

  String get wire => name;

  static LayoutSpot? fromWire(Object? s) =>
      LayoutSpot.values.where((v) => v.name == s).firstOrNull;

  /// The nine grid spots, row by row.
  static const grid = [tl, tc, tr, ml, mc, mr, bl, bc, br];

  bool get isTop => this == tl || this == tc || this == tr;
  bool get isBottom => this == bl || this == bc || this == br;
  bool get isLeft => this == tl || this == ml || this == bl;
  bool get isRight => this == tr || this == mr || this == br;

  Alignment get alignment => switch (this) {
    tl => Alignment.topLeft,
    tc => Alignment.topCenter,
    tr => Alignment.topRight,
    ml => Alignment.centerLeft,
    mc || full => Alignment.center,
    mr => Alignment.centerRight,
    bl => Alignment.bottomLeft,
    bc => Alignment.bottomCenter,
    br => Alignment.bottomRight,
  };
}

/// One line of a camera's layer list.
@immutable
class LayerEntry {
  const LayerEntry(this.id, {this.spot, this.hidden = false});

  /// A [LiveGraphic.id] or [LiveElement.id].
  final String id;

  /// Null = the item's own default spot.
  final LayoutSpot? spot;
  final bool hidden;

  LayerEntry copyWith({LayoutSpot? spot, bool? hidden}) =>
      LayerEntry(id, spot: spot ?? this.spot, hidden: hidden ?? this.hidden);

  static LayerEntry? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String) return null;
    return LayerEntry(
      j['id'] as String,
      spot: LayoutSpot.fromWire(j['spot']),
      hidden: j['hidden'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'spot': ?spot?.wire,
    if (hidden) 'hidden': true,
  };

  @override
  bool operator ==(Object other) =>
      other is LayerEntry &&
      other.id == id &&
      other.spot == spot &&
      other.hidden == hidden;

  @override
  int get hashCode => Object.hash(id, spot, hidden);
}

/// Every camera's layer list. A camera without its own uses [all] ("Copy to
/// all" writes there); a screen share always uses [all].
@immutable
class OverlayLayout {
  const OverlayLayout({this.all = const [], this.bySlot = const {}, this.at});

  static const empty = OverlayLayout();

  final List<LayerEntry> all;
  final Map<String, List<LayerEntry>> bySlot;

  /// Server ms the last change refers to (viewer hold-back). Not sent.
  final int? at;

  List<LayerEntry> layersFor(String? slotId) =>
      (slotId == null ? null : bySlot[slotId]) ?? all;

  /// [slotId]'s own layer list (null = the shared one).
  OverlayLayout withLayers(String? slotId, List<LayerEntry> layers) {
    if (slotId == null) return OverlayLayout(all: layers, bySlot: bySlot);
    return OverlayLayout(all: all, bySlot: {...bySlot, slotId: layers});
  }

  /// One layer list for every camera.
  OverlayLayout copiedToAll(List<LayerEntry> layers) =>
      OverlayLayout(all: layers);

  factory OverlayLayout.fromRoomMetadata(String? raw) {
    try {
      final m = jsonDecode(raw ?? '{}');
      return m is Map ? OverlayLayout.fromJson(m['layout']) : empty;
    } catch (_) {
      return empty;
    }
  }

  factory OverlayLayout.fromJson(Object? j) {
    if (j is! Map) return empty;
    List<LayerEntry> list(Object? l) => l is List
        ? l.map(LayerEntry.fromJson).whereType<LayerEntry>().toList()
        : const [];
    final bySlot = <String, List<LayerEntry>>{};
    if (j['bySlot'] case final Map raw) {
      raw.forEach((k, v) {
        final l = list(v);
        if (k is String && l.isNotEmpty) bySlot[k] = l;
      });
    }
    return OverlayLayout(
      all: list(j['all']),
      bySlot: bySlot,
      at: (j['at'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
    if (all.isNotEmpty) 'all': [for (final e in all) e.toJson()],
    'bySlot': {
      for (final e in bySlot.entries)
        if (e.value.isNotEmpty) e.key: [for (final l in e.value) l.toJson()],
    },
  };

  @override
  bool operator ==(Object other) =>
      other is OverlayLayout &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

// ── Placement ────────────────────────────────────────────────────────────────

/// A graphic's own spot when no layout moves it — so shows from before
/// layouts look exactly as they did.
LayoutSpot defaultGraphicSpot(LiveGraphic g) => switch (g.kind) {
  GraphicKind.logo || GraphicKind.sponsor || GraphicKind.qr =>
    LayoutSpot.fromWire(g.corner) ?? LayoutSpot.tr,
  GraphicKind.lowerThird || GraphicKind.chat => LayoutSpot.bl,
  GraphicKind.banner => LayoutSpot.bc,
  GraphicKind.slate => LayoutSpot.full,
};

/// The spots a graphic may be moved to: a slate is always full screen, a
/// banner is a full-width row (top, middle or bottom).
List<LayoutSpot> allowedGraphicSpots(GraphicKind k) => switch (k) {
  GraphicKind.slate => const [LayoutSpot.full],
  GraphicKind.banner => const [LayoutSpot.tc, LayoutSpot.mc, LayoutSpot.bc],
  _ => LayoutSpot.grid,
};

/// Elements may go anywhere, full screen included.
const allowedElementSpots = LayoutSpot.values;

/// Front-to-back order for items no layer list mentions: corner bugs at the
/// back, then elements, lower thirds, chat cards, banners, and a slate over
/// everything.
int _defaultRank(LiveGraphic? g) => switch (g?.kind) {
  null => 1,
  GraphicKind.logo || GraphicKind.sponsor || GraphicKind.qr => 0,
  GraphicKind.lowerThird => 2,
  GraphicKind.chat => 3,
  GraphicKind.banner => 4,
  GraphicKind.slate => 5,
};

/// One graphic or element, placed.
@immutable
class PlacedItem {
  const PlacedItem({
    required this.channel,
    required this.spot,
    required this.z,
    this.graphic,
    this.element,
  });

  /// What fades in and out as a unit: a graphic's cap key (so swapping one
  /// lower third for another cross-fades), or `el:<id>`.
  final String channel;
  final LayoutSpot spot;

  /// Higher = in front.
  final int z;
  final LiveGraphic? graphic;
  final LiveElement? element;

  String get id => graphic?.id ?? element!.id;
  String get name => graphic?.title ?? graphic?.text ?? element?.name ?? id;
  bool get isFull => spot == LayoutSpot.full;
  bool get isBanner => graphic?.kind == GraphicKind.banner;

  /// Small square things that sit side by side in a corner.
  bool get isCompact => switch (graphic?.kind) {
    GraphicKind.logo || GraphicKind.sponsor || GraphicKind.qr => true,
    _ => false,
  };
}

/// Where everything on one camera goes, back to front. Listed items take
/// their layer list's spot (when allowed) and order; anything on air but not
/// listed goes in front of them in the default order, so a graphic just put
/// on air is never buried. Hidden items are left out. Graphics sharing a cap
/// key are already one (the last wins, as before layouts).
List<PlacedItem> placeOverlay({
  required List<LiveGraphic> graphics,
  List<LiveElement> elements = const [],
  List<LayerEntry> layers = const [],
}) {
  final byCap = <String, LiveGraphic>{};
  for (final g in graphics) {
    byCap.remove(g.capKey);
    byCap[g.capKey] = g;
  }
  final index = <String, int>{};
  for (var i = 0; i < layers.length; i++) {
    index.putIfAbsent(layers[i].id, () => i);
  }
  final out = <PlacedItem>[];
  void add({
    required String id,
    required String channel,
    required LayoutSpot fallback,
    required List<LayoutSpot> allowed,
    LiveGraphic? g,
    LiveElement? e,
  }) {
    final i = index[id];
    final entry = i == null ? null : layers[i];
    if (entry?.hidden ?? false) return;
    final spot = entry?.spot != null && allowed.contains(entry!.spot)
        ? entry.spot!
        : fallback;
    out.add(
      PlacedItem(
        channel: channel,
        spot: spot,
        z: i == null ? 2000 + _defaultRank(g) : 1000 + layers.length - i,
        graphic: g,
        element: e,
      ),
    );
  }

  for (final g in byCap.values) {
    add(
      id: g.id,
      channel: g.capKey,
      fallback: defaultGraphicSpot(g),
      allowed: allowedGraphicSpots(g.kind),
      g: g,
    );
  }
  for (final e in elements) {
    add(
      id: e.id,
      channel: 'el:${e.id}',
      fallback: ElementKinds.of(e.kind)?.defaultSpot ?? LayoutSpot.tr,
      allowed: allowedElementSpots,
      e: e,
    );
  }
  out.sort((a, b) => a.z.compareTo(b.z));
  return out;
}

/// The Studio's heads-up for one camera: what a full-screen item hides, and
/// spots crowded enough to run into their neighbours. Advice only — nothing
/// is blocked.
List<String> layoutWarnings(List<PlacedItem> placed) {
  final out = <String>[];
  for (final full in placed.where((p) => p.isFull)) {
    final under = placed.where((p) => p.z < full.z).map((p) => p.name);
    if (under.isNotEmpty) {
      out.add('${full.name} covers ${under.join(', ')}.');
    }
  }
  final perSpot = <LayoutSpot, int>{};
  for (final p in placed.where((p) => !p.isFull && !p.isCompact)) {
    perSpot[p.spot] = (perSpot[p.spot] ?? 0) + 1;
  }
  perSpot.forEach((spot, n) {
    if (n >= 3) out.add('$n items share ${spot.label} — they may overlap.');
  });
  return out;
}

/// The 16:9 picture inside a [box] of any shape, centred (what
/// `VideoViewFit.contain` shows).
Rect videoFrame(Size box, {double aspect = 16 / 9}) {
  if (box.width <= 0 || box.height <= 0) return Rect.zero;
  final w = math.min(box.width, box.height * aspect);
  final h = w / aspect;
  return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
}

// ── Hold-back ────────────────────────────────────────────────────────────────

/// How long a viewer waits before showing an overlay change, so a score never
/// lands before the goal does. [contentAtMs] is the server ms the change refers
/// to (stamped by the server, less the Studio's own picture age); the viewer's
/// picture is [viewerAgeMs] old, so it shows that moment at
/// `contentAt + viewerAge` on the server clock. Without a server clock or a
/// picture age there is nothing to go on: no wait (never a guess that could
/// stall graphics by a device's clock error).
Duration overlayHoldback({
  required int? contentAtMs,
  required int? serverNowMs,
  required double? viewerAgeMs,
  int capMs = 10000,
}) {
  if (contentAtMs == null || serverNowMs == null || viewerAgeMs == null) {
    return Duration.zero;
  }
  final wait = contentAtMs + viewerAgeMs.round() - serverNowMs;
  return Duration(milliseconds: wait.clamp(0, capMs));
}
