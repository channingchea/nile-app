import 'dart:async';

import 'package:flutter/foundation.dart';

import 'analytics.dart';
import 'brand_kit.dart';
import 'live_elements.dart';
import 'livekit_service.dart' show ElementStale;
import 'server_clock.dart';
import 'studio_graphics.dart' show CueSet, GraphicTargets;

/// Sends one element (its next version) with clock commands; returns it as
/// the server stored it. Throws [ElementStale] when out of step.
typedef ElementPush =
    Future<LiveElement> Function(
      LiveElement element,
      Map<String, ClockOp> clockOps,
    );

/// What `list-elements` returns: every element in the show and the totals of
/// those viewers can tap.
typedef ElementsSnapshot = ({
  List<LiveElement> elements,
  Map<String, ElementTally> tallies,
});

/// The Studio's side of live elements (phase 3): the latest known state of
/// every element in this show — on air or not — applied locally at once and
/// pushed in order, one element at a time, so a burst of "+1"s never races.
///
/// The real Studio pushes through `set-element`; Studio Preview passes a
/// local stand-in. [load] reloads from the server (`list-elements`) when the
/// Studio (re)joins — a dropped Studio picks up exactly where it was.
class StudioElementsController extends ChangeNotifier {
  StudioElementsController({
    required this.push,
    this.load,
    this.removeRemote,
    this.onError,
    this.rehearsal = false,
  });

  /// Studio Preview's controller: nothing leaves the device, and analytics
  /// marks what it reports as a rehearsal.
  final bool rehearsal;

  final ElementPush push;

  /// Every element in the show and its totals (`list-elements`).
  final Future<ElementsSnapshot> Function()? load;

  /// Drops an element's live state server-side (`set-element` remove).
  final Future<void> Function(String id)? removeRemote;

  /// A push that failed (message for a toast).
  final ValueChanged<String>? onError;

  final Map<String, LiveElement> _live = {};
  final Map<String, List<LiveElement>> _undo = {};
  final Map<String, Future<void>> _queue = {};
  final Map<String, ElementTally> _tallies = {};

  /// An element's totals, live from the system topic (and on reload).
  ElementTally? tally(String id) => _tallies[id];

  void setTally(String id, ElementTally tally) {
    _tallies[id] = tally;
    notifyListeners();
  }

  /// Elements shown as their own angle (phase 4).
  List<LiveElement> get angles => [
    for (final e in _live.values)
      if (e.angle) e,
  ]..sort((a, b) => a.id.compareTo(b.id));

  /// Changes that can be undone per element.
  static const undoDepth = 10;

  List<StudioElement> _library = const [];
  BrandStyle? _kit;

  List<StudioElement> get library => _library;
  BrandStyle? get kit => _kit;

  LiveElement? live(String id) => _live[id];

  /// Every element on air, as viewers see it.
  ElementsState get onAir => ElementsState(
    items: [
      for (final e in _live.values)
        if (e.onAir) e,
    ],
  );

  /// What the monitor shows: on air plus every cued element where it is cued.
  ElementsState preview(CueSet cues) {
    final cued = {for (final c in cues.elements) c.id: c.targets};
    return ElementsState(
      items: [
        for (final e in _live.values)
          if (cued[e.id] case final t?)
            e.copyWith(targets: _union(e.targets, t))
          else if (e.onAir)
            e,
        for (final c in cues.elements)
          if (!_live.containsKey(c.id))
            if (_seed(c.id) case final e?) e.copyWith(targets: c.targets),
      ],
    );
  }

  static GraphicTargets _union(GraphicTargets a, GraphicTargets b) {
    if (a.isNone) return b;
    if (a.all || b.all) {
      final ex = a.all && b.all
          ? a.except.intersection(b.except)
          : a.all
          ? a.except.difference(b.slots)
          : b.except.difference(a.slots);
      return GraphicTargets.all(except: ex);
    }
    return GraphicTargets.only({...a.slots, ...b.slots});
  }

  /// The library changed (loaded, edited, kit changed). Elements already in
  /// the show take the new name, settings and look — pushed if on air.
  void setLibrary(List<StudioElement> library, {BrandStyle? kit}) {
    _library = library;
    _kit = kit;
    for (final e in library) {
      final cur = _live[e.id];
      if (cur == null) continue;
      final next = cur.withLibrary(e, kit: kit);
      if (next != cur) {
        unawaited(update(e.id, (_) => next, undoable: false, pushOffAir: false));
      }
    }
    notifyListeners();
  }

  LiveElement? _seed(String id) {
    final lib = _library.where((e) => e.id == id).firstOrNull;
    return lib == null ? null : LiveElement.fromLibrary(lib, kit: _kit);
  }

  /// The element as it stands, or a fresh one from the library.
  LiveElement? current(String id) => _live[id] ?? _seed(id);

