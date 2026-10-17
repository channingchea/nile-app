import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:nile_realsync/nile_realsync.dart';

import 'livekit_service.dart';
import 'studio_roles.dart';
import 'supabase_client.dart';

// RealSync (Studio master host, phase 7): keep the camera a viewer is watching
// in step with the show audio for the whole show, not just at subscribe time.
//
//   7b  Every publisher measures its clock against the server and puts the
//       offset in its metadata (`clockOffsetMs`).
//   7c  Each viewer reads `estimatedPlayoutTimestamp` for the watched camera and
//       the master audio. Both are in the SENDER's clock, so subtracting each
//       sender's offset puts them on one timeline; the difference is the drift.
//   7d  Whichever stream is ahead is held back via the native jitter-buffer
//       minimum (nile_realsync), ramped in small steps.
//   7e  The Studio shows each camera's lag next to its tile.
//   7f  The native hook self-tests; any failure — or the remote switch being
//       off — leaves the old joinedAt subscribe delay in charge.

/// NTP (1900) → Unix (1970) epoch, in ms. `estimatedPlayoutTimestamp` is NTP.
const ntpToUnixMs = 2208988800000;

// ── 7b. Clock alignment ─────────────────────────────────────────────────────

/// One ping to the server's clock, NTP-style: when it left here, reached the
/// server, left the server, and got back — so the server's own processing
/// time (auth, cold start) doesn't count as network.
@immutable
class ClockSample {
  const ClockSample({
    required this.sentAt,
    required this.serverReceivedAt,
    required this.serverSentAt,
    required this.receivedAt,
  });

  final int sentAt;
  final int serverReceivedAt;
  final int serverSentAt;
  final int receivedAt;

  int get rttMs => (receivedAt - sentAt) - (serverSentAt - serverReceivedAt);

  /// This device's clock minus the server's, assuming a symmetric path.
  int get offsetMs =>
      (((sentAt - serverReceivedAt) + (receivedAt - serverSentAt)) / 2).round();
}

/// The offset from the quickest ping — the one least distorted by queuing.
ClockSample? bestClockSample(Iterable<ClockSample> samples) {
  ClockSample? best;
  for (final s in samples) {
    if (s.rttMs < 0) continue;
    if (best == null || s.rttMs < best.rttMs) best = s;
  }
  return best;
}

/// Publisher side: measures this device's clock against the server's and
/// writes it to its own participant metadata — on connect, every 60 s, and
/// whenever the Studio resyncs.
class ClockReporter {
  ClockReporter({required this.eventId, required this.identity});

