import 'dart:convert';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import 'live_elements.dart';
import 'overlay_layout.dart';
import 'studio_graphics.dart';

/// One tile of a grid replay: a camera ([slot]; null = a screen share or an
/// unassigned camera, which carry show-wide graphics only) or an element angle
/// ([elementId]). [rect] is the tile's 16:9 picture as fractions of the frame.
@immutable
class ReplayTile {
  const ReplayTile({this.slot, this.elementId, required this.rect});

  final String? slot;
  final String? elementId;
  final Rect rect;

  static ReplayTile? fromJson(Object? j) {
    if (j is! Map) return null;
    final r = j['r'];
    if (r is! List || r.length != 4 || r.any((v) => v is! num)) return null;
    final v = [for (final n in r) (n as num).toDouble()];
    return ReplayTile(
      slot: j['s'] is String ? j['s'] as String : null,
      elementId: j['el'] is String ? j['el'] as String : null,
      rect: Rect.fromLTWH(v[0], v[1], v[2], v[3]),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReplayTile &&
      other.slot == slot &&
      other.elementId == elementId &&
      other.rect == rect;

  @override
  int get hashCode => Object.hash(slot, elementId, rect);
}

/// Everything the replay draws at one moment.
@immutable
class ReplayFrame {
  const ReplayFrame({
    this.tiles = const [],
    this.graphics = GraphicsState.empty,
    this.elements = ElementsState.empty,
    this.layout = OverlayLayout.empty,
    this.tallies = const {},
  });

  static const empty = ReplayFrame();

  final List<ReplayTile> tiles;
  final GraphicsState graphics;
  final ElementsState elements;
  final OverlayLayout layout;

  /// Element id → its totals at this moment.
  final Map<String, ElementTally> tallies;
}

typedef _At<T> = ({int o, T v});

/// The overlay timeline of a grid replay, as reported by Nile's recorder page
/// (`replay-grid`): what was on screen at every moment of the video.
class ReplayTimeline {
  ReplayTimeline._(this.startWall, this._tiles, this._metas, this._tallies);

  /// Wall-clock ms (server time) at video time 0.
  final int? startWall;
  final List<_At<List<ReplayTile>>> _tiles;
  final List<_At<({GraphicsState g, ElementsState e, OverlayLayout l})>> _metas;
  final Map<String, List<_At<ElementTally>>> _tallies;

  /// Marks are `{o, k, d}` sorted by `o` (video ms). Unknown kinds and
  /// malformed entries are dropped.
  factory ReplayTimeline.fromMarks(List<Object?> marks) {
    int? start;
    final tiles = <_At<List<ReplayTile>>>[];
    final metas =
        <_At<({GraphicsState g, ElementsState e, OverlayLayout l})>>[];
    final tallies = <String, List<_At<ElementTally>>>{};
    for (final m in marks) {
      if (m is! Map || m['o'] is! num) continue;
      final o = (m['o'] as num).toInt();
      final d = m['d'];
      switch (m['k']) {
        case 'start':
          if (d is Map && d['wall'] is num) {
            start ??= (d['wall'] as num).toInt();
          }
        case 'tiles':
          if (d is List) {
            tiles.add((
              o: o,
              v: d.map(ReplayTile.fromJson).whereType<ReplayTile>().toList(),
            ));
          }
        case 'meta':
          if (d is Map) {
            final raw = jsonEncode(d);
            metas.add((
              o: o,
              v: (
                g: GraphicsState.fromRoomMetadata(raw),
                e: ElementsState.fromRoomMetadata(raw),
                l: OverlayLayout.fromRoomMetadata(raw),
              ),
            ));
          }
        case 'tally':
          final t = d is Map ? tallyFromJson(d['tally'], d['voters']) : null;
          final id = d is Map ? d['elementId'] : null;
          if (t != null && id is String) (tallies[id] ??= []).add((o: o, v: t));
      }
    }
    int byO(_At a, _At b) => a.o.compareTo(b.o);
    tiles.sort(byO);
    metas.sort(byO);
    for (final l in tallies.values) {
      l.sort(byO);
    }
    return ReplayTimeline._(start, tiles, metas, tallies);
  }

  bool get isEmpty => _tiles.isEmpty;

  /// Wall-clock ms at video time [ms] (null when the recording never said
  /// when it started).
  int? wallAt(int ms) => startWall == null ? null : startWall! + ms;

  ReplayFrame frameAt(int ms) {
    final meta = _latest(_metas, ms);
    return ReplayFrame(
      tiles: _latest(_tiles, ms) ?? const [],
      graphics: meta?.g ?? GraphicsState.empty,
      elements: meta?.e ?? ElementsState.empty,
      layout: meta?.l ?? OverlayLayout.empty,
      tallies: {for (final e in _tallies.entries) e.key: ?_latest(e.value, ms)},
    );
  }

  /// The last entry at or before [ms] (binary search).
  static T? _latest<T>(List<_At<T>> list, int ms) {
    var lo = 0, hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (list[mid].o <= ms) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo == 0 ? null : list[lo - 1].v;
  }
}
