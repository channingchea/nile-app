import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCRtpReceiver;
import 'package:livekit_client/livekit_client.dart';
import 'package:nile_realsync/nile_realsync.dart';

import 'livekit_service.dart';
import 'studio_roles.dart';
import 'supabase_client.dart';

// RealSync (Studio master host, phase 7): keep every camera a viewer has on
// screen and the master audio showing the same moment, for the whole show.
//
//   7b  Every publisher measures its clock against the server, puts the
//       offset in its metadata (`clockOffsetMs`), and stamps every frame it
//       sends with its own wall clock (nile_realsync capture stamps).
//   7c  Each viewer reads the stamps on every camera on screen and the master
//       audio as they arrive. Arrival age + the sender's offset + the jitter
//       buffer's current delay = how old the content playing now is, on one
//       clock.
//   7d  Every stream is held back to the oldest one (at most 1 s) via the
//       native jitter-buffer minimum (nile_realsync), ramped in small steps.
//   7e  The Studio shows each camera's lag next to its tile.
//   7f  The native hook self-tests; any failure — or the remote switch being
//       off — leaves the old joinedAt subscribe delay in charge.

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
/// whenever the Studio resyncs. With [participant], it also stamps every track
/// that participant publishes (retrying until each sender is negotiated).
class ClockReporter {
  ClockReporter({required this.eventId, required this.identity, this.participant});

  final String eventId;
  final String identity;
  final LocalParticipant? participant;
  Timer? _timer;
  bool _running = false;
  EventsListener<ParticipantEvent>? _events;
  final Set<String> _stamped = {};

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 60), (_) {
      remeasure();
      _stampTracks();
    });
    remeasure();
    _events?.dispose();
    _events = participant?.createListener()
      ?..on<LocalTrackPublishedEvent>((_) {
        _stampTracks();
        // Audio codecs settle once negotiation finishes.
        Future.delayed(const Duration(seconds: 3), _stampTracks);
      });
    _stampTracks();
  }

  Future<void> _stampTracks() async {
    final p = participant;
    if (p == null || !await RealSyncConfig.measuring()) return;
    for (final pub in p.trackPublications.values) {
      final track = pub.track;
      final id = track?.sender?.senderId;
      if (id == null || _stamped.contains(id)) continue;
      if (await NileRealSync.stampSender(id, audio: track is LocalAudioTrack)) {
        _stamped.add(id);
      }
    }
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
    _events?.dispose();
    _events = null;
    for (final id in _stamped) {
      unawaited(NileRealSync.forget(id));
    }
    _stamped.clear();
  }
}

// ── 7c/7d. Measurement + correction ─────────────────────────────────────────

/// The decisions, without any I/O, so they can be tested.
///
/// Every stream on a viewer's screen — each visible camera and the master
/// audio — reports how old its content is when it plays ([ContentAgeReader]).
/// All of them are held back to match the oldest, so every angle and the sound
/// show the same moment; but no stream is held more than [capMs]. A stream
/// further behind than that is left where it is (the Studio flags it) instead
/// of delaying everything to match it.
///
/// Delays are jitter-buffer MINIMUMS: each reading already includes whatever
/// actually took effect, and subtracting the applied delay gives the stream's
/// natural age. Streams join and settle on their own; one that stops reporting
/// (a thumbnail scrolled off screen pauses) stops counting after [staleAfter].
class GroupSyncEngine {
  GroupSyncEngine({
    this.deadBandMs = 40,
    this.capMs = realSyncCapMs,
    this.stepMs = 50,
    this.window = 5,
    this.settleWindow = 3,
    this.staleAfter = const Duration(seconds: 5),
  });

  final int deadBandMs;
  final int capMs;
  final int stepMs;

  /// Readings in each stream's rolling median once settled.
  final int window;

  /// Readings a new stream needs before it counts, so it converges fast.
  final int settleWindow;
  final Duration staleAfter;

  final Map<String, List<double>> _natural = {};
  final Map<String, DateTime> _lastReading = {};
  final Set<String> _settled = {};

  /// Applied (ramped) and target hold-back per stream, in ms.
  final Map<String, int> delayMs = {};
  final Map<String, int> targetMs = {};

  /// A reporting stream hasn't settled yet (sample faster meanwhile).
  bool get settling => _natural.entries
      .any((e) => e.value.isNotEmpty && !_settled.contains(e.key));

  /// Track exactly [ids]. Returns the streams dropped — clear their delays.
  Set<String> retain(Set<String> ids) {
    final gone = _natural.keys.toSet().difference(ids);
    for (final id in gone) {
      _natural.remove(id);
      _lastReading.remove(id);
      _settled.remove(id);
      delayMs.remove(id);
      targetMs.remove(id);
    }
    for (final id in ids) {
      _natural.putIfAbsent(id, () => []);
    }
    return gone;
  }

