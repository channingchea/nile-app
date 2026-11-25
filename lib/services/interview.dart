import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Interview mode (docs/plans/studio-modes.md, phases 2-5): guests, the green
/// room and the stage. Mirrors supabase/functions/_shared/interview.ts.
///
/// Who is on stage lives in the LiveKit room metadata (`stage`), written by
/// the livekit `move-guest` / `set-stage` actions. The guest list lives in
/// `event_guests` (0147). Viewers, guests, the Studio and the replay recorder
/// all compose the stage from the same metadata with [stageSlots].

/// Most people on stage at once, the host included.
const int kStageMax = 6;

/// Default "you're on in 5".
const int kStageCountdownSeconds = 5;

/// LiveKit identity of a remote guest.
String guestIdentity(String userId) => 'guest-$userId';

/// The user id inside a guest identity, or null when it isn't one.
String? guestUserIdOf(String identity) =>
    identity.startsWith('guest-') ? identity.substring(6) : null;

/// The Studio's private talkback connection (role `backstage`).
String backstageIdentity(String eventId) => 'backstage-$eventId';

/// Data channel topic for backstage chat (host, crew and guests only).
const String kBackstageTopic = 'backstage';

enum GuestStatus {
  /// Came in by share link; waits until the host lets them in (0149).
  requested('requested', 'Asked to join'),
  invited('invited', 'Invited'),
  greenRoom('green_room', 'In green room'),
  onStage('on_stage', 'On stage'),
  removed('removed', 'Removed');

  const GuestStatus(this.wire, this.label);
  final String wire;
  final String label;

  static GuestStatus fromWire(Object? v) =>
      values.firstWhere((s) => s.wire == v, orElse: () => invited);
}

/// One row of `event_guests`, with the guest's profile.
@immutable
class InterviewGuest {
  const InterviewGuest({
    required this.id,
    required this.userId,
    required this.username,
    required this.status,
    this.displayName,
    this.avatarUrl,
    this.title,
    this.stageSeconds = 0,
  });

  /// Columns + profile join for [fromRow].
  static const select =
      'id, user_id, status, title, stage_seconds, '
      'profiles!event_guests_user_id_fkey(username, display_name, avatar_url)';

  factory InterviewGuest.fromRow(Map<String, dynamic> r) {
    final p = (r['profiles'] as Map?) ?? const {};
    return InterviewGuest(
      id: r['id'] as String,
      userId: r['user_id'] as String,
      username: p['username'] as String? ?? 'guest',
      displayName: p['display_name'] as String?,
      avatarUrl: p['avatar_url'] as String?,
      title: r['title'] as String?,
      status: GuestStatus.fromWire(r['status']),
      stageSeconds: (r['stage_seconds'] as num?)?.toInt() ?? 0,
    );
  }

  final String id;
  final String userId;
  final String username;
  final String? displayName;
  final String? avatarUrl;
  final String? title;
  final GuestStatus status;
  final int stageSeconds;

  String get identity => guestIdentity(userId);
  String get name => (displayName != null && displayName!.isNotEmpty)
      ? displayName!
      : username;

  InterviewGuest copyWith({GuestStatus? status, String? title}) =>
      InterviewGuest(
        id: id,
        userId: userId,
        username: username,
        displayName: displayName,
        avatarUrl: avatarUrl,
        title: title ?? this.title,
        status: status ?? this.status,
        stageSeconds: stageSeconds,
      );
}

/// What a guest's LiveKit token metadata says about them.
@immutable
class GuestMeta {
  const GuestMeta({
    required this.userId,
    required this.name,
    this.username,
    this.avatarUrl,
    this.title,
    this.status = GuestStatus.greenRoom,
  });

  static GuestMeta? fromJson(Map<String, dynamic> m) {
    if (m['role'] != 'guest' || m['userId'] is! String) return null;
    return GuestMeta(
      userId: m['userId'] as String,
      name:
          (m['displayName'] as String?) ??
          (m['username'] as String?) ??
          'Guest',
      username: m['username'] as String?,
      avatarUrl: m['avatarUrl'] as String?,
      title: m['title'] as String?,
      status: GuestStatus.fromWire(m['status']),
    );
  }

  final String userId;
  final String name;
  final String? username;
  final String? avatarUrl;
  final String? title;
  final GuestStatus status;
}

enum StageLayout {
  solo('solo', 'Solo'),
  side('side', 'Side by side'),
  grid('grid', 'Grid'),
  spotlight('spotlight', 'Spotlight');

  const StageLayout(this.wire, this.label);
  final String wire;
  final String label;

  static StageLayout fromWire(Object? v) =>
      values.firstWhere((l) => l.wire == v, orElse: () => grid);
}

@immutable
class StageEntry {
  const StageEntry(this.id, this.at);

  /// LiveKit identity.
  final String id;

  /// Server time (ms) they appear on stage — a countdown after being brought on.
  final int at;

  @override
  bool operator ==(Object other) =>
      other is StageEntry && other.id == id && other.at == at;
  @override
  int get hashCode => Object.hash(id, at);
}

/// The stage, from room metadata `stage`.
@immutable
class StageState {
  const StageState({
    this.entries = const [],
    this.layout = StageLayout.grid,
    this.focus,
    this.content,
  });

  static const empty = StageState();

