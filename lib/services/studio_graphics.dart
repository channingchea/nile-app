import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'brand_kit.dart';

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
  slate('slate', 'Full-screen slate'),

  /// A link as a QR code in a corner; viewers on a phone can tap it.
  qr('qr', 'QR code'),

  /// This event's accepted sponsor's logo (or a "Sponsored by" badge). Built
  /// in from the sponsorship — never saved in a library. The server fills in
  /// the image and name from the campaign.
  sponsor('sponsor', 'Sponsor logo'),

  /// A viewer's chat message put on screen from the Studio chat ("Show on
  /// screen"). Push-only — never saved in a library.
  chat('chat', 'Chat message');

  const GraphicKind(this.wire, this.label);
  final String wire;
  final String label;

  static GraphicKind? fromWire(Object? s) =>
      GraphicKind.values.where((k) => k.wire == s).firstOrNull;

  /// Kinds a library can hold (the `studio_graphic_kind` enum).
  static const library = [lowerThird, logo, banner, slate, qr];
}

/// Auto-hide choices offered in the library editor and the Cameras menu.
/// 0 = stays up until turned off.
const autoHideChoices = [0, 5, 8, 10, 15, 30];

String autoHideLabel(int seconds) => seconds <= 0 ? 'Off' : '$seconds s';

/// How a countdown slate counts: a fixed length, to a time of day, or to the
/// show's scheduled start.
enum CountdownMode {
  duration('duration'),
  clock('clock'),
  showStart('showStart');

  const CountdownMode(this.wire);
  final String wire;

  static CountdownMode? fromWire(Object? s) =>
      CountdownMode.values.where((k) => k.wire == s).firstOrNull;
}

/// Where a QR code's link comes from. `event` and `profile` are resolved when
/// pushed, so one saved QR works for every show.
const qrSources = {
  'custom': 'Any link',
  'event': 'This show’s page',
  'profile': 'Your profile',
};

final _https = RegExp(r'^https://[^\s/$.?#][^\s]*$', caseSensitive: false);

/// A link a QR code may carry: https only, 500 characters at most.
bool isQrUrl(Object? url) =>
    url is String && url.length <= 500 && _https.hasMatch(url);

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

  /// The show's sponsor as a built-in item ("Sponsor: Acme"). [logoUrl] is
  /// only for the Studio's own preview — the server looks the logo up itself.
  factory StudioGraphic.sponsor({
    required String campaignId,
    required String sponsorName,
    String? logoUrl,
    String corner = 'tr',
    String size = 'm',
  }) => StudioGraphic(
    id: 'sponsor:$campaignId',
    kind: GraphicKind.sponsor,
    name: 'Sponsor: $sponsorName',
    payload: {
      'campaignId': campaignId,
      'sponsorName': sponsorName,
      'logoUrl': ?logoUrl,
      'corner': corner,
      'size': size,
    },
  );

  bool get isPreset => id.startsWith('preset:');
  bool get isBuiltIn => isPreset || kind == GraphicKind.sponsor;

  /// Drawn in Nile's own style even when a brand kit is set.
  bool get nileStyle => payload['nileStyle'] == true;

  /// The graphic's saved auto-hide, in seconds; 0 = stays up.
  int get autoHideSeconds => (payload['autoHideSeconds'] as num?)?.toInt() ?? 0;

  StudioGraphic copyWith({
    String? name,
    Map<String, dynamic>? payload,
    int? sort,
  }) => StudioGraphic(
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

    if (p['nileStyle'] != null && p['nileStyle'] is! bool) {
      return 'Style choice is malformed.';
    }
    final hide = p['autoHideSeconds'];
    if (hide != null && (hide is! num || hide < 1 || hide > 3600)) {
      return 'Auto-hide is 1 second to an hour.';
    }

    switch (kind) {
      case GraphicKind.chat:
        return 'Chat messages are put on screen from the chat.';
      case GraphicKind.sponsor:
        return 'The sponsor logo comes from the show’s sponsorship.';
      case GraphicKind.qr:
        final source = p['source'] ?? 'custom';
        if (!qrSources.containsKey(source)) {
          return 'Pick where the link comes from.';
        }
        if (source == 'custom' && !isQrUrl(p['url'])) {
          return 'Enter a link starting with https://';
        }
        if (!logoCorners.contains(p['corner'])) return 'Pick a corner.';
        if (p['size'] != null && !['s', 'm', 'l'].contains(p['size'])) {
          return 'Pick a size.';
        }
        return text('caption', 0, 40, 'Caption');
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
        if (p['countdown'] case final Object cd) {
          final err = countdownError(cd);
          if (err != null) return err;
        }
        return text('title', 1, 60, 'Title') ??
            text('subtitle', 0, 120, 'Subtitle');
    }
  }
}

