import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Studio graphics (Studio master host, phases 4-5).
///
/// Two shapes of the same thing:
///  - [StudioGraphic] — an item in the host's saved library (`studio_graphics`
///    table, owner-only) or one of the built-in [StudioGraphicPresets].
///  - [LiveGraphic] — a self-contained snapshot pushed into the LiveKit room
///    metadata by the Studio. Viewers draw these; they never read the library.
///
/// Payload rules mirror `studio_graphic_payload_ok` (migrations 0130/0130a) and
/// `validateGraphics` in supabase/functions/_shared/graphics.ts.

enum GraphicKind {
  lowerThird('lower_third', 'Lower third'),
  logo('logo', 'Logo / image'),
  banner('banner', 'Banner'),
  slate('slate', 'Full-screen slate');

  const GraphicKind(this.wire, this.label);
  final String wire;
  final String label;

  static GraphicKind? fromWire(Object? s) =>
      GraphicKind.values.where((k) => k.wire == s).firstOrNull;
}

/// Logo corners, in their wire form.
const logoCorners = ['tl', 'tr', 'bl', 'br'];
const logoCornerLabels = {
  'tl': 'Top left',
  'tr': 'Top right',
  'bl': 'Bottom left',
  'br': 'Bottom right',
};

@immutable
class StudioGraphic {
  const StudioGraphic({
    required this.id,
    required this.kind,
    required this.name,
    required this.payload,
    this.sort = 0,
  });

