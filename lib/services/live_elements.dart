import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../theme.dart';
import 'brand_kit.dart';
import 'overlay_layout.dart';
import 'studio_graphics.dart' show GraphicTargets;

/// Studio live elements (docs/plans/studio-live-elements-foundation.md).
///
/// Three shapes of the same thing, like graphics:
///  - [StudioElement] — saved in the host's library (`studio_elements`,
///    owner-only).
///  - [LiveElement] — the element as it stands in a show: settings, live
///    values, clocks, where it is on air. Stored per event server-side
///    (`live_element_state`) and, while on air, in room metadata `elements`.
///  - [ElementsState] — every on-air element, as viewers read it.
///
/// Mirrors supabase/functions/_shared/elements.ts.

// ── Clocks ───────────────────────────────────────────────────────────────────

enum ClockOpKind { start, pause, reset, set }

/// A Studio command for one of an element's clocks. The server applies it with
/// its own time; the Studio applies it locally too, so the panel never waits.
@immutable
class ClockOp {
  const ClockOp(this.kind, [this.ms]);
  static const start = ClockOp(ClockOpKind.start);
  static const pause = ClockOp(ClockOpKind.pause);
  static const reset = ClockOp(ClockOpKind.reset);

  final ClockOpKind kind;

  /// [ClockOpKind.set] only: the new reading.
  final int? ms;

  Map<String, dynamic> toJson() => {
    'op': kind.name,
    if (kind == ClockOpKind.set) 'ms': ms ?? 0,
  };
}

/// A stopwatch in server ms: [elapsedMs] banked, plus the time since
/// [runningSince] while it runs. Each phone reads it against its own estimate
/// of the server clock (ServerClock).
@immutable
class ElementClock {
  const ElementClock({this.elapsedMs = 0, this.runningSince, this.pausedAt});

  static const _dayMs = 86400000;

  final int elapsedMs;
  final int? runningSince;
  final int? pausedAt;

  bool get running => runningSince != null;

  int valueAt(int serverNowMs) =>
      elapsedMs + (running ? math.max(0, serverNowMs - runningSince!) : 0);

  ElementClock apply(ClockOp op, int serverNowMs) => switch (op.kind) {
    ClockOpKind.start =>
      running
          ? this
          : ElementClock(elapsedMs: elapsedMs, runningSince: serverNowMs),
    ClockOpKind.pause =>
      running
          ? ElementClock(
              elapsedMs: valueAt(serverNowMs),
              pausedAt: serverNowMs,
            )
          : this,
    ClockOpKind.reset => const ElementClock(),
    ClockOpKind.set =>
      running
          ? ElementClock(
              elapsedMs: (op.ms ?? 0).clamp(0, _dayMs),
              runningSince: serverNowMs,
            )
          : ElementClock(
              elapsedMs: (op.ms ?? 0).clamp(0, _dayMs),
              pausedAt: pausedAt,
            ),
  };