/// Why a slate's `countdown` value is unusable, or null when it is fine.
///   {mode: duration, seconds: 1-86400} · {mode: clock, at: "HH:MM"} ·
///   {mode: showStart}
String? countdownError(Object? cd) {
  if (cd is! Map) return 'Countdown is malformed.';
  switch (CountdownMode.fromWire(cd['mode'])) {
    case CountdownMode.duration:
      final s = cd['seconds'];
      return s is num && s >= 1 && s <= 86400
          ? null
          : 'Countdown is 1 second to 24 hours.';
    case CountdownMode.clock:
      return parseClock(cd['at']) == null ? 'Pick a time of day.' : null;
    case CountdownMode.showStart:
      return null;
    case null:
      return 'Pick how the countdown counts.';
  }
}

/// "HH:MM" (24 h) → (hour, minute), or null.
(int, int)? parseClock(Object? at) {
  if (at is! String) return null;
  final m = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$').firstMatch(at);
  return m == null ? null : (int.parse(m[1]!), int.parse(m[2]!));
}

/// When a countdown described by [payload] ends, given the moment it is
/// pushed. A clock time is the next time the host's own clock shows it; the
/// show start falls back to "no countdown" when the show has no start time.
/// Returns (endsAtMs, showsClock) or null for a slate without a countdown.
(int, bool)? countdownEnd(
  Map<String, dynamic> payload, {
  required DateTime now,
  DateTime? showStartAt,
}) {
  final cd = payload['countdown'];
  if (cd is Map) {
    switch (CountdownMode.fromWire(cd['mode'])) {
      case CountdownMode.duration:
        final s = (cd['seconds'] as num?)?.toInt();
        return s == null
            ? null
            : (now.add(Duration(seconds: s)).millisecondsSinceEpoch, false);
      case CountdownMode.clock:
        final hm = parseClock(cd['at']);
        if (hm == null) return null;
        final local = now.toLocal();
        var at = DateTime(local.year, local.month, local.day, hm.$1, hm.$2);
        if (!at.isAfter(local)) at = at.add(const Duration(days: 1));
        return (at.millisecondsSinceEpoch, true);
      case CountdownMode.showStart:
        return showStartAt == null
            ? null
            : (showStartAt.millisecondsSinceEpoch, true);
      case null:
        return null;
    }
  }
  final legacy = (payload['countdownSeconds'] as num?)?.toInt();
  return legacy == null
      ? null
      : (now.add(Duration(seconds: legacy)).millisecondsSinceEpoch, false);
}

/// Built-in graphics every host has without saving anything: the four slates
/// from the plan. Pushed exactly like library items.
abstract final class StudioGraphicPresets {
  static const all = [
    StudioGraphic(
      id: 'preset:starting',
      kind: GraphicKind.slate,
      name: 'Starting soon',
      payload: {
        'title': 'Starting soon',
        'subtitle': 'Grab a seat — we’re about to begin.',
      },
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
      payload: {
        'title': 'Starting in',
        'countdown': {'mode': 'duration', 'seconds': 300},
      },
    ),
    StudioGraphic(
      id: 'preset:until-start',
      kind: GraphicKind.slate,
      name: 'Countdown to show start',
      payload: {
        'title': 'Starting in',
        'countdown': {'mode': 'showStart'},
      },
    ),
  ];
}