  bool canUndo(String id) => _undo[id]?.isNotEmpty ?? false;

  /// Change one element: [change] gets the current state; [clockOps] run its
  /// clocks. Applied here at once, then pushed. Off-air elements with no
  /// state on the server yet are kept locally until they first go on air,
  /// unless [pushOffAir].
  Future<bool> update(
    String id,
    LiveElement Function(LiveElement current) change, {
    Map<String, ClockOp> clockOps = const {},
    bool undoable = true,
    bool pushOffAir = true,
  }) async {
    final base = current(id);
    if (base == null) return false;
    var next = change(base).withClockOps(clockOps, ServerClock.now());
    next = next.copyWith(version: base.version + 1);
    if (undoable) {
      final stack = _undo.putIfAbsent(id, () => []);
      stack.add(base);
      if (stack.length > undoDepth) stack.removeAt(0);
    }
    _live[id] = next;
    notifyListeners();
    if (!pushOffAir && !next.onAir && base.version == 0) {
      _track(base, next);
      return true;
    }
    final ok = await _send(next, clockOps);
    if (ok) _track(base, next);
    return ok;
  }

  /// PostHog: what the host did with an element — its kind and counts, never
  /// its name or values.
  void _track(LiveElement was, LiveElement now) {
    final props = <String, Object>{'kind': now.kind, 'preview': rehearsal};
    final t = now.targets;
    if (was.targets.isNone && !t.isNone) {
      NileAnalytics.capture(NileEvent.elementTaken, {
        ...props,
        'all_cameras': t.all,
        if (!t.all) 'cameras': t.slots.length,
      });
    }
    if (!was.angle && now.angle) {
      NileAnalytics.capture(NileEvent.elementAngleShown, props);
    }
    if (was.open != now.open && now.choices.isNotEmpty) {
      NileAnalytics.capture(
        now.open ? NileEvent.elementTapsOpened : NileEvent.elementTapsClosed,
        props,
      );
    }
  }

  /// Show [id] as its own angle, or stop.
  Future<bool> setAngle(String id, bool on) =>
      update(id, (e) => e.copyWith(angle: on), undoable: false);

  /// Put [id] on [targets] (none = off air) — Take, or a retarget.
  Future<bool> setTargets(String id, GraphicTargets targets) =>
      update(id, (e) => e.copyWith(targets: targets), undoable: false);

  /// Back one change: values as they were, each clock back to its old
  /// reading (running or paused as it is now; where it is on air is left
  /// alone).
  Future<bool> undo(String id) {
    final stack = _undo[id];
    if (stack == null || stack.isEmpty) return Future.value(false);
    final prev = stack.removeLast();
    return update(
      id,
      (cur) => cur.copyWith(state: prev.state, config: prev.config),
      undoable: false,
      clockOps: _clockRestore(prev),
    );
  }

  /// Clocks are the server's to stamp: undo sends each one's old reading as a
  /// `set`.
  Map<String, ClockOp> _clockRestore(LiveElement prev) => {
    for (final e in prev.clocks.entries)
      e.key: ClockOp(ClockOpKind.set, e.value.valueAt(ServerClock.now())),
  };

  /// Out of the show entirely (its library item was deleted).
  Future<void> remove(String id) async {
    final had = _live.remove(id);
    _undo.remove(id);
    notifyListeners();
    if (had != null && had.version > 0) {
      try {
        await removeRemote?.call(id);
      } catch (err) {
        onError?.call(err.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  /// Every element in the show from the server — they win over local state.
  Future<void> restore() async {
    final fetch = load;
    if (fetch == null) return;
    try {
      final snap = await fetch();
      for (final e in snap.elements) {
        final mine = _live[e.id];
        if (mine == null || mine.version <= e.version) _live[e.id] = e;
      }
      _tallies.addAll(snap.tallies);
      notifyListeners();
    } catch (_) {
      // Next push or rejoin tries again.
    }
  }

  Future<bool> _send(LiveElement e, Map<String, ClockOp> ops) {
    final done = Completer<bool>();
    final prev = _queue[e.id] ?? Future.value();
    _queue[e.id] = prev.then((_) async {
      try {
        final stored = await push(e, ops);
        // Don't clobber anything newer made while this was in flight.
        if ((_live[e.id]?.version ?? 0) <= stored.version) {
          _live[e.id] = stored;
          notifyListeners();
        }
        done.complete(true);
      } on ElementStale catch (s) {
        final cur = s.current;
        if (cur != null) _live[e.id] = cur;
        notifyListeners();
        onError?.call(s.toString());
        done.complete(false);
      } catch (err) {
        onError?.call(err.toString().replaceFirst('Exception: ', ''));
        done.complete(false);
      }
    });
    return done.future;
  }
}
