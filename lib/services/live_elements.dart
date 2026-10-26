import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../theme.dart';
import 'brand_kit.dart';
import 'overlay_layout.dart';
import 'server_clock.dart';
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
          ? ElementClock(elapsedMs: valueAt(serverNowMs), pausedAt: serverNowMs)
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
    this.choices,
    this.maxPicks,
    this.labelOf,
    this.applyOps,
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

  /// What viewers may tap for this config (phase 5); null or empty = nothing.
  /// Mirrors KindRule.choices on the server.
  final List<String> Function(Map<String, dynamic> config)? choices;

  /// How many choices one vote may hold (null = one).
  final int Function(Map<String, dynamic> config)? maxPicks;

  /// A choice as people read it (null = the choice id itself).
  final String Function(Map<String, dynamic> config, String choice)? labelOf;

  /// Timer and reset applied locally the way the server applies them; null =
  /// the kind takes no [ElementOps].
  final Map<String, dynamic> Function(
    Map<String, dynamic> state,
    Map<String, dynamic> config,
    ElementOps ops,
    int serverNowMs,
  )?
  applyOps;
}

String? _counterConfigError(Map<String, dynamic> c) {
  final label = c['label'];
  if (label is! String || label.length > 40) {
    return 'Label is 40 characters at most.';
  }
  final step = c['step'] ?? 1;
  if (step is! int || step < 1 || step > 100) return 'Step is 1 to 100.';
  if (c['taps'] != null && c['taps'] is! bool) {
    return 'Taps setting is malformed.';
  }
  return null;
}

List<String> _counterChoices(Map<String, dynamic> c) =>
    c['taps'] == true ? const ['up', 'down'] : const [];

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
    choices: _counterChoices,
  );

  /// Multiple choice, yes/no, rating 1–5 or pick several
  /// (docs/plans/studio-poll.md).
  static const poll = ElementKindSpec(
    wire: 'poll',
    label: 'Poll',
    defaultConfig: {
      'type': 'choice',
      'question': '',
      'answers': [
        {'id': 'a1', 'text': ''},
        {'id': 'a2', 'text': ''},
      ],
      'results': 'live',
    },
    defaultState: {},
    defaultSpot: LayoutSpot.mr,
    validate: _pollConfigError,
    choices: _pollChoices,
    maxPicks: _pollMaxPicks,
    labelOf: _pollLabel,
    applyOps: _pollOps,
  );

  static const all = [counter, poll];

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
    if (font != null && !brandFonts.contains(font)) {
      return 'Pick a listed font.';
    }
    return null;
  }

  factory ElementStyle.fromJson(Object? j) {
    if (j is! Map) return none;
    String? hex(Object? v) =>
        isBrandHex(v) ? (v as String).toUpperCase() : null;
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
    : {
        'slots': [...t.slots]..sort(),
      };

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
    this.angle = false,
    this.presentedBy,
    this.version = 0,
    this.at,
    this.ops = ElementOps.none,
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

  /// Also its own angle in viewers' pickers ([elementAngleId]) — full screen
  /// on its brand background (phase 4).
  final bool angle;

  /// Sponsor hook: the campaign presenting it. No UI yet.
  final String? presentedBy;

  /// The last version the server accepted (0 = never pushed).
  final int version;

  /// Server ms the last change refers to (viewer hold-back).
  final int? at;

  /// Timer/reset commands riding on one push (never stored).
  final ElementOps ops;

  bool get onAir => !targets.isNone;

  /// On a camera or as its own angle — viewers can see it.
  bool get live => onAir || angle;

  ElementKindSpec? get spec => ElementKinds.of(kind);

  /// Taps are being taken (the Studio opened them).
  bool get open => state['open'] == true;

  /// Everything a viewer could tap on it, open or not.
  List<String> get choices => spec?.choices?.call(config) ?? const [];

  /// How many choices one vote may hold.
  int get maxPicks => spec?.maxPicks?.call(config) ?? 1;

  /// [choice] as people read it ("Red", not "a1").
  String labelOf(String choice) =>
      spec?.labelOf?.call(config, choice) ?? choice;

  /// Voting ended by itself: its timer (`closesAt`, server ms) ran out.
  bool timedOutAt(int serverNowMs) {
    final c = state['closesAt'];
    return c is num && serverNowMs >= c;
  }

  /// What a viewer may tap right now: its choices while open (timer not run
  /// out) and live.
  List<String> get openChoices =>
      open && live && !timedOutAt(ServerClock.now()) ? choices : const [];

  /// [ops] applied locally (the server does the same with its own clock).
  LiveElement withOps(ElementOps ops, int serverNowMs) {
    final apply = spec?.applyOps;
    if (ops.isEmpty || apply == null) return this;
    return copyWith(state: apply(state, config, ops, serverNowMs));
  }

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
    bool? angle,
    int? version,
    int? at,
    ElementOps? ops,
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
    angle: angle ?? this.angle,
    presentedBy: presentedBy,
    version: version ?? this.version,
    at: at ?? this.at,
    ops: ops ?? this.ops,
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
      angle: j['angle'] == true,
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
    if (angle) 'angle': true,
    'presentedBy': ?presentedBy,
    'version': version,
    if (!ops.isEmpty) 'ops': ops.toJson(),
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

  /// Elements shown as their own angle, by id order.
  List<LiveElement> get angles => [
    for (final e in items)
      if (e.angle) e,
  ];

  LiveElement? byId(String id) => items.where((e) => e.id == id).firstOrNull;

  /// Any element viewers can tap right now.
  bool get takesTaps => items.any((e) => e.openChoices.isNotEmpty);

  /// What a viewer watching [slotId] sees (null = a screen share: all-camera
  /// elements only).
  List<LiveElement> forSlot(String? slotId) => [
    for (final e in items)
      if (slotId == null ? e.targets.all : e.targets.includes(slotId)) e,
  ];

  @override
  bool operator ==(Object other) =>
      other is ElementsState &&
      other.at == at &&
      listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(at, Object.hashAll(items));
}