  factory StudioGraphic.fromRow(Map<String, dynamic> r) => StudioGraphic(
    id: r['id'] as String,
    kind: GraphicKind.fromWire(r['kind']) ?? GraphicKind.lowerThird,
    name: r['name'] as String,
    payload: Map<String, dynamic>.from(r['payload'] as Map),
    sort: (r['sort'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final GraphicKind kind;
  final String name;
  final Map<String, dynamic> payload;
  final int sort;

  bool get isPreset => id.startsWith('preset:');

  StudioGraphic copyWith({String? name, Map<String, dynamic>? payload, int? sort}) =>
      StudioGraphic(
        id: id,
        kind: kind,
        name: name ?? this.name,
        payload: payload ?? this.payload,
        sort: sort ?? this.sort,
      );

  /// Why [payload] can't be saved as a [kind], or null when it can.
  static String? validate(GraphicKind kind, Map<String, dynamic> p) {
    String? text(String key, int min, int max, String label) {
      final v = p[key];
      if (v == null && min == 0) return null;
      if (v is! String || v.trim().length < min) return '$label is required.';
      if (v.length > max) return '$label is $max characters at most.';
      return null;
    }

    switch (kind) {
      case GraphicKind.lowerThird:
        return text('title', 1, 60, 'Title') ??
            text('subtitle', 0, 80, 'Subtitle');
      case GraphicKind.logo:
        if (p['imagePath'] is! String || (p['imagePath'] as String).isEmpty) {
          return 'Upload an image.';
        }
        if (!logoCorners.contains(p['corner'])) return 'Pick a corner.';
        if (p['size'] != null && !['s', 'm', 'l'].contains(p['size'])) {
          return 'Pick a size.';
        }
        return null;
      case GraphicKind.banner:
        if (p['scrolling'] is! bool) return 'Choose static or scrolling.';
        return text('text', 1, 140, 'Banner text');
      case GraphicKind.slate:
        final c = p['countdownSeconds'];
        if (c != null && (c is! num || c < 1 || c > 86400)) {
          return 'Countdown is 1 second to 24 hours.';
        }
        return text('title', 1, 60, 'Title') ??
            text('subtitle', 0, 120, 'Subtitle');
    }
  }
}

/// Built-in graphics every host has without saving anything: the four slates
/// from the plan. Pushed exactly like library items.
abstract final class StudioGraphicPresets {
  static const all = [
    StudioGraphic(
      id: 'preset:starting',
      kind: GraphicKind.slate,
      name: 'Starting soon',
      payload: {'title': 'Starting soon', 'subtitle': 'Grab a seat — we’re about to begin.'},
    ),
    StudioGraphic(
      id: 'preset:brb',
      kind: GraphicKind.slate,
      name: 'Be right back',
      payload: {'title': 'Be right back'},
    ),
    StudioGraphic(
      id: 'preset:thanks',
      kind: GraphicKind.slate,
      name: 'Thank you',
      payload: {'title': 'Thank you for watching'},
    ),
    StudioGraphic(
      id: 'preset:countdown',
      kind: GraphicKind.slate,
      name: 'Countdown (5 min)',
      payload: {'title': 'Starting in', 'countdownSeconds': 300},
    ),
  ];
}

/// A graphic as pushed live: everything needed to draw it, nothing that needs
/// a lookup. Image paths are already public URLs; a countdown already has its
/// end time.
@immutable
class LiveGraphic {
  const LiveGraphic({
    required this.id,
    required this.kind,
    this.title,
    this.subtitle,
    this.text,
    this.imageUrl,
    this.corner,
    this.size,
    this.scrolling = false,
    this.endsAt,
  });

  /// [StudioGraphic.id] it came from — what the push panel's switches key on.
  final String id;
  final GraphicKind kind;
  final String? title;
  final String? subtitle;
  final String? text;
  final String? imageUrl;
  final String? corner;
  final String? size;
  final bool scrolling;

  /// Countdown slates: epoch ms when the countdown reaches zero.
  final int? endsAt;

  /// Graphics of the same cap key can't be on screen together: one lower
  /// third, one logo per corner, one banner, one slate.
  String get capKey => kind == GraphicKind.logo ? 'logo:$corner' : kind.wire;

  /// Snapshot a library item for pushing. [publicUrl] turns a storage path
  /// into a URL; [now] stamps a countdown's end.
  factory LiveGraphic.snapshot(
    StudioGraphic g, {
    required String Function(String path) publicUrl,
    required DateTime now,
  }) {
    final p = g.payload;
    final path = p['imagePath'] as String?;
    final countdown = (p['countdownSeconds'] as num?)?.toInt();
    return LiveGraphic(
      id: g.id,
      kind: g.kind,
      title: p['title'] as String?,
      subtitle: p['subtitle'] as String?,
      text: p['text'] as String?,
      imageUrl: path == null || path.isEmpty ? null : publicUrl(path),
      corner: p['corner'] as String?,
      size: p['size'] as String?,
      scrolling: p['scrolling'] == true,
      endsAt: countdown == null
          ? null
          : now.add(Duration(seconds: countdown)).millisecondsSinceEpoch,
    );
  }

  static LiveGraphic? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = GraphicKind.fromWire(j['kind']);
    final id = j['id'];
    if (kind == null || id is! String) return null;
    return LiveGraphic(
      id: id,
      kind: kind,
      title: j['title'] as String?,
      subtitle: j['subtitle'] as String?,
      text: j['text'] as String?,
      imageUrl: j['imageUrl'] as String?,
      corner: j['corner'] as String?,
      size: j['size'] as String?,
      scrolling: j['scrolling'] == true,
      endsAt: (j['endsAt'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.wire,
    'title': ?title,
    'subtitle': ?subtitle,
    'text': ?text,
    'imageUrl': ?imageUrl,
    'corner': ?corner,
    'size': ?size,
    if (scrolling) 'scrolling': true,
    'endsAt': ?endsAt,
  };

  @override
  bool operator ==(Object other) =>
      other is LiveGraphic &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// What is on air: graphics for every camera, plus per-slot extras.
///
/// Lives in the LiveKit room metadata under `graphics`, written only by the
/// `set-graphics` action. Each viewer combines it for the angle they watch
/// ([forSlot]), so graphics follow the camera a viewer picks.
@immutable
class GraphicsState {
  const GraphicsState({this.all = const [], this.bySlot = const {}});

  static const empty = GraphicsState();

  final List<LiveGraphic> all;
  final Map<String, List<LiveGraphic>> bySlot;

  bool get isEmpty => all.isEmpty && bySlot.values.every((l) => l.isEmpty);

  /// Read from raw room metadata. Anything malformed is dropped, never thrown.
  factory GraphicsState.fromRoomMetadata(String? raw) {
    try {
      final m = jsonDecode(raw ?? '{}');
      return m is Map ? GraphicsState.fromJson(m['graphics']) : empty;
    } catch (_) {
      return empty;
    }
  }

  factory GraphicsState.fromJson(Object? j) {
    if (j is! Map) return empty;
    List<LiveGraphic> list(Object? l) => l is List
        ? l.map(LiveGraphic.fromJson).whereType<LiveGraphic>().toList()
        : const [];
    final bySlot = <String, List<LiveGraphic>>{};
    final raw = j['bySlot'];
    if (raw is Map) {
      raw.forEach((k, v) {
        final l = list(v);
        if (k is String && l.isNotEmpty) bySlot[k] = l;
      });
    }
    return GraphicsState(all: list(j['all']), bySlot: bySlot);
  }

  Map<String, dynamic> toJson() => {
    'all': [for (final g in all) g.toJson()],
    'bySlot': {
      for (final e in bySlot.entries)
        if (e.value.isNotEmpty) e.key: [for (final g in e.value) g.toJson()],
    },
  };

  /// What a viewer watching [slotId] sees: everything pushed to all cameras,
  /// with a per-slot graphic replacing an "all" one of the same cap key (the
  /// camera-specific lower third wins over the show-wide one).
  List<LiveGraphic> forSlot(String? slotId) {
    final own = slotId == null ? const <LiveGraphic>[] : bySlot[slotId] ?? const [];
    final taken = {for (final g in own) g.capKey};
    return [
      ...all.where((g) => !taken.contains(g.capKey)),
      ...own,
    ];
  }

  /// The list a target holds: [slotId] null = all cameras.
  List<LiveGraphic> targetList(String? slotId) =>
      slotId == null ? all : bySlot[slotId] ?? const [];

  bool isOn(String? slotId, String graphicId) =>
      targetList(slotId).any((g) => g.id == graphicId);

  /// Turn [g] on for a target, replacing whatever held its cap key there.
  GraphicsState withOn(String? slotId, LiveGraphic g) =>
      _withTarget(slotId, [
        ...targetList(slotId).where((x) => x.capKey != g.capKey && x.id != g.id),
        g,
      ]);

  GraphicsState withOff(String? slotId, String graphicId) => _withTarget(
    slotId,
    targetList(slotId).where((x) => x.id != graphicId).toList(),
  );

  GraphicsState cleared(String? slotId) => _withTarget(slotId, const []);

  GraphicsState _withTarget(String? slotId, List<LiveGraphic> list) {
    if (slotId == null) return GraphicsState(all: list, bySlot: bySlot);
    final next = {...bySlot};
    if (list.isEmpty) {
      next.remove(slotId);
    } else {
      next[slotId] = list;
    }
    return GraphicsState(all: all, bySlot: next);
  }

  @override
  bool operator ==(Object other) =>
      other is GraphicsState &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}