/// A graphic as pushed live: everything needed to draw it, nothing that needs
/// a lookup. Image paths are already public URLs; a countdown already has its
/// end time; an auto-hide already has the moment it comes down.
@immutable
class LiveGraphic {
  const LiveGraphic({
    required this.id,
    required this.kind,
    this.title,
    this.subtitle,
    this.text,
    this.imageUrl,
    this.avatarUrl,
    this.corner,
    this.size,
    this.scrolling = false,
    this.endsAt,
    this.showsClock = false,
    this.hideAt,
    this.except = const [],
    this.url,
    this.caption,
    this.campaignId,
    this.nileStyle = false,
    this.brand,
  });

  /// [StudioGraphic.id] it came from — what the panel keys on. Chat graphics
  /// use `chat:<message id>`.
  final String id;
  final GraphicKind kind;

  /// Lower third / slate title; a chat graphic's username.
  final String? title;
  final String? subtitle;

  /// Banner text; a chat graphic's message.
  final String? text;
  final String? imageUrl;

  /// Chat graphics: the sender's avatar.
  final String? avatarUrl;
  final String? corner;
  final String? size;
  final bool scrolling;

  /// Countdown slates: epoch ms when the countdown reaches zero.
  final int? endsAt;

  /// The countdown runs to a time of day (or the show's start): the slate
  /// also says the time, in each viewer's own time zone.
  final bool showsClock;

  /// Epoch ms when it comes down by itself. Null = stays up.
  final int? hideAt;

  /// Graphics on every camera: slots it has been taken off ("All but Cam 2").
  final List<String> except;

  /// QR codes: the link.
  final String? url;

  /// QR codes: the short line under the code.
  final String? caption;

  /// Sponsor logos: the campaign (the server fills [imageUrl] and [title]).
  final String? campaignId;

  /// Opted out of the brand kit.
  final bool nileStyle;

  /// The brand kit to draw with — attached by [GraphicsState.forSlot], never
  /// sent. Null = Nile style.
  final BrandStyle? brand;

  /// Graphics of the same cap key can't be on screen together: one lower
  /// third, one logo per corner, one banner, one slate, one chat message.
  /// A sponsor logo is a logo; a QR code has its own spot in each corner.
  String get capKey => switch (kind) {
    GraphicKind.logo || GraphicKind.sponsor => 'logo:$corner',
    GraphicKind.qr => 'qr:$corner',
    _ => kind.wire,
  };

  /// Viewers on a phone can tap it.
  bool get tappable => kind == GraphicKind.qr && url != null;

  /// This graphic as drawn with [style] (null = Nile style). Graphics that
  /// opted out of the kit ignore it.
  LiveGraphic withBrand(BrandStyle? style) => _copy(
    brand: nileStyle ? null : style,
    clearBrand: nileStyle || style == null,
  );

  bool expiredAt(int nowMs) => hideAt != null && hideAt! <= nowMs;

  /// Snapshot a library item for pushing. [publicUrl] turns a storage path
  /// into a URL; [now] stamps a countdown's end and the auto-hide.
  ///
  /// [autoHideSeconds] overrides the graphic's saved auto-hide (0 = off);
  /// null keeps the saved one. [showStartAt] feeds "count down to show start".
  /// [resolveLink] turns a QR source (`event`, `profile`) into its link.
  factory LiveGraphic.snapshot(
    StudioGraphic g, {
    required String Function(String path) publicUrl,
    required DateTime now,
    int? autoHideSeconds,
    DateTime? showStartAt,
    String? Function(String source)? resolveLink,
  }) {
    final p = g.payload;
    final path = p['imagePath'] as String?;
    final countdown = g.kind == GraphicKind.slate
        ? countdownEnd(p, now: now, showStartAt: showStartAt)
        : null;
    final hide = autoHideSeconds ?? g.autoHideSeconds;
    return LiveGraphic(
      id: g.id,
      kind: g.kind,
      title:
          (g.kind == GraphicKind.sponsor ? p['sponsorName'] : p['title'])
              as String?,
      subtitle: p['subtitle'] as String?,
      text: p['text'] as String?,
      imageUrl: g.kind == GraphicKind.sponsor
          ? p['logoUrl'] as String?
          : path == null || path.isEmpty
          ? null
          : publicUrl(path),
      corner: p['corner'] as String?,
      size: p['size'] as String?,
      scrolling: p['scrolling'] == true,
      endsAt: countdown?.$1,
      showsClock: countdown?.$2 ?? false,
      hideAt: hide > 0
          ? now.add(Duration(seconds: hide)).millisecondsSinceEpoch
          : null,
      url: g.kind == GraphicKind.qr
          ? (p['source'] ?? 'custom') == 'custom'
                ? p['url'] as String?
                : resolveLink?.call(p['source'] as String)
          : null,
      caption: p['caption'] as String?,
      campaignId: p['campaignId'] as String?,
      nileStyle: g.nileStyle,
    );
  }

