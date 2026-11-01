import 'package:flutter/foundation.dart';

import 'analytics.dart';
import 'brand_kit.dart';
import 'elements_service.dart';
import 'graphics_service.dart';
import 'layout_templates.dart';
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

Future<StudioGraphic> _createGraphic(StudioGraphic g) => GraphicsService.create(
  kind: g.kind,
  name: g.name,
  payload: g.payload,
  sort: g.sort,
);

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
    this.createGraphic = _createGraphic,
  });

  /// Studio Preview: starts from your saved layouts and graphics (read once)
  /// but saves nowhere — every change lives in memory and is gone when you
  /// leave. [elements] is the preview's own element library.
  factory LayoutsBackend.rehearsal({
    required Future<List<StudioElement>> Function() elements,
    Future<List<StudioLayout>> Function() savedLayouts = LayoutsService.list,
    Future<List<StudioGraphic>> Function() savedGraphics = GraphicsService.list,
  }) {
    final m = _Memory(savedLayouts, savedGraphics);
    return LayoutsBackend(
      list: m.list,
      create: m.create,
      update: m.update,
      delete: m.delete,
      reorder: (_) async {},
      graphics: m.graphicsList,
      elements: elements,
      createGraphic: m.createGraphic,
    );
  }

  final Future<List<StudioLayout>> Function() list;
  final Future<StudioLayout> Function(StudioLayout) create;
  final Future<StudioLayout> Function(StudioLayout) update;
  final Future<void> Function(StudioLayout) delete;
  final Future<void> Function(List<StudioLayout>) reorder;
  final Future<List<StudioGraphic>> Function() graphics;
  final Future<List<StudioElement>> Function() elements;

  /// Templates save the graphics they need here.
  final Future<StudioGraphic> Function(StudioGraphic) createGraphic;
}

/// Deep equality for JSON-shaped values (jsonb comes back with its keys
/// reordered, so encoded strings can't be compared).
bool _sameJson(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _sameJson(a[k], b[k]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameJson(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// In-memory layouts and graphics, seeded once from the account.
class _Memory {
  _Memory(this._savedLayouts, this._savedGraphics);

  final Future<List<StudioLayout>> Function() _savedLayouts;
  final Future<List<StudioGraphic>> Function() _savedGraphics;
  List<StudioLayout> _layouts = [];
  final List<StudioGraphic> _graphics = [];
  Future<void>? _seeded;
  int _next = 0;

  // Offline or signed out: start empty.
  Future<void> _seed() => _seeded ??= () async {
    try {
      _layouts = [...await _savedLayouts()];
    } catch (_) {}
    try {
      _graphics.addAll(await _savedGraphics());
    } catch (_) {}
  }();

  String _id() =>
      '00000000-0000-4000-8000-${(_next++).toString().padLeft(12, '0')}';

  Future<List<StudioLayout>> list() async {
    await _seed();
    return [..._layouts];
  }

  StudioLayout _stamp(StudioLayout l, String id) => StudioLayout.fromPayload(
    l.payload,
    id: id,
    name: l.name.trim(),
    template: l.template,
    sort: l.sort,
    updatedAt: DateTime.now().toUtc(),
  );

  Future<StudioLayout> create(StudioLayout l) async {
    await _seed();
    final error = l.error;
    if (error != null) throw ArgumentError(error);
    final saved = _stamp(l, _id());
    _layouts.add(saved);
    return saved;
  }

  Future<StudioLayout> update(StudioLayout l) async {
    final error = l.error;
    if (error != null) throw ArgumentError(error);
    final saved = _stamp(l, l.id);
    _layouts = [for (final x in _layouts) x.id == l.id ? saved : x];
    return saved;
  }

  Future<void> delete(StudioLayout l) async =>
      _layouts.removeWhere((x) => x.id == l.id);

  Future<List<StudioGraphic>> graphicsList() async {
    await _seed();
    return [..._graphics];
  }

  Future<StudioGraphic> createGraphic(StudioGraphic g) async {
    final saved = StudioGraphic(
      id: 'preview-graphic-${_next++}',
      kind: g.kind,
      name: g.name,
      payload: g.payload,
      sort: g.sort,
    );
    _graphics.add(saved);
    return saved;
  }
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
    this.rehearsal = false,
  });

  /// Studio Preview: analytics marks what it reports as a rehearsal.
  final bool rehearsal;

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
    if (next != null) {
      onCue?.call();
      _capture(NileEvent.layoutCued, next);
    }
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
      _capture(NileEvent.layoutApplied, layout, {
        'covered': r.covered.length,
        'elements_changed': r.elements.length,
      });
      if (r.missingCount > 0) {
        _capture(NileEvent.layoutMissingItems, layout, {
          'missing': r.missingCount,
        });
      }
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
    _capture(NileEvent.layoutSaved, saved, {'how': 'current_look'});
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

  /// Save what the editor made: a new layout (no id yet) or an edit.
  Future<StudioLayout> save(StudioLayout l) async {
    if (l.id.isNotEmpty) {
      await _replace(l);
      final saved = _layouts.firstWhere((x) => x.id == l.id);
      _capture(NileEvent.layoutSaved, saved, {'how': 'editor'});
      return saved;
    }
    final saved = await backend.create(l.copyWith(sort: _layouts.length));
    _layouts = [..._layouts, saved];
    _capture(NileEvent.layoutSaved, saved, {'how': 'editor'});
    notifyListeners();
    return saved;
  }

  /// "New from template": the graphics it needs go into the library (an
  /// identical one already there is reused), then a layout sized to this
  /// show's cameras.
  Future<StudioLayout> newFromTemplate(LayoutTemplate t) async {
    await load();
    final ids = <String, String>{};
    for (final draft in t.graphics) {
      final same = _graphics.values.where(
        (g) => g.kind == draft.kind && _sameJson(g.payload, draft.payload),
      );
      if (same.isNotEmpty) {
        ids[draft.id] = same.first.id;
        continue;
      }
      final saved = await backend.createGraphic(
        StudioGraphic(
          id: '',
          kind: draft.kind,
          name: draft.name,
          payload: draft.payload,
          sort: _graphics.length,
        ),
      );
      _graphics = {..._graphics, saved.id: saved};
      ids[draft.id] = saved.id;
    }
    final cameras = current().positions.length;
    final layout = t.build((k) => ids[k]!, cameras < 1 ? 1 : cameras);
    final saved = await backend.create(layout.copyWith(sort: _layouts.length));
    _layouts = [..._layouts, saved];
    _capture(NileEvent.layoutSaved, saved, {'how': 'template'});
    notifyListeners();
    return saved;
  }

  /// PostHog: counts and the template id only — never a name.
  void _capture(
    NileEvent event,
    StudioLayout l, [
    Map<String, Object> extra = const {},
  ]) => NileAnalytics.capture(event, {
    'cameras': l.cameras.length,
    'template': ?l.template,
    'preview': rehearsal,
    ...extra,
  });

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