  /// Resync: re-measure every stream. Delays stay until new targets land.
  void restart() {
    for (final r in _natural.values) {
      r.clear();
    }
    _settled.clear();
  }

  /// A full reset — nothing held back.
  void clear() {
    restart();
    delayMs.clear();
    targetMs.clear();
  }

  void add(String id, double ageMs, {DateTime? at}) {
    final r = _natural[id];
    if (r == null || !ageMs.isFinite || ageMs.abs() > 10000) return; // garbage
    r.add(ageMs - (delayMs[id] ?? 0));
    final keep = _settled.contains(id) ? window : settleWindow;
    while (r.length > keep) {
      r.removeAt(0);
    }
    _lastReading[id] = at ?? DateTime.now();
  }

  static double _median(List<double> v) {
    final s = [...v]..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
  }

  /// New targets from every stream that is ready (enough fresh readings).
  /// Returns true when any target moved.
  bool solve({DateTime? now}) {
    final t = now ?? DateTime.now();
    final natural = <String, double>{};
    for (final e in _natural.entries) {
      final last = _lastReading[e.key];
      if (last == null || t.difference(last) > staleAfter) continue;
      if (e.value.length < settleWindow) continue;
      natural[e.key] = _median(e.value);
    }
    if (natural.length < 2) return false; // nothing to line up
    final newest = natural.values.reduce(math.min);
    final oldest = natural.values.reduce(math.max);
    // Everyone meets the oldest stream — unless it's past the cap.
    final meet = math.min(oldest, newest + capMs);
    var changed = false;
    for (final e in natural.entries) {
      _settled.add(e.key);
      final want = (meet - e.value).round().clamp(0, capMs);
      final had = targetMs[e.key] ?? 0;
      if ((want - had).abs() < deadBandMs) continue;
      targetMs[e.key] = want;
      changed = true;
    }
    return changed;
  }

  /// One ramp step toward the targets. Returns the streams whose delay moved.
  Set<String> step() {
    final moved = <String>{};
    for (final id in {...targetMs.keys, ...delayMs.keys}) {
      final from = delayMs[id] ?? 0;
      final to = targetMs[id] ?? 0;
      final next = from + (to - from).clamp(-stepMs, stepMs).toInt();
      if (next == from) continue;
      delayMs[id] = next;
      moved.add(id);
    }
    return moved;
  }
}

/// The most RealSync holds a stream back. A camera further out than this is
/// flagged in the Studio instead of delaying everyone watching it.
const realSyncCapMs = 1000;

int clockOffsetOf(Participant? p) =>
    (parseParticipantMeta(p?.metadata)['clockOffsetMs'] as num?)?.toInt() ?? 0;

/// How old the content a remote track is playing right now is, in ms: the
/// frames' arrival age (from their capture stamps), corrected by the sender's
/// clock offset, plus the time they now sit in the jitter buffer. This
/// device's own offset is left out — it's the same for every stream, so it
/// cancels in any comparison.
class ContentAgeReader {
  final Set<String> _reading = {};
  final Map<String, ({double delay, double count})> _buffer = {};

  Future<double?> ageMs(Participant? sender, Track? track) async {
    final receiver = track?.receiver;
    final id = receiver?.receiverId;
    if (sender == null || receiver == null || id == null) return null;
    if (_reading.add(id) &&
        !await NileRealSync.readReceiver(id, audio: track is AudioTrack)) {
      _reading.remove(id);
      return null;
    }
    final arrival = (await NileRealSync.ages([id]))[id]?.ageMs;
    final buffered = await _bufferedMs(id, receiver);
    if (arrival == null || buffered == null) return null;
    return arrival + clockOffsetOf(sender) + buffered;
  }

  /// Average jitter-buffer delay since the last reading of this receiver.
  Future<double?> _bufferedMs(String id, RTCRtpReceiver receiver) async {
    try {
      for (final r in await receiver.getStats()) {
        if (r.type != 'inbound-rtp') continue;
        final delay = (r.values['jitterBufferDelay'] as num?)?.toDouble();
        final count = (r.values['jitterBufferEmittedCount'] as num?)?.toDouble();
        if (delay == null || count == null) return null;
        final before = _buffer[id];
        _buffer[id] = (delay: delay, count: count);
        if (before == null || count <= before.count) return null;
        return (delay - before.delay) / (count - before.count) * 1000;
      }
    } catch (_) {}
    return null;
  }

  /// Stop reading every receiver not in [keep].
  void retain(Set<String> keep) {
    for (final id in _reading.difference(keep)) {
      unawaited(NileRealSync.forget(id));
      _buffer.remove(id);
    }
    _reading.retainAll(keep);
  }