  final String eventId;
  final String identity;
  Timer? _timer;
  bool _running = false;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => remeasure());
    remeasure();
  }

  Future<void> remeasure() async {
    if (_running || !await RealSyncConfig.measuring()) return;
    _running = true;
    try {
      final samples = <ClockSample>[];
      for (var i = 0; i < 5; i++) {
        final sent = DateTime.now().millisecondsSinceEpoch;
        final server = await LivekitService.serverClock();
        samples.add(
          ClockSample(
            sentAt: sent,
            serverReceivedAt: server.receivedAt,
            serverSentAt: server.sentAt,
            receivedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
      final best = bestClockSample(samples);
      if (best != null) {
        await LivekitService.reportClock(
          eventId: eventId,
          identity: identity,
          offsetMs: best.offsetMs,
          rttMs: best.rttMs,
        );
      }
    } catch (_) {
      // Best effort — viewers treat a missing offset as zero.
    } finally {
      _running = false;
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

// ── 7c/7d. Measurement + correction ─────────────────────────────────────────

/// The decisions, without any I/O, so they can be tested.
///
/// Drift is (videoPlayout − cameraOffset) − (audioPlayout − audioOffset): how
/// far the picture's content is AHEAD of the sound's. Positive → hold the
/// video back; negative → hold the audio back. Only one of the two is ever
/// delayed. The delay set is a jitter-buffer MINIMUM — if the buffer already
/// sits deeper, nothing changes until the minimum passes it — so corrections
/// are fed back: the next measurement includes whatever actually took effect.
class SyncEngine {
  SyncEngine({
    this.deadBandMs = 40,
    this.capMs = 1500,
    this.stepMs = 50,
    this.window = 5,
    this.settleWindow = 3,
  });

  final int deadBandMs;
  final int capMs;
  final int stepMs;

  /// Readings in the steady-state median.
  final int window;

  /// Readings needed right after a switch, so a new angle converges fast.
  final int settleWindow;

  final List<double> _drifts = [];
  bool _settling = true;

  int videoDelayMs = 0;
  int audioDelayMs = 0;
  int targetVideoMs = 0;
  int targetAudioMs = 0;

  /// The watched camera changed (or a resync): forget old readings. Delays
  /// stay — the new angle starts from what the audio already has.
  void restart() {
    _drifts.clear();
    _settling = true;
    targetVideoMs = 0;
    videoDelayMs = 0;
  }

  /// A full reset — nothing held back.
  void clear() {
    restart();
    audioDelayMs = 0;
    targetAudioMs = 0;
  }

  bool get settling => _settling;

  double? get medianDrift {
    if (_drifts.isEmpty) return null;
    final s = [..._drifts]..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
  }

  /// Add a reading; returns true when it produced new targets.
  bool addDrift(double driftMs) {
    if (!driftMs.isFinite || driftMs.abs() > 10000) return false; // garbage
    _drifts.add(driftMs);
    final need = _settling ? settleWindow : window;
    if (_drifts.length < need) return false;
    final d = medianDrift!;
    _drifts.clear();
    _settling = false;
    if (d.abs() < deadBandMs) return false;
    // What the picture needs relative to the sound, given what is applied.
    final relative = (videoDelayMs - audioDelayMs) + d;
    if (relative >= 0) {
      targetVideoMs = math.min(relative.round(), capMs);
      targetAudioMs = 0;
    } else {
      targetAudioMs = math.min((-relative).round(), capMs);
      targetVideoMs = 0;
    }
    return true;
  }

  /// One ramp step toward the targets. Returns which delays changed.
  ({bool video, bool audio}) step() {
    int toward(int from, int to) =>
        from + (to - from).clamp(-stepMs, stepMs).toInt();
    final v = toward(videoDelayMs, targetVideoMs);
    final a = toward(audioDelayMs, targetAudioMs);
    final changed = (video: v != videoDelayMs, audio: a != audioDelayMs);
    videoDelayMs = v;
    audioDelayMs = a;
    return changed;
  }
}

/// Drift from two playout readings and the senders' clock offsets.
double driftMs({
  required double videoPlayoutMs,
  required int cameraOffsetMs,
  required double audioPlayoutMs,
  required int audioOffsetMs,
}) =>
    (videoPlayoutMs - cameraOffsetMs) - (audioPlayoutMs - audioOffsetMs);

/// `estimatedPlayoutTimestamp` for a receiver's inbound stream, if reported.
Future<double?> estimatedPlayout(Track? track) async {
  final receiver = track?.receiver;
  if (receiver == null) return null;
  try {
    for (final r in await receiver.getStats()) {
      if (r.type != 'inbound-rtp') continue;
      final v = r.values['estimatedPlayoutTimestamp'];
      if (v is num && v > 0) return v.toDouble();
    }
  } catch (_) {}
  return null;
}

int clockOffsetOf(Participant? p) =>
    (parseParticipantMeta(p?.metadata)['clockOffsetMs'] as num?)?.toInt() ?? 0;

/// Viewer side: runs the [SyncEngine] against the watched camera and the
/// master audio. It looks the two up itself on every tick, so an angle switch
/// or a master-audio change is noticed without any wiring in the viewer.
class RealSyncDriver {
  RealSyncDriver({
    required this.room,
    required this.watchedCamera,
    required this.masterAudio,
    SyncEngine? engine,
  }) : engine = engine ?? SyncEngine();

  final Room room;
  final String? Function() watchedCamera;
  final String? Function() masterAudio;
  final SyncEngine engine;

  Timer? _sampler;
  Timer? _ramp;
  String? _camera;
  String? _audio;
  String? _videoReceiverId;
  String? _audioReceiverId;
  DateTime _ignoreUntil = DateTime.now();

  void start() {
    _schedule(const Duration(milliseconds: 1000));
    _ramp = Timer.periodic(const Duration(milliseconds: 50), (_) => _applyStep());
  }

  /// Resync: re-measure from scratch.
  void reset() {
    engine.restart();
    _ignoreUntil = DateTime.now().add(const Duration(seconds: 1));
  }

  void _schedule(Duration d) {
    _sampler?.cancel();
    _sampler = Timer(d, _sample);
  }

  RemoteTrackPublication? _videoPub(RemoteParticipant? p) => p
      ?.videoTrackPublications
      .where((x) => x.source != TrackSource.screenShareVideo && x.subscribed)
      .firstOrNull;

  Future<void> _sample() async {
    final camId = watchedCamera();
    final audioId = masterAudio();
    if (camId != _camera || audioId != _audio) {
      // New angle or new sound source: let the old angle go, start over, and
      // ignore readings until the new stream settles.
      final old = _videoReceiverId;
      if (old != null) unawaited(NileRealSync.setMinimumPlayoutDelay(old, null));
      if (audioId != _audio && _audioReceiverId != null) {
        unawaited(NileRealSync.setMinimumPlayoutDelay(_audioReceiverId!, null));
        engine.clear();
      } else {
        engine.restart();
      }
      _camera = camId;
      _audio = audioId;
      _videoReceiverId = null;
      _audioReceiverId = null;
      _ignoreUntil = DateTime.now().add(const Duration(seconds: 1));
    }

    if (DateTime.now().isAfter(_ignoreUntil) && camId != null && audioId != null) {
      final cam = room.remoteParticipants[camId];
      final aud = room.remoteParticipants[audioId];
      final vTrack = _videoPub(cam)?.track;
      final aTrack = aud?.audioTrackPublications
          .where((x) => x.subscribed)
          .firstOrNull
          ?.track;
      _videoReceiverId = vTrack?.receiver?.receiverId;
      _audioReceiverId = aTrack?.receiver?.receiverId;
      final vp = await estimatedPlayout(vTrack);
      final ap = await estimatedPlayout(aTrack);
      if (vp != null && ap != null) {
        engine.addDrift(
          driftMs(
            videoPlayoutMs: vp,
            cameraOffsetMs: clockOffsetOf(cam),
            audioPlayoutMs: ap,
            audioOffsetMs: clockOffsetOf(aud),
          ),
        );
      }
    }
    // Quick readings while settling (~2 s to converge), then every 2 s.
    _schedule(
      engine.settling
          ? const Duration(milliseconds: 500)
          : const Duration(seconds: 2),
    );
  }

  void _applyStep() {
    final changed = engine.step();
    final v = _videoReceiverId;
    final a = _audioReceiverId;
    if (changed.video && v != null) {
      unawaited(
        NileRealSync.setMinimumPlayoutDelay(
          v,
          engine.videoDelayMs == 0
              ? null
              : Duration(milliseconds: engine.videoDelayMs),
        ),
      );
    }
    if (changed.audio && a != null) {
      unawaited(
        NileRealSync.setMinimumPlayoutDelay(
          a,
          engine.audioDelayMs == 0
              ? null
              : Duration(milliseconds: engine.audioDelayMs),
        ),
      );
    }
  }

  void dispose() {
    _sampler?.cancel();
    _ramp?.cancel();
    for (final id in [_videoReceiverId, _audioReceiverId]) {
      if (id != null) unawaited(NileRealSync.setMinimumPlayoutDelay(id, null));
    }
  }
}

// ── 7e. Studio: each camera's lag ───────────────────────────────────────────

/// Each camera's lag behind the most current one, in ms, from its playout
/// reading and sender clock offset. Cameras without a reading are left out.
Map<String, int> relativeLagMs(Map<String, ({double playout, int offset})> readings) {
  if (readings.isEmpty) return const {};
  // Content time each camera is showing now, on the shared clock.
  final shown = {
    for (final e in readings.entries) e.key: e.value.playout - e.value.offset,
  };
  final newest = shown.values.reduce(math.max);
  return {for (final e in shown.entries) e.key: (newest - e.value).round()};
}

// ── 7f. Switches ─────────────────────────────────────────────────────────────

/// RealSync runs only when the remote switch (`app_config.realsync_enabled`)
/// is on. Correction additionally needs the native hook's self-test to pass.
/// Both are read once per launch.
abstract final class RealSyncConfig {
  static Future<bool>? _flag;

  static Future<bool> _remoteFlag() => _flag ??= () async {
    try {
      final rows = await supabase
          .from('app_config')
          .select('realsync_enabled')
          .eq('id', 1)
          .limit(1);
      return rows.isNotEmpty && rows.first['realsync_enabled'] == true;
    } catch (_) {
      return false;
    }
  }();

  /// Clock offsets and lag readings (no native hook needed).
  static Future<bool> measuring() => _remoteFlag();

  /// The full loop: measuring, plus the native delay hook.
  static Future<bool> correcting() async =>
      await _remoteFlag() && await NileRealSync.unavailableReason() == null;
}