// ── Element angles (phase 4) ─────────────────────────────────────────────────

/// An element shown as its own angle is a virtual camera with this id; show
/// control (off air, default, send everyone, order) takes it like a slot id.
String elementAngleId(String elementId) => 'el:$elementId';

bool isElementAngleId(String? id) => id != null && id.startsWith('el:');

/// The element behind an element-angle id, or null.
String? elementIdOfAngle(String? id) =>
    isElementAngleId(id) ? id!.substring(3) : null;

// ── Viewer taps (phase 5) ────────────────────────────────────────────────────

/// An element's totals: choice → count, and how many people voted. Hosts see
/// these, never who voted what.
@immutable
class ElementTally {
  const ElementTally([this.counts = const {}, this.voters]);

  static const empty = ElementTally();

  final Map<String, int> counts;

  /// People who voted; null = one vote each (the sum of [counts]). Fewer
  /// than the sum when a vote may hold several picks.
  final int? voters;

  int? operator [](String choice) => counts[choice];

  /// Every pick counted.
  int get votes => counts.values.fold(0, (a, b) => a + b);

  /// People who voted.
  int get people => voters ?? votes;

  @override
  bool operator ==(Object other) =>
      other is ElementTally &&
      other.voters == voters &&
      mapEquals(other.counts, counts);

  @override
  int get hashCode => Object.hash(
    voters,
    Object.hashAll(counts.entries.map((e) => (e.key, e.value))),
  );

  @override
  String toString() => 'ElementTally($counts, voters: $voters)';
}

/// Totals off the wire: `{choice: n}` plus, from newer servers, `voters`.
ElementTally? tallyFromJson(Object? j, [Object? voters]) {
  if (j is! Map) return null;
  return ElementTally({
    for (final e in j.entries)
      if (e.key is String && e.value is num)
        e.key as String: (e.value as num).toInt(),
  }, voters is num ? voters.toInt() : null);
}

/// Timer and reset commands for one push (polls). The server stamps the
/// result with its own clock; the Studio applies them locally too.
@immutable
class ElementOps {
  const ElementOps({this.timer, this.timerSec, this.reset = false});

  static const none = ElementOps();

  /// true = start (for [timerSec], else the element's own length), false =
  /// cancel, null = leave as it is.
  final bool? timer;
  final int? timerSec;

  /// A new round: every vote cleared.
  final bool reset;

  bool get isEmpty => timer == null && !reset;

  Map<String, dynamic> toJson() => {
    if (timer == true) 'timer': {'op': 'start', 'sec': ?timerSec},
    if (timer == false) 'timer': {'op': 'cancel'},
    if (reset) 'reset': true,
  };

  @override
  bool operator ==(Object other) =>
      other is ElementOps &&
      other.timer == timer &&
      other.timerSec == timerSec &&
      other.reset == reset;

  @override
  int get hashCode => Object.hash(timer, timerSec, reset);
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

// ── Polls (docs/plans/studio-poll.md) ────────────────────────────────────────

enum PollType {
  choice('Multiple choice'),
  yesno('Yes / no'),
  rating('Rating 1–5'),
  several('Pick several');

  const PollType(this.label);
  final String label;

  static PollType of(Object? wire) =>
      values.where((t) => t.name == wire).firstOrNull ?? choice;
}

/// Who sees a poll's totals.
enum PollResultsMode {
  live('Live', 'Everyone sees totals as votes come in.'),
  voted('After you vote', 'Each viewer sees totals once they have voted.'),
  reveal('Only when revealed', 'Nobody sees totals until you reveal them.');