  void dispose() => retain(const {});
}

/// Viewer side: runs the [GroupSyncEngine] over every video feed on screen
/// and the master audio. It looks them up itself on every tick, so a new
/// camera, a closed one or a master-audio change is noticed without wiring.
class RealSyncDriver {
  RealSyncDriver({
    required this.room,
    required this.feeds,
    required this.masterAudio,
    GroupSyncEngine? engine,
  }) : engine = engine ?? GroupSyncEngine();

  final Room room;

  /// Every video feed the viewer has on screen: who sends it, and its track.
  final List<({String identity, Track? track})> Function() feeds;
  final String? Function() masterAudio;
  final GroupSyncEngine engine;
  final ContentAgeReader _ages = ContentAgeReader();

  /// Latest reading per camera (participant identity): how old its picture is
  /// as it plays here — what overlays are held back to.
  final Map<String, double> _videoAge = {};

  Timer? _sampler;
  Timer? _ramp;

  /// How old [identity]'s picture is on this screen, ms; null until measured.
  double? ageOf(String identity) => _videoAge[identity];
  DateTime _ignoreUntil = DateTime.now();

  void start() {
    _schedule(const Duration(milliseconds: 1000));
    _ramp = Timer.periodic(const Duration(milliseconds: 50), (_) => _applyStep());
  }

  /// Resync: re-measure every stream from scratch.
  void reset() {
    engine.restart();
    _ignoreUntil = DateTime.now().add(const Duration(seconds: 1));
  }

  void _schedule(Duration d) {
    _sampler?.cancel();
    _sampler = Timer(d, _sample);
  }

  Future<void> _sample() async {
    // receiverId → (sender, track) for every stream to line up.
    final streams = <String, (Participant, Track)>{};
    for (final f in feeds()) {
      final p = room.remoteParticipants[f.identity];
      final track = f.track;
      final id = track?.receiver?.receiverId;
      if (p != null && track != null && id != null) streams[id] = (p, track);
    }
    final audioFrom = room.remoteParticipants[masterAudio()];
    final audio = audioFrom?.audioTrackPublications
        .where((x) => x.subscribed)
        .firstOrNull
        ?.track;
    final audioId = audio?.receiver?.receiverId;
    if (audioFrom != null && audio != null && audioId != null) {
      streams[audioId] = (audioFrom, audio);
    }

    for (final id in engine.retain(streams.keys.toSet())) {
      unawaited(NileRealSync.setMinimumPlayoutDelay(id, null));
    }
    _ages.retain(streams.keys.toSet());

    if (DateTime.now().isAfter(_ignoreUntil)) {
      for (final e in streams.entries) {
        final age = await _ages.ageMs(e.value.$1, e.value.$2);
        if (age != null) engine.add(e.key, age);
        if (age != null && e.value.$2 is VideoTrack) {
          _videoAge[e.value.$1.identity] = age;
        }
      }
      engine.solve();
    }
    // Quick readings while anything settles (~2 s to converge), then every 2 s.
    _schedule(
      engine.settling
          ? const Duration(milliseconds: 500)
          : const Duration(seconds: 2),
    );
  }

  void _applyStep() {
    for (final id in engine.step()) {
      final ms = engine.delayMs[id] ?? 0;
      unawaited(
        NileRealSync.setMinimumPlayoutDelay(
          id,
          ms == 0 ? null : Duration(milliseconds: ms),
        ),
      );
    }
  }

  void dispose() {
    _sampler?.cancel();
    _ramp?.cancel();
    _ages.dispose();
    for (final id in engine.delayMs.keys) {
      unawaited(NileRealSync.setMinimumPlayoutDelay(id, null));
    }
    engine.clear();
  }
}

// ── 7e. Studio: each camera's lag ───────────────────────────────────────────

/// Each camera's lag behind the most current one, in ms, from how old each
/// camera's content is ([ContentAgeReader]). Cameras without a reading are
/// left out.
Map<String, int> relativeLagMs(Map<String, double> ageMs) {
  if (ageMs.isEmpty) return const {};
  final newest = ageMs.values.reduce(math.min);
  return {for (final e in ageMs.entries) e.key: (e.value - newest).round()};
}

// ── 7f. Switches ─────────────────────────────────────────────────────────────

/// RealSync runs only when the remote switch (`app_config.realsync_enabled`)
/// is on. Correction additionally needs the native self-tests to pass.
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

  /// The full loop: measuring, plus both native hooks (stamps, delay).
  static Future<bool> correcting() async =>
      await _remoteFlag() &&
      await NileRealSync.unavailableReason() == null &&
      await NileRealSync.stampUnavailableReason() == null;
}