  /// A chat message as an on-screen card ("Show on screen"), up for
  /// [seconds] (0 = until taken down).
  factory LiveGraphic.chatMessage({
    required String messageId,
    required String username,
    required String message,
    String? avatarUrl,
    required DateTime now,
    int seconds = 10,
  }) => LiveGraphic(
    id: 'chat:$messageId',
    kind: GraphicKind.chat,
    title: username.length > 40 ? username.substring(0, 40) : username,
    text: message.length > 200 ? '${message.substring(0, 199)}…' : message,
    avatarUrl: avatarUrl,
    hideAt: seconds > 0
        ? now.add(Duration(seconds: seconds)).millisecondsSinceEpoch
        : null,
  );

  LiveGraphic copyWith({
    List<String>? except,
    int? hideAt,
    bool clearHide = false,
  }) => _copy(except: except, hideAt: hideAt, clearHide: clearHide);

  LiveGraphic _copy({
    List<String>? except,
    int? hideAt,
    bool clearHide = false,
    BrandStyle? brand,
    bool clearBrand = false,
  }) => LiveGraphic(
    id: id,
    kind: kind,
    title: title,
    subtitle: subtitle,
    text: text,
    imageUrl: imageUrl,
    avatarUrl: avatarUrl,
    corner: corner,
    size: size,
    scrolling: scrolling,
    endsAt: endsAt,
    showsClock: showsClock,
    hideAt: clearHide ? null : hideAt ?? this.hideAt,
    except: except ?? this.except,
    url: url,
    caption: caption,
    campaignId: campaignId,
    nileStyle: nileStyle,
    brand: clearBrand ? null : brand ?? this.brand,
  );

  static LiveGraphic? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = GraphicKind.fromWire(j['kind']);
    final id = j['id'];
    if (kind == null || id is! String) return null;
    final except = j['except'];
    return LiveGraphic(
      id: id,
      kind: kind,
      title: j['title'] as String?,
      subtitle: j['subtitle'] as String?,
      text: j['text'] as String?,
      imageUrl: j['imageUrl'] as String?,
      avatarUrl: j['avatarUrl'] as String?,
      corner: j['corner'] as String?,
      size: j['size'] as String?,
      scrolling: j['scrolling'] == true,
      endsAt: (j['endsAt'] as num?)?.toInt(),
      showsClock: j['showsClock'] == true,
      hideAt: (j['hideAt'] as num?)?.toInt(),
      except: except is List ? except.whereType<String>().toList() : const [],
      url: j['url'] as String?,
      caption: j['caption'] as String?,
      campaignId: j['campaignId'] as String?,
      nileStyle: j['nileStyle'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.wire,
    'title': ?title,
    'subtitle': ?subtitle,
    'text': ?text,
    'imageUrl': ?imageUrl,
    'avatarUrl': ?avatarUrl,
    'corner': ?corner,
    'size': ?size,
    if (scrolling) 'scrolling': true,
    'endsAt': ?endsAt,
    if (showsClock) 'showsClock': true,
    'hideAt': ?hideAt,
    if (except.isNotEmpty) 'except': except,
    'url': ?url,
    'caption': ?caption,
    'campaignId': ?campaignId,
    if (nileStyle) 'nileStyle': true,
  };

  @override
  bool operator ==(Object other) =>
      other is LiveGraphic &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// Where one graphic is on air: every camera (minus [except]), or just
/// [slots]. What the panel's "Cameras" button summarises and edits.
@immutable
class GraphicTargets {
  const GraphicTargets.all({this.except = const {}})
    : all = true,
      slots = const {};
  const GraphicTargets.only(this.slots) : all = false, except = const {};

  static const none = GraphicTargets.only({});

  final bool all;
  final Set<String> except;
  final Set<String> slots;

  bool get isNone => !all && slots.isEmpty;

  bool includes(String slotId) =>
      all ? !except.contains(slotId) : slots.contains(slotId);

  /// "Off", "All cameras", "All but Cam 2", "Cam 1, Cam 3". [labelOf] names a
  /// slot; [order] lists slots in display order.
  String summary(String Function(String slotId) labelOf, List<String> order) {
    if (all) {
      if (except.isEmpty) return 'All cameras';
      return 'All but ${[for (final s in order)
        if (except.contains(s)) labelOf(s)].join(', ')}';
    }
    if (slots.isEmpty) return 'Off';
    return [
      for (final s in order)
        if (slots.contains(s)) labelOf(s),
    ].join(', ');
  }

