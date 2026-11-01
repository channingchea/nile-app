import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'brand_kit.dart';
import 'live_elements.dart';
import 'livekit_service.dart' show CameraSlot;
import 'overlay_layout.dart';
import 'show_control.dart';
import 'studio_graphics.dart';

/// Studio Layouts (docs/plans/studio-layouts.md): saved show setups in the
/// host's account-wide library (`studio_layouts`, migration 0144). Applying
/// one restores graphics and elements on each camera, their spots and layer
/// order, cameras on/off air, element angles, the default angle and camera
/// order — viewers still pick their own angle.
///
/// A layout holds library ids only, so editing a graphic changes every layout
/// that uses it. Cameras are matched by position: "Camera 2" is the second
/// camera made for the show ([positionsOf]), whatever order the Studio shows.

enum LayoutItemType { graphic, element }

/// One graphic or element on a layout camera.
@immutable
class LayoutItem {
  const LayoutItem.graphic(
    this.ref, {
    this.spot,
    this.hidden = false,
    this.autoHide,
  }) : type = LayoutItemType.graphic;
  const LayoutItem.element(this.ref, {this.spot, this.hidden = false})
    : type = LayoutItemType.element,
      autoHide = null;

  final LayoutItemType type;

  /// A [StudioGraphic.id] or [StudioElement.id].
  final String ref;

  /// Null = the item's own default spot.
  final LayoutSpot? spot;
  final bool hidden;

  /// Graphics: seconds until it comes down by itself (0 = stays up). Null =
  /// the library graphic's own setting.
  final int? autoHide;

  bool get isGraphic => type == LayoutItemType.graphic;

  LayerEntry get layer => LayerEntry(ref, spot: spot, hidden: hidden);

  static LayoutItem? fromJson(Object? j) {
    if (j is! Map) return null;
    final spot = LayoutSpot.fromWire(j['spot']);
    final hidden = j['hidden'] == true;
    if (j['g'] case final String id when id.isNotEmpty) {
      final hide = j['autoHide'];
      return LayoutItem.graphic(
        id,
        spot: spot,
        hidden: hidden,
        autoHide: hide is int && hide >= 0 ? hide : null,
      );
    }
    if (j['e'] case final String id when id.isNotEmpty) {
      return LayoutItem.element(id, spot: spot, hidden: hidden);
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    isGraphic ? 'g' : 'e': ref,
    'spot': ?spot?.wire,
    if (hidden) 'hidden': true,
    'autoHide': ?autoHide,
  };

  @override
  bool operator ==(Object other) =>
      other is LayoutItem &&
      other.type == type &&
      other.ref == ref &&
      other.spot == spot &&
      other.hidden == hidden &&
      other.autoHide == autoHide;

  @override
  int get hashCode => Object.hash(type, ref, spot, hidden, autoHide);
}

/// One camera position in a layout. [items] run front to back, like a layer
/// list (top = front).
@immutable
class LayoutCamera {
  const LayoutCamera({this.items = const [], this.onAir = true});

  final List<LayoutItem> items;
  final bool onAir;