  const PollResultsMode(this.label, this.hint);
  final String label;
  final String hint;

  static PollResultsMode of(Object? wire) =>
      values.where((t) => t.name == wire).firstOrNull ?? live;
}

/// Who is looking at an element: what decides whether a poll's totals show.
enum ElementAudience { viewer, staff, replay }

@immutable
class PollAnswer {
  const PollAnswer(this.id, this.text);
  final String id;
  final String text;

  Map<String, dynamic> toJson() => {'id': id, 'text': text};

  @override
  bool operator ==(Object other) =>
      other is PollAnswer && other.id == id && other.text == text;

  @override
  int get hashCode => Object.hash(id, text);
}

/// A poll's settings (its `config`). Mirrors cleanPollConfig on the server.
@immutable
class PollConfig {
  const PollConfig({
    this.type = PollType.choice,
    this.question = '',
    this.answers = const [],
    this.maxPicks,
    this.results = PollResultsMode.live,
    this.timerSec,
  });

  static const maxQuestion = 120;
  static const maxAnswer = 40;
  static const minAnswers = 2;
  static const maxAnswers = 6;
  static const minTimerSec = 10;
  static const maxTimerSec = 1800;

  static const yesNo = [PollAnswer('yes', 'Yes'), PollAnswer('no', 'No')];
  static const stars = [
    PollAnswer('1', '1'),
    PollAnswer('2', '2'),
    PollAnswer('3', '3'),
    PollAnswer('4', '4'),
    PollAnswer('5', '5'),
  ];

  final PollType type;
  final String question;

  /// Multiple choice and pick several: the host's answers.
  final List<PollAnswer> answers;

  /// Pick several: at most this many (null = any number).
  final int? maxPicks;
  final PollResultsMode results;

  /// The timer's default length (null = no timer).
  final int? timerSec;

  factory PollConfig.fromJson(Map<String, dynamic> j) => PollConfig(
    type: PollType.of(j['type']),
    question: j['question'] is String ? j['question'] as String : '',
    answers: [
      if (j['answers'] case final List l)
        for (final a in l)
          if (a is Map && a['id'] is String)
            PollAnswer(
              a['id'] as String,
              a['text'] is String ? a['text'] as String : '',
            ),
    ],
    maxPicks: (j['maxPicks'] as num?)?.toInt(),
    results: PollResultsMode.of(j['results']),
    timerSec: (j['timerSec'] as num?)?.toInt(),
  );

  bool get ownAnswers => type == PollType.choice || type == PollType.several;

  /// What viewers pick from: the host's answers, or yes/no, or 1–5.
  List<PollAnswer> get items => switch (type) {
    PollType.yesno => yesNo,
    PollType.rating => stars,
    _ => answers,
  };

  /// How many answers one vote may hold.
  int get pickLimit => type == PollType.several
      ? (maxPicks ?? items.length).clamp(1, math.max(1, items.length))
      : 1;

  String labelOf(String id) =>
      items.where((a) => a.id == id).firstOrNull?.text ?? id;

  /// Same answers in the same order (wording aside): what may change while
  /// votes point at them.
  bool sameAnswers(PollConfig o) =>
      o.type == type &&
      listEquals(
        [for (final a in o.items) a.id],
        [for (final a in items) a.id],
      );

  /// An id no answer here uses yet.
  String nextAnswerId() {
    var n = answers.length + 1;
    while (answers.any((a) => a.id == 'a$n')) {
      n++;
    }
    return 'a$n';
  }

  /// Why it can't be saved, or null.
  String? get error {
    final q = question.trim();
    if (q.isEmpty) return 'Write the question.';
    if (q.length > maxQuestion) {
      return 'The question is $maxQuestion characters at most.';
    }
    if (!ownAnswers) return null;
    if (answers.length < minAnswers) return 'Add at least two answers.';
    if (answers.length > maxAnswers) return 'Six answers at most.';
    final seen = <String>{};
    for (final a in answers) {
      final t = a.text.trim();
      if (t.isEmpty) return 'Fill in every answer, or remove the empty one.';
      if (t.length > maxAnswer) {
        return 'Answers are $maxAnswer characters at most.';
      }
      if (!seen.add(t.toLowerCase())) return '“$t” is in there twice.';
    }
    final m = maxPicks;
    if (type == PollType.several &&
        m != null &&
        (m < 1 || m > answers.length)) {
      return 'Max picks is 1 to ${answers.length}.';
    }
    final t = timerSec;
    if (t != null && (t < minTimerSec || t > maxTimerSec)) {
      return 'The timer is 10 seconds to 30 minutes.';
    }
    return null;
  }

