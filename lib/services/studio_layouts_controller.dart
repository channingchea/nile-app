import 'package:flutter/foundation.dart';

import 'brand_kit.dart';
import 'elements_service.dart';
import 'graphics_service.dart';
import 'layouts_service.dart';
import 'live_elements.dart';
import 'overlay_layout.dart';
import 'show_control.dart';
import 'studio_graphics.dart';
import 'studio_layouts.dart';

/// The show as the Studio holds it right now — what layouts snapshot and
/// resolve against. [positions] from [positionsOf]; [elements] = every
/// element in the show, on air or not.
typedef StudioShowNow = ({
  List<String> positions,
  GraphicsState graphics,
  List<LiveElement> elements,
  OverlayLayout overlay,
  ShowControl show,
});

/// Where layouts and the libraries they point at come from. The real Studio
/// uses the services; Studio Preview and tests pass their own.
class LayoutsBackend {
  const LayoutsBackend({
    this.list = LayoutsService.list,
    this.create = LayoutsService.create,
    this.update = LayoutsService.update,
    this.delete = LayoutsService.delete,
    this.reorder = LayoutsService.reorder,
    this.graphics = GraphicsService.list,
    this.elements = ElementsService.list,
  });

  final Future<List<StudioLayout>> Function() list;
  final Future<StudioLayout> Function(StudioLayout) create;
  final Future<StudioLayout> Function(StudioLayout) update;
  final Future<void> Function(StudioLayout) delete;
  final Future<void> Function(List<StudioLayout>) reorder;
  final Future<List<StudioGraphic>> Function() graphics;
  final Future<List<StudioElement>> Function() elements;
}

/// The Studio's side of Layouts (docs/plans/studio-layouts.md, phase 4): the
/// library, the one cued layout, and Apply. [send] puts a resolved layout on
/// air (the `apply-layout` action) and updates the Studio's own state.
class StudioLayoutsController extends ChangeNotifier {
  StudioLayoutsController({
    required this.current,
    required this.build,
    required this.send,
    this.backend = const LayoutsBackend(),
    this.kit,
    this.onCue,
  });

  final StudioShowNow Function() current;
  final LiveGraphic Function(StudioGraphic g, int? autoHide) build;
  final Future<void> Function(StudioLayout layout, ResolvedLayout resolved)
  send;
  final LayoutsBackend backend;
  final BrandStyle? Function()? kit;

  /// A layout was cued — the Studio clears its graphics cue (one cue at a
  /// time, so Enter never applies two things).
  final VoidCallback? onCue;

  List<StudioLayout> _layouts = const [];
  Map<String, StudioGraphic> _graphics = const {};
  Map<String, StudioElement> _elements = const {};
  bool _loaded = false;
  Future<void>? _loading;
  StudioLayout? _cued;
  LayoutApplied? _applied;
  bool _busy = false;

  List<StudioLayout> get layouts => _layouts;
  Map<String, StudioGraphic> get graphicsLibrary => _graphics;
  Map<String, StudioElement> get elementsLibrary => _elements;
  bool get loaded => _loaded;
  bool get busy => _busy;
  StudioLayout? get cued => _cued;
  LayoutApplied? get applied => _applied;

  /// Layouts and both libraries. Throws when they can't be read.
  Future<void> load({bool force = false}) {
    if (_loaded && !force) return Future.value();
    return _loading ??= () async {
      try {
        final r = await Future.wait([
          backend.list(),
          backend.graphics(),
          backend.elements(),
        ]);
        _layouts = r[0] as List<StudioLayout>;
        _graphics = {for (final g in r[1] as List<StudioGraphic>) g.id: g};
        _elements = {for (final e in r[2] as List<StudioElement>) e.id: e};
        _loaded = true;
        _refreshCue();
        notifyListeners();
      } finally {
        _loading = null;
      }
    }();
  }

  /// Room metadata `layoutApplied` changed.
  void setApplied(LayoutApplied? a) {
    if (a?.id == _applied?.id && _sameTime(a?.updatedAt, _applied?.updatedAt)) {
      return;
    }
    _applied = a;
    notifyListeners();
  }

  bool isOnAir(StudioLayout l) => _applied?.id == l.id;

  /// On air, but saved again since it was applied (re-Apply to send it).
  bool isChanged(StudioLayout l) =>
      isOnAir(l) && !_sameTime(_applied!.updatedAt, l.updatedAt);

  static bool _sameTime(DateTime? a, DateTime? b) =>
      a == null || b == null ? a == b : a.isAtSameMomentAs(b);

  // ── Cue ────────────────────────────────────────────────────────────────────

  /// Cue [l] (null = clear). Cueing the cued one again clears it.
  void cue(StudioLayout? l) {
    final next = l == null || l.id == _cued?.id ? null : l;
    if (next?.id == _cued?.id) return;
    _cued = next;
    if (next != null) onCue?.call();
    notifyListeners();
  }

  /// ⌥1–9: cue the [n]th layout (loading the library the first time).
  Future<void> cueNumber(int n) async {
    if (!_loaded) {
      try {
        await load();
      } catch (_) {
        return;
      }
    }
    if (n >= 1 && n <= _layouts.length) cue(_layouts[n - 1]);
  }