  @override
  bool operator ==(Object other) =>
      other is GraphicTargets &&
      other.all == all &&
      setEquals(other.except, except) &&
      setEquals(other.slots, slots);

  @override
  int get hashCode => Object.hash(
    all,
    Object.hashAllUnordered(except),
    Object.hashAllUnordered(slots),
  );
}

/// What is on air: graphics for every camera, plus per-slot extras.
///
/// Lives in the LiveKit room metadata under `graphics`, written only by the
/// `set-graphics` action. Each viewer combines it for the angle they watch
/// ([forSlot]), so graphics follow the camera a viewer picks.
@immutable
class GraphicsState {
  const GraphicsState({
    this.all = const [],
    this.bySlot = const {},
    this.brand,
  });

  static const empty = GraphicsState();

  final List<LiveGraphic> all;
  final Map<String, List<LiveGraphic>> bySlot;

  /// The host's brand kit, drawn on every graphic that didn't opt out. Null =
  /// Nile style. The Studio attaches it to every push.
  final BrandStyle? brand;

  GraphicsState withBrand(BrandStyle? style) =>
      GraphicsState(all: all, bySlot: bySlot, brand: style);

  bool get isEmpty => all.isEmpty && bySlot.values.every((l) => l.isEmpty);

  Iterable<LiveGraphic> get _everything => [
    ...all,
    for (final l in bySlot.values) ...l,
  ];

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
    return GraphicsState(
      all: list(j['all']),
      bySlot: bySlot,
      brand: BrandStyle.fromJson(j['brand']),
    );
  }

  Map<String, dynamic> toJson() => {
    'all': [for (final g in all) g.toJson()],
    'bySlot': {
      for (final e in bySlot.entries)
        if (e.value.isNotEmpty) e.key: [for (final g in e.value) g.toJson()],
    },
    if (brand != null) 'brand': brand!.toJson(),
  };

  /// What a viewer watching [slotId] sees: everything pushed to all cameras
  /// (except the ones taken off this camera), with a per-slot graphic
  /// replacing an "all" one of the same cap key (the camera-specific lower
  /// third wins over the show-wide one). Anything past its auto-hide is gone
  /// already, even before the Studio takes it out of the metadata.
  List<LiveGraphic> forSlot(String? slotId, {int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final own = [
      for (final g
          in slotId == null
              ? const <LiveGraphic>[]
              : bySlot[slotId] ?? const <LiveGraphic>[])
        if (!g.expiredAt(now)) g,
    ];
    final taken = {for (final g in own) g.capKey};
    return [
      for (final g in [
        ...all.where(
          (g) =>
              !taken.contains(g.capKey) &&
              !g.expiredAt(now) &&
              !(slotId != null && g.except.contains(slotId)),
        ),
        ...own,
      ])
        g.withBrand(brand),
    ];
  }

  /// The list a target holds: [slotId] null = all cameras.
  List<LiveGraphic> targetList(String? slotId) =>
      slotId == null ? all : bySlot[slotId] ?? const [];

  bool isOn(String? slotId, String graphicId) =>
      targetList(slotId).any((g) => g.id == graphicId);

  /// On any camera at all.
  bool onAnywhere(String graphicId) =>
      _everything.any((g) => g.id == graphicId);

  /// Where [graphicId] is on air right now.
  GraphicTargets targetsOf(String graphicId) {
    final inAll = all.where((g) => g.id == graphicId).firstOrNull;
    if (inAll != null) return GraphicTargets.all(except: inAll.except.toSet());
    return GraphicTargets.only({
      for (final e in bySlot.entries)
        if (e.value.any((g) => g.id == graphicId)) e.key,
    });
  }

  /// Turn [g] on for a target, replacing whatever held its cap key there.
  GraphicsState withOn(String? slotId, LiveGraphic g) => _withTarget(slotId, [
    ...targetList(slotId).where((x) => x.capKey != g.capKey && x.id != g.id),
    g,
  ]);

  GraphicsState withOff(String? slotId, String graphicId) => _withTarget(
    slotId,
    targetList(slotId).where((x) => x.id != graphicId).toList(),
  );

  GraphicsState cleared(String? slotId) => _withTarget(slotId, const []);

  /// Put [g] exactly on [t] — wherever it was before no longer counts.
  GraphicsState withTargets(LiveGraphic g, GraphicTargets t) {
    var s = withoutEverywhere(g.id);
    if (t.all) {
      return s.withOn(null, g.copyWith(except: t.except.toList()..sort()));
    }
    for (final slot in t.slots) {
      s = s.withOn(slot, g.copyWith(except: const []));
    }
    return s;
  }

  /// Take [graphicId] off one camera only. An all-cameras graphic stays on
  /// every other camera ("All but Cam 2").
  GraphicsState withoutOnSlot(String graphicId, String slotId) {
    var s = withOff(slotId, graphicId);
    final g = s.all.where((x) => x.id == graphicId).firstOrNull;
    if (g != null && !g.except.contains(slotId)) {
      s = s._withTarget(null, [
        for (final x in s.all)
          x.id == graphicId
              ? x.copyWith(except: [...x.except, slotId]..sort())
              : x,
      ]);
    }
    return s;
  }

  GraphicsState withoutEverywhere(String graphicId) {
    final next = <String, List<LiveGraphic>>{};
    for (final e in bySlot.entries) {
      final l = e.value.where((g) => g.id != graphicId).toList();
      if (l.isNotEmpty) next[e.key] = l;
    }
    return GraphicsState(
      all: all.where((g) => g.id != graphicId).toList(),
      bySlot: next,
      brand: brand,
    );
  }

  /// Hotkey: off everywhere if it is on anywhere, else on [last].
  GraphicsState toggled(LiveGraphic g, GraphicTargets last) =>
      onAnywhere(g.id) ? withoutEverywhere(g.id) : withTargets(g, last);

  /// Everything still up at [nowMs].
  GraphicsState withoutExpired(int nowMs) {
    final next = <String, List<LiveGraphic>>{};
    for (final e in bySlot.entries) {
      final l = e.value.where((g) => !g.expiredAt(nowMs)).toList();
      if (l.isNotEmpty) next[e.key] = l;
    }
    return GraphicsState(
      all: all.where((g) => !g.expiredAt(nowMs)).toList(),
      bySlot: next,
      brand: brand,
    );
  }

  /// The next auto-hide due, epoch ms — when the Studio should tidy up.
  int? get nextHideAt {
    int? next;
    for (final g in _everything) {
      final h = g.hideAt;
      if (h != null && (next == null || h < next)) next = h;
    }
    return next;
  }

  GraphicsState _withTarget(String? slotId, List<LiveGraphic> list) {
    if (slotId == null) {
      return GraphicsState(all: list, bySlot: bySlot, brand: brand);
    }
    final next = {...bySlot};
    if (list.isEmpty) {
      next.remove(slotId);
    } else {
      next[slotId] = list;
    }
    return GraphicsState(all: all, bySlot: next, brand: brand);
  }

  @override
  bool operator ==(Object other) =>
      other is GraphicsState &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// A graphic waiting in the Studio for "Take" (cue before air). Lives only in
/// the Studio — nothing is sent until [take]. [build] snapshots the graphic at
/// the moment it is called, so a countdown or auto-hide starts at Take, not
/// when it was cued.
@immutable
class GraphicCue {
  const GraphicCue({
    required this.id,
    required this.name,
    required this.targets,
    required this.build,
  });

  /// The graphic's id ([StudioGraphic.id], `chat:<id>`…).
  final String id;
  final String name;
  final GraphicTargets targets;
  final LiveGraphic Function(DateTime now) build;

  /// Cue a library item, preset or the sponsor onto [targets].
  factory GraphicCue.of(
    StudioGraphic g, {
    required GraphicTargets targets,
    required String Function(String path) publicUrl,
    int? autoHideSeconds,
    DateTime? showStartAt,
    String? Function(String source)? resolveLink,
  }) => GraphicCue(
    id: g.id,
    name: g.name,
    targets: targets,
    build: (now) => LiveGraphic.snapshot(
      g,
      publicUrl: publicUrl,
      now: now,
      autoHideSeconds: autoHideSeconds,
      showStartAt: showStartAt,
      resolveLink: resolveLink,
    ),
  );

  GraphicCue withTargets(GraphicTargets t) =>
      GraphicCue(id: id, name: name, targets: t, build: build);

  /// The state that goes on air when it is taken at [now].
  GraphicsState take(GraphicsState current, DateTime now) =>
      current.withTargets(build(now), targets);

  /// What the Studio's monitor shows while it is cued: [take] with nothing
  /// counting down to its hide, so the preview stays up.
  GraphicsState preview(GraphicsState current, DateTime now) =>
      current.withTargets(build(now).copyWith(clearHide: true), targets);
}

/// Everything waiting for Take — several graphics can be cued at once and go
/// on air together. Cueing a graphic again replaces its entry; cueing one that
/// would take another's place on screen (same spot, overlapping cameras)
/// drops the older one, so the monitor never previews what Take won't send.
@immutable
class CueSet {
  const CueSet([this.items = const []]);

  static const empty = CueSet();

  /// In the order they were cued; Take applies them in this order.
  final List<GraphicCue> items;

  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;
  int get length => items.length;

  GraphicCue? byId(String id) => items.where((c) => c.id == id).firstOrNull;
  bool contains(String id) => byId(id) != null;

  CueSet adding(GraphicCue cue) {
    final now = DateTime.now();
    final key = cue.build(now).capKey;
    return CueSet([
      for (final c in items)
        if (c.id != cue.id &&
            !(c.build(now).capKey == key && _overlap(c.targets, cue.targets)))
          c,
      cue,
    ]);
  }

  CueSet without(String id) => CueSet([
    for (final c in items)
      if (c.id != id) c,
  ]);

  /// Cued → un-cued; otherwise cue it.
  CueSet toggled(GraphicCue cue) =>
      contains(cue.id) ? without(cue.id) : adding(cue);

  /// Every cue on air at [now].
  GraphicsState take(GraphicsState current, DateTime now) =>
      items.fold(current, (s, c) => c.take(s, now));

  /// What the monitor shows: on air plus every cue, none of them hiding.
  GraphicsState preview(GraphicsState current, DateTime now) =>
      items.fold(current, (s, c) => c.preview(s, now));

  /// Some cue lands on [slotId] (null = a screen share: all-camera cues).
  bool lands(String? slotId) => items.any(
    (c) => slotId == null ? c.targets.all : c.targets.includes(slotId),
  );

  /// "Be right back" or "3 graphics".
  String get label => length == 1 ? items.single.name : '$length graphics';

  /// For the cue strip: one cue → its name and cameras; several → "3
  /// graphics" and their names.
  ({String name, String targets}) describe(
    String Function(String slotId) labelOf,
    List<String> order,
  ) => length == 1
      ? (name: label, targets: items.single.targets.summary(labelOf, order))
      : (name: label, targets: items.map((c) => c.name).join(', '));

  static bool _overlap(GraphicTargets a, GraphicTargets b) {
    if (a.all && b.all) return true;
    if (a.all) return b.slots.any((s) => !a.except.contains(s));
    if (b.all) return a.slots.any((s) => !b.except.contains(s));
    return a.slots.any(b.slots.contains);
  }

  @override
  bool operator ==(Object other) =>
      other is CueSet && listEquals(other.items, items);

  @override
  int get hashCode => Object.hashAll(items);
}