  factory StageState.fromRoomMetadata(String? raw) {
    try {
      final m = jsonDecode(raw ?? '{}');
      return m is Map && m['stage'] is Map
          ? StageState.fromJson(m['stage'] as Map)
          : empty;
    } catch (_) {
      return empty;
    }
  }

  factory StageState.fromJson(Map m) {
    final entries = <StageEntry>[];
    final ids = m['ids'];
    if (ids is List) {
      for (final e in ids) {
        if (e is Map && e['id'] is String && e['at'] is num) {
          final id = e['id'] as String;
          if (entries.every((x) => x.id != id)) {
            entries.add(StageEntry(id, (e['at'] as num).toInt()));
          }
        }
      }
    }
    final focus = m['focus'];
    return StageState(
      entries: entries.take(kStageMax).toList(),
      layout: StageLayout.fromWire(m['layout']),
      focus: focus is String && entries.any((e) => e.id == focus)
          ? focus
          : null,
      content: m['content'] is String ? m['content'] as String : null,
    );
  }

  /// Everyone on stage, in layout order.
  final List<StageEntry> entries;
  final StageLayout layout;

  /// Who Solo and Spotlight feature. Null = the first person on stage.
  final String? focus;

  /// The extra viewer angle: `<identity>#share` or `el:<id>`. Null = none.
  final String? content;

  List<String> get ids => [for (final e in entries) e.id];
  bool contains(String identity) => entries.any((e) => e.id == identity);
  bool get isFull => entries.length >= kStageMax;

  /// Those whose countdown has run out at [nowMs] (server time).
  List<String> visibleAt(int nowMs) => [
    for (final e in entries)
      if (e.at <= nowMs) e.id,
  ];

  /// Whole seconds until [identity] is on, or null when they already are (or
  /// aren't coming).
  int? countdownFor(String identity, int nowMs) {
    for (final e in entries) {
      if (e.id == identity) {
        return e.at > nowMs ? ((e.at - nowMs) / 1000).ceil() : null;
      }
    }
    return null;
  }

  /// Index of [focus] among [visible], defaulting to 0.
  int focusIndexIn(List<String> visible) {
    final i = focus == null ? -1 : visible.indexOf(focus!);
    return i < 0 ? 0 : i;
  }

  @override
  bool operator ==(Object other) =>
      other is StageState &&
      listEquals(other.entries, entries) &&
      other.layout == layout &&
      other.focus == focus &&
      other.content == content;
  @override
  int get hashCode =>
      Object.hash(Object.hashAll(entries), layout, focus, content);
}

/// Where one person sits in the stage frame: [index] into the list passed to
/// [stageSlots], [rect] in fractions of a 16:9 frame (0-1).
typedef StageSlot = ({int index, Rect rect});

/// Gap between tiles, in fractions of the frame width. Vertical gaps are the
/// same number of pixels on a 16:9 frame.
const double kStageGap = 0.01;

/// The stage layout for [n] people. The same rules run in the viewer, the
/// guest's preview, the Studio monitor and the replay recorder
/// (recorder/recorder.js `stageLayout`), so everyone sees one picture.
///
///  * Solo: only the featured person, full frame.
///  * Side by side: one row, equal columns, full height.
///  * Grid: as square a grid as fits, last row centred.
///  * Spotlight: the featured person on the left three quarters, everyone else
///    stacked down the right.
///
/// Tiles fill their cell (video is cropped to cover), so nothing letterboxes.
List<StageSlot> stageSlots(StageLayout layout, int n, {int focusIndex = 0}) {
  if (n <= 0) return const [];
  final fi = focusIndex.clamp(0, n - 1);
  const g = kStageGap, gy = kStageGap * 16 / 9;
  double r4(double v) => (v * 10000).roundToDouble() / 10000;
  Rect rect(double x, double y, double w, double h) =>
      Rect.fromLTWH(r4(x), r4(y), r4(w), r4(h));

  if (n == 1 || layout == StageLayout.solo) {
    return [(index: fi, rect: rect(0, 0, 1, 1))];
  }
  switch (layout) {
    case StageLayout.side:
      final w = (1 - (n - 1) * g) / n;
      return [
        for (var i = 0; i < n; i++)
          (index: i, rect: rect(i * (w + g), 0, w, 1)),
      ];
    case StageLayout.spotlight:
      const bw = 0.75;
      final others = [
        for (var i = 0; i < n; i++)
          if (i != fi) i,
      ];
      final m = others.length;
      final sh = (1 - (m - 1) * gy) / m;
      return [
        (index: fi, rect: rect(0, 0, bw, 1)),
        for (var j = 0; j < m; j++)
          (index: others[j], rect: rect(bw + g, j * (sh + gy), 1 - bw - g, sh)),
      ];
    case StageLayout.grid:
    case StageLayout.solo:
      final cols = math.sqrt(n).ceil();
      final rows = (n / cols).ceil();
      final cw = (1 - (cols - 1) * g) / cols;
      final ch = (1 - (rows - 1) * gy) / rows;
      return [
        for (var i = 0; i < n; i++)
          () {
            final row = i ~/ cols, col = i % cols;
            final inRow = row == rows - 1 ? n - (rows - 1) * cols : cols;
            final xoff = (1 - (inRow * cw + (inRow - 1) * g)) / 2;
            return (
              index: i,
              rect: rect(xoff + col * (cw + g), row * (ch + gy), cw, ch),
            );
          }(),
      ];
  }
}