  static ElementClock? fromJson(Object? j) {
    if (j is! Map || j['elapsedMs'] is! num) return null;
    return ElementClock(
      elapsedMs: (j['elapsedMs'] as num).toInt(),
      runningSince: (j['runningSince'] as num?)?.toInt(),
      pausedAt: (j['pausedAt'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
    'elapsedMs': elapsedMs,
    'runningSince': ?runningSince,
    'pausedAt': ?pausedAt,
  };

  @override
  bool operator ==(Object other) =>
      other is ElementClock &&
      other.elapsedMs == elapsedMs &&
      other.runningSince == runningSince &&
      other.pausedAt == pausedAt;

  @override
  int get hashCode => Object.hash(elapsedMs, runningSince, pausedAt);
}

/// "4:05", "1:02:03".
String formatClock(int ms) {
  final d = Duration(milliseconds: math.max(0, ms));
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  if (d.inHours > 0) {
    return '${d.inHours}:${(d.inMinutes % 60).toString().padLeft(2, '0')}:$s';
  }
  return '${d.inMinutes}:$s';
}

// ── Kinds ────────────────────────────────────────────────────────────────────

/// What the app knows about one kind of element, without any UI (that lives in
/// lib/widgets/elements/element_kinds.dart). Mirrors ELEMENT_KINDS on the
/// server. Elements of a kind this build doesn't know are dropped unseen.
@immutable
class ElementKindSpec {
  const ElementKindSpec({
    required this.wire,
    required this.label,
    required this.defaultConfig,
    required this.defaultState,
    required this.defaultSpot,
    this.clocks = const [],
    this.hidden = false,
    this.validate,
  });

  final String wire;
  final String label;
  final Map<String, dynamic> defaultConfig;
  final Map<String, dynamic> defaultState;
  final LayoutSpot defaultSpot;

  /// Clock names the kind runs.
  final List<String> clocks;

  /// Test-only: offered in the Studio only in debug builds.
  final bool hidden;

  /// Why a config can't be saved, or null.
  final String? Function(Map<String, dynamic> config)? validate;
}

String? _counterConfigError(Map<String, dynamic> c) {
  final label = c['label'];
  if (label is! String || label.length > 40) {
    return 'Label is 40 characters at most.';
  }
  final step = c['step'] ?? 1;
  if (step is! int || step < 1 || step > 100) return 'Step is 1 to 100.';
  return null;
}

abstract final class ElementKinds {
  /// A labelled number with a stopwatch — the hidden test kind that exercises
  /// the whole path before real kinds (scoreboard, poll) arrive.
  static const counter = ElementKindSpec(
    wire: 'counter',
    label: 'Counter (test)',
    defaultConfig: {'label': 'Count', 'step': 1},
    defaultState: {'value': 0},
    defaultSpot: LayoutSpot.tr,
    clocks: ['main'],
    hidden: true,
    validate: _counterConfigError,
  );

  static const all = [counter];

  static ElementKindSpec? of(Object? wire) =>
      all.where((k) => k.wire == wire).firstOrNull;

  /// Kinds the Studio offers under "New element".
  static List<ElementKindSpec> offered({bool debug = kDebugMode}) => [
    for (final k in all)
      if (!k.hidden || debug) k,
  ];
}

// ── Style ────────────────────────────────────────────────────────────────────

/// An element's look: the brand kit, with per-element overrides (team
/// colours…), or Nile's own style. Stored in `studio_elements.style`.
@immutable
class ElementStyle {
  const ElementStyle({
    this.nileStyle = false,
    this.accent,
    this.panel,
    this.text,
    this.onAccent,
    this.font,
  });

  static const none = ElementStyle();

  final bool nileStyle;
  final String? accent;
  final String? panel;
  final String? text;
  final String? onAccent;
  final String? font;

  bool get hasOverrides =>
      accent != null ||
      panel != null ||
      text != null ||
      onAccent != null ||
      font != null;

  /// What viewers draw with: null = Nile style.
  BrandStyle? resolve(BrandStyle? kit) {
    if (nileStyle || (kit == null && !hasOverrides)) return null;
    final base =
        kit ??
        BrandStyle(
          accent: hexFromColor(NileColors.volt),
          panel: hexFromColor(NileColors.bgSurface),
          text: hexFromColor(NileColors.txtPrimary),
          onAccent: hexFromColor(NileColors.onVolt),
        );
    return BrandStyle(
      accent: accent ?? base.accent,
      panel: panel ?? base.panel,
      text: text ?? base.text,
      onAccent: onAccent ?? base.onAccent,
      font: font ?? base.font,
    );
  }

  /// Why it can't be saved, or null.
  String? get error {
    for (final c in [accent, panel, text, onAccent]) {
      if (c != null && !isBrandHex(c)) return 'Colours are #RRGGBB.';
    }
    if (font != null && !brandFonts.contains(font)) return 'Pick a listed font.';
    return null;
  }

  factory ElementStyle.fromJson(Object? j) {
    if (j is! Map) return none;
    String? hex(Object? v) => isBrandHex(v) ? (v as String).toUpperCase() : null;
    return ElementStyle(
      nileStyle: j['nileStyle'] == true,
      accent: hex(j['accent']),
      panel: hex(j['panel']),
      text: hex(j['text']),
      onAccent: hex(j['onAccent']),
      font: brandFonts.contains(j['font']) ? j['font'] as String : null,
    );
  }

  Map<String, dynamic> toJson() => {
    if (nileStyle) 'nileStyle': true,
    'accent': ?accent,
    'panel': ?panel,
    'text': ?text,
    'onAccent': ?onAccent,
    'font': ?font,
  };

  @override
  bool operator ==(Object other) =>
      other is ElementStyle &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

// ── Library ──────────────────────────────────────────────────────────────────

/// A saved element.
@immutable
class StudioElement {
  const StudioElement({
    required this.id,
    required this.kind,
    required this.name,
    this.config = const {},
    this.style = ElementStyle.none,
    this.sort = 0,
  });

  factory StudioElement.fromRow(Map<String, dynamic> r) => StudioElement(
    id: r['id'] as String,
    kind: r['kind'] as String,
    name: r['name'] as String,
    config: Map<String, dynamic>.from(r['config'] as Map? ?? const {}),
    style: ElementStyle.fromJson(r['style']),
    sort: (r['sort'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String kind;
  final String name;
  final Map<String, dynamic> config;
  final ElementStyle style;
  final int sort;

  ElementKindSpec? get spec => ElementKinds.of(kind);

  StudioElement copyWith({
    String? name,
    Map<String, dynamic>? config,
    ElementStyle? style,
    int? sort,
  }) => StudioElement(
    id: id,
    kind: kind,
    name: name ?? this.name,
    config: config ?? this.config,
    style: style ?? this.style,
    sort: sort ?? this.sort,
  );

  /// Why it can't be saved, or null.
  String? get error {
    final k = spec;
    if (k == null) return 'This app doesn’t know that kind of element.';
    final n = name.trim();
    if (n.isEmpty || n.length > 60) return 'Name is 1–60 characters.';
    return style.error ?? k.validate?.call(config);
  }
}

// ── Live ─────────────────────────────────────────────────────────────────────

/// Targets on the wire: `{all: true, except?}` or `{slots}` (empty = off air).
Map<String, dynamic> targetsToJson(GraphicTargets t) => t.all
    ? {
        'all': true,
        if (t.except.isNotEmpty) 'except': [...t.except]..sort(),
      }
    : {'slots': [...t.slots]..sort()};

GraphicTargets targetsFromJson(Object? j) {
  if (j is! Map) return GraphicTargets.none;
  Set<String> ids(Object? l) => l is List ? l.whereType<String>().toSet() : {};
  return j['all'] == true
      ? GraphicTargets.all(except: ids(j['except']))
      : GraphicTargets.only(ids(j['slots']));
}

/// An element in a show.
@immutable
class LiveElement {
  const LiveElement({
    required this.id,
    required this.kind,
    required this.name,
    this.config = const {},
    this.state = const {},
    this.clocks = const {},
    this.style,
    this.nileStyle = false,
    this.targets = GraphicTargets.none,
    this.presentedBy,
    this.version = 0,
    this.at,
  });

  /// A library item's first appearance in a show: default values, off air.
  factory LiveElement.fromLibrary(StudioElement e, {BrandStyle? kit}) =>
      LiveElement(
        id: e.id,
        kind: e.kind,
        name: e.name,
        config: e.config,
        state: Map.of(e.spec?.defaultState ?? const {}),
        style: e.style.resolve(kit),
        nileStyle: e.style.nileStyle,
      );

  final String id;
  final String kind;
  final String name;
  final Map<String, dynamic> config;

  /// Kind-specific live values (score, votes…), clocks aside.
  final Map<String, dynamic> state;
  final Map<String, ElementClock> clocks;

  /// Resolved look; null = Nile style.
  final BrandStyle? style;
  final bool nileStyle;
  final GraphicTargets targets;

  /// Sponsor hook: the campaign presenting it. No UI yet.
  final String? presentedBy;

  /// The last version the server accepted (0 = never pushed).
  final int version;

  /// Server ms the last change refers to (viewer hold-back).
  final int? at;

  bool get onAir => !targets.isNone;

  ElementKindSpec? get spec => ElementKinds.of(kind);

  ElementClock clock(String name) => clocks[name] ?? const ElementClock();

  /// Settings, name and look from a (possibly edited) library item; live
  /// values and targets stay.
  LiveElement withLibrary(StudioElement e, {BrandStyle? kit}) => copyWith(
    name: e.name,
    config: e.config,
    style: e.style.resolve(kit),
    clearStyle: e.style.resolve(kit) == null,
    nileStyle: e.style.nileStyle,
  );

  LiveElement copyWith({
    String? name,
    Map<String, dynamic>? config,
    Map<String, dynamic>? state,
    Map<String, ElementClock>? clocks,
    BrandStyle? style,
    bool clearStyle = false,
    bool? nileStyle,
    GraphicTargets? targets,
    int? version,
    int? at,
  }) => LiveElement(
    id: id,
    kind: kind,
    name: name ?? this.name,
    config: config ?? this.config,
    state: state ?? this.state,
    clocks: clocks ?? this.clocks,
    style: clearStyle ? null : style ?? this.style,
    nileStyle: nileStyle ?? this.nileStyle,
    targets: targets ?? this.targets,
    presentedBy: presentedBy,
    version: version ?? this.version,
    at: at ?? this.at,
  );

  /// [ops] applied to this element's clocks at [serverNowMs].
  LiveElement withClockOps(Map<String, ClockOp> ops, int serverNowMs) {
    if (ops.isEmpty) return this;
    final next = {...clocks};
    ops.forEach((name, op) => next[name] = clock(name).apply(op, serverNowMs));
    return copyWith(clocks: next);
  }

  static LiveElement? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], kind = j['kind'], name = j['name'];
    // A kind this build doesn't know is dropped, never drawn wrong.
    if (id is! String || kind is! String || ElementKinds.of(kind) == null) {
      return null;
    }
    final rawState = j['state'] is Map
        ? Map<String, dynamic>.from(j['state'] as Map)
        : <String, dynamic>{};
    final rawClocks = rawState.remove('clocks');
    final clocks = <String, ElementClock>{};
    if (rawClocks is Map) {
      rawClocks.forEach((k, v) {
        final c = ElementClock.fromJson(v);
        if (k is String && c != null) clocks[k] = c;
      });
    }
    return LiveElement(
      id: id,
      kind: kind,
      name: name is String ? name : '',
      config: j['config'] is Map
          ? Map<String, dynamic>.from(j['config'] as Map)
          : const {},
      state: rawState,
      clocks: clocks,
      style: BrandStyle.fromJson(j['style']),
      nileStyle: j['nileStyle'] == true,
      targets: targetsFromJson(j['targets']),
      presentedBy: j['presentedBy'] as String?,
      version: (j['version'] as num?)?.toInt() ?? 0,
      at: (j['at'] as num?)?.toInt(),
    );
  }

  /// What the Studio pushes (set-element) and what viewers read.
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'name': name,
    'config': config,
    'state': {
      ...state,
      if (clocks.isNotEmpty)
        'clocks': {for (final e in clocks.entries) e.key: e.value.toJson()},
    },
    'style': ?style?.toJson(),
    if (nileStyle) 'nileStyle': true,
    'targets': targetsToJson(targets),
    'presentedBy': ?presentedBy,
    'version': version,
  };

  @override
  bool operator ==(Object other) =>
      other is LiveElement &&
      other.at == at &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// Every element on air: room metadata `elements`.
@immutable
class ElementsState {
  const ElementsState({this.items = const [], this.at});

  static const empty = ElementsState();

  final List<LiveElement> items;

  /// Server ms the latest change refers to.
  final int? at;

  bool get isEmpty => items.isEmpty;

  /// Any element with a clock — viewers then need the server clock.
  bool get hasClocks => items.any((e) => e.clocks.isNotEmpty);

  factory ElementsState.fromRoomMetadata(String? raw) {
    try {
      final m = jsonDecode(raw ?? '{}');
      return m is Map ? ElementsState.fromJson(m['elements']) : empty;
    } catch (_) {
      return empty;
    }
  }

  factory ElementsState.fromJson(Object? j) {
    if (j is! Map || j['items'] is! List) return empty;
    return ElementsState(
      items: (j['items'] as List)
          .map(LiveElement.fromJson)
          .whereType<LiveElement>()
          .toList(),
      at: (j['at'] as num?)?.toInt(),
    );
  }

  /// What a viewer watching [slotId] sees (null = a screen share: all-camera
  /// elements only).
  List<LiveElement> forSlot(String? slotId) => [
    for (final e in items)
      if (slotId == null ? e.targets.all : e.targets.includes(slotId)) e,
  ];

  @override
  bool operator ==(Object other) =>
      other is ElementsState && other.at == at && listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(at, Object.hashAll(items));
}

/// An element waiting in the Studio for Take, next to cued graphics. Only
/// where it goes is cued; its values are whatever they are at Take.
@immutable
class ElementCue {
  const ElementCue({
    required this.id,
    required this.name,
    required this.targets,
  });

  final String id;
  final String name;
  final GraphicTargets targets;

  ElementCue withTargets(GraphicTargets t) =>
      ElementCue(id: id, name: name, targets: t);

  @override
  bool operator ==(Object other) =>
      other is ElementCue &&
      other.id == id &&
      other.name == name &&
      other.targets == targets;

  @override
  int get hashCode => Object.hash(id, name, targets);
}