  /// Keep the cue pointing at the latest save of the cued layout.
  void _refreshCue() {
    final c = _cued;
    if (c == null) return;
    _cued = _layouts.where((l) => l.id == c.id).firstOrNull;
  }

  // ── Apply ──────────────────────────────────────────────────────────────────

  ResolvedLayout resolve(StudioLayout l) {
    final s = current();
    return resolveLayout(
      l,
      positions: s.positions,
      graphicsLibrary: _graphics,
      elementsLibrary: _elements,
      build: build,
      graphics: s.graphics,
      elements: s.elements,
      overlay: s.overlay,
      show: s.show,
      kit: kit?.call(),
    );
  }

  /// What applying [l] would change, camera by camera.
  List<CameraChange> changesFor(
    StudioLayout l, {
    required String Function(String slotId) labelOf,
  }) {
    final s = current();
    return layoutChanges(
      to: resolve(l),
      labelOf: labelOf,
      nameOf: nameOf,
      graphics: s.graphics,
      elements: s.elements,
      show: s.show,
    );
  }

  /// A graphic's or element's name, from the library or the show.
  String nameOf(String id) {
    final lib = _graphics[id]?.name ?? _elements[id]?.name;
    if (lib != null) return lib;
    final s = current();
    for (final g in [
      ...s.graphics.all,
      for (final l in s.graphics.bySlot.values) ...l,
    ]) {
      if (g.id == id) return g.title ?? g.text ?? g.kind.label;
    }
    return s.elements.where((e) => e.id == id).firstOrNull?.name ?? 'Item';
  }

  /// Put [l] (default: the cued one) on air. Returns what was resolved, or
  /// throws with a message for the host.
  Future<ResolvedLayout?> apply([StudioLayout? l]) async {
    final layout = l ?? _cued;
    if (layout == null || _busy) return null;
    _busy = true;
    notifyListeners();
    try {
      final r = resolve(layout);
      await send(layout, r);
      _applied = (id: layout.id, updatedAt: layout.updatedAt);
      if (_cued?.id == layout.id) _cued = null;
      return r;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // ── Library ────────────────────────────────────────────────────────────────

  /// "Save current look": a new layout from the show as it is. Returns it and
  /// the names of anything on air that couldn't be saved.
  Future<({StudioLayout layout, List<String> leftOut})> saveCurrent(
    String name,
  ) async {
    await load();
    final snap = _snapshot(name);
    final saved = await backend.create(
      snap.layout.copyWith(sort: _layouts.length),
    );
    _layouts = [..._layouts, saved];
    notifyListeners();
    return (layout: saved, leftOut: snap.leftOut);
  }

  /// "Update from current look": [l]'s contents become the show as it is.
  Future<List<String>> updateFromCurrent(StudioLayout l) async {
    await load();
    final snap = _snapshot(l.name);
    final s = snap.layout;
    await _replace(
      l.copyWith(
        cameras: s.cameras,
        angles: s.angles,
        defaultAngle: s.defaultAngle,
        clearDefault: s.defaultAngle == null,
        order: s.order,
      ),
    );
    return snap.leftOut;
  }

  Future<void> rename(StudioLayout l, String name) =>
      _replace(l.copyWith(name: name));

  Future<void> duplicate(StudioLayout l) async {
    final base = l.name.trim();
    final copy = await backend.create(
      l.copyWith(
        name: '${base.length > 55 ? base.substring(0, 55) : base} copy',
        sort: _layouts.length,
      ),
    );
    _layouts = [..._layouts, copy];
    notifyListeners();
  }

  Future<void> delete(StudioLayout l) async {
    await backend.delete(l);
    _layouts = [
      for (final x in _layouts)
        if (x.id != l.id) x,
    ];
    if (_cued?.id == l.id) _cued = null;
    notifyListeners();
  }

  /// Drag to reorder: [from] moves to [to] (indices after removal, as
  /// `onReorderItem` gives them).
  Future<void> move(int from, int to) async {
    final list = [..._layouts];
    list.insert(to, list.removeAt(from));
    final before = _layouts;
    _layouts = [for (final (i, l) in list.indexed) l.copyWith(sort: i)];
    notifyListeners();
    try {
      // Old sorts on purpose: the backend writes only the ones that moved.
      await backend.reorder(list);
    } catch (_) {
      _layouts = before;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _replace(StudioLayout next) async {
    final saved = await backend.update(next);
    _layouts = [for (final x in _layouts) x.id == saved.id ? saved : x];
    _refreshCue();
    notifyListeners();
  }

  ({StudioLayout layout, List<String> leftOut}) _snapshot(String name) {
    final s = current();
    return snapshotLayout(
      name: name,
      positions: s.positions,
      libraryGraphics: _graphics.keys.toSet(),
      libraryElements: _elements.keys.toSet(),
      graphics: s.graphics,
      elements: s.elements,
      overlay: s.overlay,
      show: s.show,
    );
  }
}
