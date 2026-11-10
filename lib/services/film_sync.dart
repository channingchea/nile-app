import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Premiere synced playback (docs/plans/studio-modes.md, phases 7-8): the
/// film clock in room metadata `film`, written by livekit `film-control`.
/// Every device computes where the film is from {state, pos, at} and the
/// shared server clock. Mirrors supabase/functions/_shared/film.ts.

enum FilmPhase { pre, playing, paused, intermission, hold, ended }

enum PipCorner {
  off,
  tl,
  tr,
  bl,
  br;

  static PipCorner fromWire(Object? v) =>
      values.firstWhere((c) => c.name == v, orElse: () => off);

  String get label => switch (this) {
    off => 'Off',
    tl => 'Top left',
    tr => 'Top right',
    bl => 'Bottom left',
    br => 'Bottom right',
  };
}

@immutable
class FilmState {
  const FilmState({
    this.phase = FilmPhase.pre,
    this.pos = 0,
    this.at = 0,
    this.dur = 0,
    this.until,
    this.message,
    this.commentary = false,
    this.duck = defaultDuck,
    this.pip = PipCorner.off,
    this.startedAt,
    this.endedAt,
  });

  static const none = FilmState();

  final FilmPhase phase;

  /// Film position (ms) at server time [at].
  final int pos;
  final int at;

  /// Film length, ms.
  final int dur;

  /// Intermission end (server ms).
  final int? until;
  final String? message;
  final bool commentary;

  /// Film volume under commentary, percent (room metadata `duck`).
  final int duck;
  static const defaultDuck = 30;
  final PipCorner pip;
  final int? startedAt;
  final int? endedAt;

  static FilmState? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final phase = FilmPhase.values.where((p) => p.name == raw['state']);
    int? n(Object? v) => v is num && v.isFinite ? v.round() : null;
    final pos = n(raw['pos']), at = n(raw['at']), dur = n(raw['dur']);
    if (phase.isEmpty || pos == null || at == null || dur == null) return null;
    return FilmState(
      phase: phase.first,
      pos: pos,
      at: at,
      dur: dur,
      until: n(raw['until']),
      message: raw['msg'] is String ? raw['msg'] as String : null,
      commentary: raw['commentary'] == true,
      duck: n(raw['duck'])?.clamp(0, 100) ?? defaultDuck,
      pip: PipCorner.fromWire(raw['pip']),
      startedAt: n(raw['startedAt']),
      endedAt: n(raw['endedAt']),
    );
  }

  /// Room metadata `film`; [none] when absent.
  static FilmState fromRoomMetadata(String? raw) {
    if (raw == null || raw.isEmpty) return none;
    try {
      final m = jsonDecode(raw);
      return m is Map ? fromJson(m['film']) ?? none : none;
    } catch (_) {
      return none;
    }
  }

  /// Where the film is at server time [now]: a playing film past its length
  /// has ended (post-show starts by itself), and an intermission past its
  /// end time is playing again.
  FilmNow nowAt(int now) {
    var p = phase;
    var at = pos;
    if (p == FilmPhase.intermission && until != null && now >= until!) {
      p = FilmPhase.playing;
      at = pos + (now - until!);
    } else if (p == FilmPhase.playing) {
      at = pos + (now - this.at).clamp(0, 1 << 52);
    }
    if (p == FilmPhase.playing && dur > 0 && at >= dur) p = FilmPhase.ended;
    return FilmNow(p, at.clamp(0, dur < 0 ? 0 : dur));
  }

  /// When [nowAt] next changes phase by itself (end of an intermission or of
  /// the film), in ms from [now]; null when nothing is due.
  int? nextChangeIn(int now) {
    final n = nowAt(now);
    if (n.phase == FilmPhase.intermission && until != null) return until! - now;
    if (n.phase == FilmPhase.playing && dur > 0) return dur - n.pos;
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is FilmState &&
      other.phase == phase &&
      other.pos == pos &&
      other.at == at &&
      other.dur == dur &&
      other.until == until &&
      other.message == message &&
      other.commentary == commentary &&
      other.duck == duck &&
      other.pip == pip &&
      other.startedAt == startedAt &&
      other.endedAt == endedAt;

  @override
  int get hashCode => Object.hash(
    phase,
    pos,
    at,
    dur,
    until,
    message,
    commentary,
    duck,
    pip,
    startedAt,
    endedAt,
  );
}

@immutable
class FilmNow {
  const FilmNow(this.phase, this.pos);
  final FilmPhase phase;
  final int pos;

  /// The film stage is up: between Play and the end.
  bool get showingFilm =>
      phase == FilmPhase.playing ||
      phase == FilmPhase.paused ||
      phase == FilmPhase.intermission ||
      phase == FilmPhase.hold;

  bool get moving => phase == FilmPhase.playing;
}

/// Run of show, as viewers see it.
enum ShowSegment { preShow, film, postShow }

ShowSegment segmentOf(FilmState f, int now) {
  final n = f.nowAt(now);
  if (n.showingFilm) return ShowSegment.film;
  return n.phase == FilmPhase.ended
      ? ShowSegment.postShow
      : ShowSegment.preShow;
}