  static LayoutCamera fromJson(Object? j) {
    if (j is! Map) return const LayoutCamera();
    final items = j['items'];
    return LayoutCamera(
      items: items is List
          ? items.map(LayoutItem.fromJson).whereType<LayoutItem>().toList()
          : const [],
      onAir: j['onAir'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
    'items': [for (final i in items) i.toJson()],
    if (!onAir) 'onAir': false,
  };

  @override
  bool operator ==(Object other) =>
      other is LayoutCamera &&
      other.onAir == onAir &&
      listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(onAir, Object.hashAll(items));
}

/// An angle in a layout: a camera position (1 = the first camera made) or an
/// element shown as its own angle.
@immutable
class AngleRef {
  const AngleRef.camera(int this.camera) : element = null;
  const AngleRef.element(String this.element) : camera = null;

  final int? camera;
  final String? element;

  static AngleRef? fromJson(Object? j) {
    if (j is! Map) return null;
    if (j['cam'] case final int n when n >= 1) return AngleRef.camera(n);
    if (j['el'] case final String id when id.isNotEmpty) {
      return AngleRef.element(id);
    }
    return null;
  }

  Map<String, dynamic> toJson() =>
      camera != null ? {'cam': camera} : {'el': element};

  @override
  bool operator ==(Object other) =>
      other is AngleRef && other.camera == camera && other.element == element;

  @override
  int get hashCode => Object.hash(camera, element);
}

/// A saved layout.
@immutable
class StudioLayout {
  const StudioLayout({
    this.id = '',
    required this.name,
    this.cameras = const [],
    this.angles = const [],
    this.defaultAngle,
    this.order = const [],
    this.template,
    this.sort = 0,
    this.updatedAt,
  });

  static const maxPayloadBytes = 16000;
  static const maxCameras = 16;

  factory StudioLayout.fromRow(Map<String, dynamic> r) =>
      StudioLayout.fromPayload(
        r['payload'],
        id: r['id'] as String,
        name: r['name'] as String,
        template: r['template'] as String?,
        sort: (r['sort'] as num?)?.toInt() ?? 0,
        updatedAt: DateTime.tryParse(r['updated_at'] as String? ?? ''),
      );

  factory StudioLayout.fromPayload(
    Object? p, {
    String id = '',
    required String name,
    String? template,
    int sort = 0,
    DateTime? updatedAt,
  }) {
    final m = p is Map ? p : const {};
    final cams = m['cameras'];
    final angles = m['angles'];
    final order = m['order'];
    return StudioLayout(
      id: id,
      name: name,
      cameras: cams is List
          ? cams.map(LayoutCamera.fromJson).toList()
          : const [],
      angles: angles is List ? angles.whereType<String>().toList() : const [],
      defaultAngle: AngleRef.fromJson(m['defaultAngle']),
      order: order is List
          ? order.map(AngleRef.fromJson).whereType<AngleRef>().toList()
          : const [],
      template: template,
      sort: sort,
      updatedAt: updatedAt,
    );
  }

  final String id;
  final String name;

  /// Camera positions: index 0 = Camera 1.
  final List<LayoutCamera> cameras;

  /// Elements shown as their own angle.
  final List<String> angles;

  /// Where new viewers start. Null = the first on-air camera.
  final AngleRef? defaultAngle;

  /// Camera order. Empty = leave the show's order as it is.
  final List<AngleRef> order;

  /// The template it was made from, if any.
  final String? template;
  final int sort;

  /// Server time of the last save — "Changed since applied" compares it.
  final DateTime? updatedAt;

  Map<String, dynamic> get payload => {
    'v': 1,
    'cameras': [for (final c in cameras) c.toJson()],
    if (angles.isNotEmpty) 'angles': angles,
    'defaultAngle': ?defaultAngle?.toJson(),
    if (order.isNotEmpty) 'order': [for (final o in order) o.toJson()],
  };

  /// Every library id it uses.
  Set<String> get refs => {
    for (final c in cameras)
      for (final i in c.items) i.ref,
    ...angles,
  };

  StudioLayout copyWith({
    String? name,
    List<LayoutCamera>? cameras,
    List<String>? angles,
    AngleRef? defaultAngle,
    bool clearDefault = false,
    List<AngleRef>? order,
    int? sort,
  }) => StudioLayout(
    id: id,
    name: name ?? this.name,
    cameras: cameras ?? this.cameras,
    angles: angles ?? this.angles,
    defaultAngle: clearDefault ? null : defaultAngle ?? this.defaultAngle,
    order: order ?? this.order,
    template: template,
    sort: sort ?? this.sort,
    updatedAt: updatedAt,
  );

  /// Why it can't be saved, or null.
  String? get error {
    final n = name.trim();
    if (n.isEmpty || n.length > 60) return 'Name is 1–60 characters.';
    if (cameras.isEmpty) return 'A layout needs at least one camera.';
    if (cameras.length > maxCameras) {
      return 'A layout has $maxCameras cameras at most.';
    }
    if (utf8.encode(jsonEncode(payload)).length > maxPayloadBytes) {
      return 'This layout is too big to save.';
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is StudioLayout &&
      other.id == id &&
      other.name == name &&
      other.template == template &&
      other.sort == sort &&
      other.updatedAt == updatedAt &&
      jsonEncode(other.payload) == jsonEncode(payload);

  @override
  int get hashCode =>
      Object.hash(id, name, template, sort, updatedAt, jsonEncode(payload));
}

/// The show's camera slot ids by position — creation order (`slot_index`),
/// not display order, so applying a layout that reorders cameras never
/// changes what "Camera 2" means.
List<String> positionsOf(Iterable<CameraSlot> slots) =>
    ([...slots]..sort((a, b) => a.slotIndex.compareTo(b.slotIndex)))
        .map((s) => s.id)
        .toList();

// ── Save current look ────────────────────────────────────────────────────────

/// The show as it is now, as a layout ("Save current look"). [positions]
/// from [positionsOf]. Graphics on every camera become an entry on each
/// camera. Anything on air that isn't in the library (a chat message on
/// screen, a sponsor logo, a deleted item) is left out and named in
/// `leftOut`.
({StudioLayout layout, List<String> leftOut}) snapshotLayout({
  required String name,
  required List<String> positions,
  required Set<String> libraryGraphics,
  required Set<String> libraryElements,
  GraphicsState graphics = GraphicsState.empty,
  Iterable<LiveElement> elements = const [],
  OverlayLayout overlay = OverlayLayout.empty,
  ShowControl show = ShowControl.empty,
  int? nowMs,
}) {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final leftOut = <String>{};
  final cameras = <LayoutCamera>[];
  for (final slot in positions) {
    final gs = graphics.forSlot(slot, nowMs: now);
    final els = [
      for (final e in elements)
        if (e.targets.includes(slot)) e,
    ];
    final layers = overlay.layersFor(slot);
    final byId = {for (final l in layers) l.id: l};
    final placed = placeOverlay(
      graphics: gs,
      elements: els,
      layers: [for (final l in layers) l.copyWith(hidden: false)],
    ).reversed;
    final items = <LayoutItem>[];
    for (final p in placed) {
      final entry = byId[p.id];
      final spot = entry?.spot;
      final hidden = entry?.hidden ?? false;
      if (p.graphic != null && libraryGraphics.contains(p.id)) {
        items.add(LayoutItem.graphic(p.id, spot: spot, hidden: hidden));
      } else if (p.element != null && libraryElements.contains(p.id)) {
        items.add(LayoutItem.element(p.id, spot: spot, hidden: hidden));
      } else {
        leftOut.add(p.name);
      }
    }
    cameras.add(LayoutCamera(items: items, onAir: show.isOnAir(slot)));
  }

  final angles = <String>[];
  for (final e in elements.where((e) => e.angle)) {
    libraryElements.contains(e.id) ? angles.add(e.id) : leftOut.add(e.name);
  }

  AngleRef? ref(String? id) {
    if (id == null) return null;
    final el = elementIdOfAngle(id);
    if (el != null) return angles.contains(el) ? AngleRef.element(el) : null;
    final i = positions.indexOf(id);
    return i < 0 ? null : AngleRef.camera(i + 1);
  }

  return (
    layout: StudioLayout(
      name: name,
      cameras: cameras,
      angles: angles,
      defaultAngle: ref(show.defaultSlot),
      order: show.slotOrder.map(ref).whereType<AngleRef>().toList(),
    ),
    leftOut: leftOut.toList(),
  );
}

// ── Apply ────────────────────────────────────────────────────────────────────

/// A layout item Apply had to skip: deleted from the library and not on air.
/// [camera] is the position (null = an element angle).
typedef MissingItem = ({int? camera, LayoutItemType type, String ref});

/// The show a layout asks for.
@immutable
class ResolvedLayout {
  const ResolvedLayout({
    required this.graphics,
    required this.overlay,
    required this.show,
    required this.elements,
    required this.covered,
    this.missing = const [],
    this.skippedCameras = 0,
  });

  final GraphicsState graphics;
  final OverlayLayout overlay;
  final ShowControl show;

  /// Elements whose cameras or angle change, as they should end up. One
  /// already in the show keeps its state (votes, clocks); a new one starts
  /// from its library item.
  final List<LiveElement> elements;

  /// Slot ids the layout replaced.
  final List<String> covered;
  final List<MissingItem> missing;

  /// Layout cameras beyond the show's camera count, left unused.
  final int skippedCameras;

  /// Missing items, each library id once.
  int get missingCount => {for (final m in missing) m.ref}.length;
}

/// What applying [layout] to the show would put on air. [positions] from
/// [positionsOf]; [build] snapshots a library graphic for pushing (the
/// Studio's `LiveGraphic.snapshot` with its URL/clock/link helpers);
/// [elements] = every element in the show, on air or not.
///
/// Cameras the layout covers are replaced completely; cameras past its count
/// keep everything. Graphics and elements already up keep their live values,
/// so a running countdown or a poll's votes carry on.
ResolvedLayout resolveLayout(
  StudioLayout layout, {
  required List<String> positions,
  required Map<String, StudioGraphic> graphicsLibrary,
  required Map<String, StudioElement> elementsLibrary,
  required LiveGraphic Function(StudioGraphic g, int? autoHide) build,
  GraphicsState graphics = GraphicsState.empty,
  Iterable<LiveElement> elements = const [],
  OverlayLayout overlay = OverlayLayout.empty,
  ShowControl show = ShowControl.empty,
  BrandStyle? kit,
  int? nowMs,
}) {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final n = layout.cameras.length < positions.length
      ? layout.cameras.length
      : positions.length;
  final covered = positions.take(n).toList();
  final coveredSet = covered.toSet();
  final allSlots = positions.toSet();
  final kept = allSlots.difference(coveredSet);
  final missing = <MissingItem>[];

  GraphicTargets targetsFor(Set<String> slots) =>
      allSlots.isNotEmpty && slots.containsAll(allSlots)
      ? const GraphicTargets.all()
      : GraphicTargets.only(slots);

  // Graphics.
  var g = graphics.withoutExpired(now);
  final liveGraphics = <String, LiveGraphic>{
    for (final x in [...g.all, for (final l in g.bySlot.values) ...l]) x.id: x,
  };
  final wantG = <String, Set<String>>{};
  final autoHide = <String, int?>{};
  final shownEls = <String, Set<String>>{};
  final byElId = {for (final e in elements) e.id: e};
  var o = overlay;
  for (var i = 0; i < n; i++) {
    final slot = covered[i];
    final layers = <LayerEntry>[];
    for (final item in layout.cameras[i].items) {
      final ok = item.isGraphic
          ? graphicsLibrary.containsKey(item.ref) ||
                liveGraphics.containsKey(item.ref)
          : elementsLibrary.containsKey(item.ref) ||
                byElId.containsKey(item.ref);
      if (!ok) {
        missing.add((camera: i + 1, type: item.type, ref: item.ref));
        continue;
      }
      if (item.isGraphic) {
        (wantG[item.ref] ??= {}).add(slot);
        autoHide.putIfAbsent(item.ref, () => item.autoHide);
      } else {
        (shownEls[item.ref] ??= {}).add(slot);
      }
      layers.add(item.layer);
    }
    o = o.withLayers(slot, layers);
  }

  for (final id in liveGraphics.keys.where((id) => !wantG.containsKey(id))) {
    for (final slot in covered) {
      g = g.withoutOnSlot(id, slot);
    }
    final inAll = g.all.where((x) => x.id == id).firstOrNull;
    if (inAll != null && inAll.except.toSet().containsAll(allSlots)) {
      g = g.withoutEverywhere(id);
    }
  }
  for (final MapEntry(key: id, value: slots) in wantG.entries) {
    final live = liveGraphics[id];
    final value = live ?? build(graphicsLibrary[id]!, autoHide[id]);
    final current = g.targetsOf(id);
    g = g.withTargets(
      value,
      targetsFor({
        for (final s in kept)
          if (live != null && current.includes(s)) s,
        ...slots,
      }),
    );
  }

  // Elements.
  final angles = <String>{};
  for (final id in layout.angles) {
    if (elementsLibrary.containsKey(id) || byElId.containsKey(id)) {
      angles.add(id);
    } else {
      missing.add((camera: null, type: LayoutItemType.element, ref: id));
    }
  }
  final changed = <LiveElement>[];
  // Angles that come or go lose any off-air mark they had.
  final reset = <String>{};
  for (final id in {...byElId.keys, ...shownEls.keys, ...angles}) {
    final cur =
        byElId[id] ?? LiveElement.fromLibrary(elementsLibrary[id]!, kit: kit);
    final slots = {
      for (final s in kept)
        if (cur.targets.includes(s)) s,
      ...?shownEls[id],
    };
    final t = slots.isEmpty ? GraphicTargets.none : targetsFor(slots);
    final angle = angles.contains(id);
    if (cur.angle != angle) reset.add(elementAngleId(id));
    if (t != cur.targets || angle != cur.angle || !byElId.containsKey(id)) {
      changed.add(cur.copyWith(targets: t, angle: angle));
    }
  }

  // Show control.
  String? slotOf(AngleRef? r) {
    if (r == null) return null;
    if (r.element != null) {
      return angles.contains(r.element) ? elementAngleId(r.element!) : null;
    }
    final p = r.camera! - 1;
    return p < positions.length ? positions[p] : null;
  }

  final offAir = {
    for (final s in show.offAir)
      if (!coveredSet.contains(s) && !reset.contains(s)) s,
    for (var i = 0; i < n; i++)
      if (!layout.cameras[i].onAir) covered[i],
  };
  final def = slotOf(layout.defaultAngle);
  final order = <String>[];
  for (final r in layout.order) {
    final s = slotOf(r);
    if (s != null && !order.contains(s)) order.add(s);
  }
  if (order.isNotEmpty) {
    order.addAll(show.slotOrder.where((s) => !order.contains(s)));
  }

  return ResolvedLayout(
    graphics: g,
    overlay: o,
    show: ShowControl(
      offAir: offAir,
      defaultSlot:
          def ?? (layout.defaultAngle == null ? null : show.defaultSlot),
      sendAll: show.sendAll,
      slotOrder: order.isEmpty ? show.slotOrder : order,
    ),
    elements: changed,
    covered: covered,
    missing: missing,
    skippedCameras: layout.cameras.length - n,
  );
}