  PollConfig copyWith({
    PollType? type,
    String? question,
    List<PollAnswer>? answers,
    int? maxPicks,
    bool clearMaxPicks = false,
    PollResultsMode? results,
    int? timerSec,
    bool clearTimer = false,
  }) => PollConfig(
    type: type ?? this.type,
    question: question ?? this.question,
    answers: answers ?? this.answers,
    maxPicks: clearMaxPicks ? null : maxPicks ?? this.maxPicks,
    results: results ?? this.results,
    timerSec: clearTimer ? null : timerSec ?? this.timerSec,
  );

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'question': question,
    if (ownAnswers) 'answers': [for (final a in answers) a.toJson()],
    if (type == PollType.several) 'maxPicks': ?maxPicks,
    'results': results.name,
    'timerSec': ?timerSec,
  };
}

/// A poll's live values (its `state`). [closesAt] and [round] are the
/// server's.
@immutable
class PollState {
  const PollState({
    this.open = false,
    this.revealed = false,
    this.closesAt,
    this.round = 0,
  });

  factory PollState.of(Map<String, dynamic> s) => PollState(
    open: s['open'] == true,
    revealed: s['revealed'] == true,
    closesAt: (s['closesAt'] as num?)?.toInt(),
    round: (s['round'] as num?)?.toInt() ?? 0,
  );

  final bool open;
  final bool revealed;

  /// Server ms the timer runs out (null = no timer running).
  final int? closesAt;

  /// Up one per reset.
  final int round;

  /// Taking votes at [serverNowMs].
  bool openAt(int serverNowMs) =>
      open && (closesAt == null || serverNowMs < closesAt!);

  /// Whole seconds left on the timer (rounded up), or null.
  int? secondsLeft(int serverNowMs) {
    final c = closesAt;
    if (!open || c == null) return null;
    return (math.max(0, c - serverNowMs) / 1000).ceil();
  }
}

/// Whether [audience] sees a poll's totals: live = always; after you vote =
/// once this viewer has (or the host reveals them); only when revealed =
/// after the reveal. The Studio
/// and host always do; replays follow the reveal.
bool pollResultsVisible(
  PollConfig c,
  PollState s, {
  required ElementAudience audience,
  bool voted = false,
}) => switch (audience) {
  ElementAudience.staff => true,
  ElementAudience.replay => c.results != PollResultsMode.reveal || s.revealed,
  ElementAudience.viewer => switch (c.results) {
    PollResultsMode.live => true,
    PollResultsMode.voted => voted || s.revealed,
    PollResultsMode.reveal => s.revealed,
  },
};

/// A poll's totals as people read them.
@immutable
class PollResults {
  const PollResults(this.config, this.tally);

  final PollConfig config;
  final ElementTally tally;

  int count(String id) => tally[id] ?? 0;

  /// Every pick counted.
  int get votes =>
      [for (final a in config.items) count(a.id)].fold(0, (a, b) => a + b);

  /// People who voted.
  int get voters => tally.voters ?? votes;

  bool get isEmpty => voters == 0;

  /// [id]'s share: of people who voted (pick several), else of votes.
  double share(String id) {
    final of = config.type == PollType.several ? voters : votes;
    return of == 0 ? 0 : count(id) / of;
  }

  int percent(String id) => (share(id) * 100).round();

  /// Rating: the average to one decimal, or null with no votes.
  double? get average {
    if (config.type != PollType.rating || votes == 0) return null;
    var sum = 0;
    for (final a in config.items) {
      sum += int.parse(a.id) * count(a.id);
    }
    return (sum / votes * 10).round() / 10;
  }

  /// "1 vote", "212 votes" — people, so picking several counts once.
  String get votesLabel => voters == 1 ? '1 vote' : '$voters votes';
}

String? _pollConfigError(Map<String, dynamic> c) =>
    PollConfig.fromJson(c).error;

List<String> _pollChoices(Map<String, dynamic> c) => [
  for (final a in PollConfig.fromJson(c).items) a.id,
];

int _pollMaxPicks(Map<String, dynamic> c) => PollConfig.fromJson(c).pickLimit;

String _pollLabel(Map<String, dynamic> c, String id) =>
    PollConfig.fromJson(c).labelOf(id);

/// Mirrors pollServerState: a reset starts a new round and drops the timer;
/// start sets `closesAt` from the timer length; cancel drops it.
Map<String, dynamic> _pollOps(
  Map<String, dynamic> state,
  Map<String, dynamic> config,
  ElementOps ops,
  int now,
) {
  final next = {...state};
  if (ops.reset) {
    next['round'] = ((state['round'] as num?)?.toInt() ?? 0) + 1;
    next.remove('closesAt');
  }
  if (ops.timer == false) next.remove('closesAt');
  final sec = ops.timerSec ?? (config['timerSec'] as num?)?.toInt();
  if (ops.timer == true && sec != null) next['closesAt'] = now + sec * 1000;
  return next;
}