/// What the player should do about being [driftMs] off the shared clock
/// (positive = ahead). Small drift is left alone, medium drift is eased out
/// with a 0.95-1.05x speed change, anything larger seeks.
@immutable
class SyncStep {
  const SyncStep({this.rate = 1.0, this.seekTo});
  final double rate;
  final int? seekTo;

  @override
  bool operator ==(Object other) =>
      other is SyncStep && other.rate == rate && other.seekTo == seekTo;
  @override
  int get hashCode => Object.hash(rate, seekTo);
  @override
  String toString() => 'SyncStep(rate: $rate, seekTo: $seekTo)';
}

const kDriftIgnoreMs = 300;
const kDriftSeekMs = 1500;

SyncStep syncStep({required int playerMs, required int targetMs}) {
  final drift = playerMs - targetMs;
  final a = drift.abs();
  if (a < kDriftIgnoreMs) return const SyncStep();
  if (a > kDriftSeekMs) return SyncStep(seekTo: targetMs);
  return SyncStep(rate: drift > 0 ? 0.95 : 1.05);
}

/// Film volume on viewer devices: ducked to [duck]% (30 unless the host
/// changed it) under the host's commentary.
double filmVolume({
  required bool commentary,
  required bool muted,
  int duck = FilmState.defaultDuck,
}) => muted ? 0 : (commentary ? duck.clamp(0, 100) / 100 : 1.0);

/// Intermission countdown "4:05".
String formatCountdown(int ms) {
  final s = (ms / 1000).ceil().clamp(0, 1 << 31);
  final m = s ~/ 60;
  return '$m:${(s % 60).toString().padLeft(2, '0')}';
}

/// The transport rules, run locally (Studio Setup's rehearsal). Mirrors
/// applyFilmControl in supabase/functions/_shared/film.ts, minus the
/// live/ready checks the rehearsal doesn't need. Returns [f] unchanged for a
/// press that makes no sense right now.
FilmState rehearseFilmControl(
  FilmState f,
  String action,
  int now, {
  int? positionMs,
  int? seconds,
  String? message,
  bool? on,
  String? corner,
  int? percent,
}) {
  final n = f.nowAt(now);
  FilmState with_({
    required FilmPhase phase,
    required int pos,
    int? until,
    String? msg,
    int? startedAt,
    int? endedAt,
    bool keepStart = true,
  }) => FilmState(
    phase: phase,
    pos: pos,
    at: now,
    dur: f.dur,
    until: until,
    message: msg,
    commentary: f.commentary,
    duck: f.duck,
    pip: f.pip,
    startedAt: startedAt ?? (keepStart ? f.startedAt : null),
    endedAt: endedAt,
  );
  switch (action) {
    case 'play' || 'resume':
      if (n.phase == FilmPhase.playing) return f;
      final from = n.phase == FilmPhase.pre || n.phase == FilmPhase.ended
          ? 0
          : n.pos;
      return with_(
        phase: FilmPhase.playing,
        pos: from,
        startedAt: f.startedAt ?? now,
      );
    case 'pause':
      return n.showingFilm ? with_(phase: FilmPhase.paused, pos: n.pos) : f;
    case 'seek':
      if (!n.showingFilm || positionMs == null) return f;
      return with_(
        phase: n.phase == FilmPhase.intermission ? FilmPhase.paused : n.phase,
        pos: positionMs.clamp(0, f.dur),
        msg: n.phase == FilmPhase.hold ? f.message : null,
      );
    case 'intermission':
      if (!n.showingFilm || seconds == null) return f;
      return with_(
        phase: FilmPhase.intermission,
        pos: n.pos,
        until: now + seconds * 1000,
      );
    case 'hold':
      if (!n.showingFilm) return f;
      final m = message?.trim() ?? '';
      return with_(
        phase: FilmPhase.hold,
        pos: n.pos,
        msg: m.isEmpty ? null : m,
      );
    case 'end':
      if (n.phase == FilmPhase.pre) return f;
      return with_(
        phase: FilmPhase.ended,
        pos: f.dur,
        endedAt: f.endedAt ?? now,
      );
    case 'reset':
      return with_(phase: FilmPhase.pre, pos: 0, keepStart: false);
    case 'commentary':
      return on == null ? f : _copy(f, commentary: on);
    case 'duck':
      return percent == null ? f : _copy(f, duck: percent.clamp(0, 100));
    case 'pip':
      return corner == null ? f : _copy(f, pip: PipCorner.fromWire(corner));
  }
  return f;
}

FilmState _copy(FilmState f, {bool? commentary, int? duck, PipCorner? pip}) =>
    FilmState(
      phase: f.phase,
      pos: f.pos,
      at: f.at,
      dur: f.dur,
      until: f.until,
      message: f.message,
      commentary: commentary ?? f.commentary,
      duck: duck ?? f.duck,
      pip: pip ?? f.pip,
      startedAt: f.startedAt,
      endedAt: f.endedAt,
    );
