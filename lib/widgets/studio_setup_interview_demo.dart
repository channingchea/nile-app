import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' show VideoTrack;

import '../services/camera_status.dart' show StudioLink;
import '../services/interview.dart';
import '../theme.dart';
import 'interview_green_room.dart';
import 'interview_stage.dart';
import 'nile_studio.dart' show NileStudioQuality;
import 'studio_preview_demo.dart';

/// A pretend interview guest in Studio Setup.
@immutable
class DemoGuest {
  const DemoGuest(this.id, this.name, this.title, this.color);

  final String id;
  final String name;
  final String title;

  /// Base colour of their placeholder picture.
  final Color color;

  String get initials => [
    for (final w in name.split(' '))
      if (w.isNotEmpty) w[0],
  ].take(2).join();
}

/// Interview mode in Studio Setup: demo guests (one still on the way), the
/// green room and the stage. Who is on stage is a local [StageState], with the
/// device clock standing in for server time. Pure fiction on one timer —
/// nothing here reads or writes the network.
class StudioSetupInterviewDemo extends ChangeNotifier {
  StudioSetupInterviewDemo({Random? random, int Function()? clock})
    : _random = random ?? Random(),
      _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Random _random;
  final int Function() _clock;

  /// Your own camera, as on the multicam rehearsal.
  static const hostId = StudioPreviewDemo.selfId;

  /// The invited guest arrives this long after the rehearsal starts.
  static const lateJoin = Duration(seconds: 10);

  /// A guest added from Invite takes this long to arrive.
  static const inviteJoin = Duration(seconds: 3);

  /// How long the automatic name lower third stays up.
  static const introSeconds = 8;

  /// Ask to unmute: the guest taps unmute after this long.
  static const _unmuteDelay = 1500;

  /// The first three are on the list from the start; the rest wait in Invite
  /// so the 6-person stage limit can be rehearsed too.
  static const guests = <DemoGuest>[
    DemoGuest(
      'demo:guest-1',
      'Maya Torres',
      'Producer, Night Shift Radio',
      NileColors.azure,
    ),
    DemoGuest(
      'demo:guest-2',
      'Jordan Lee',
      'Author, Small Rooms',
      NileColors.violet,
    ),
    DemoGuest(
      'demo:guest-3',
      'Priya Kapoor',
      'Founder, Loop Studio',
      NileColors.amber,
    ),
    DemoGuest('demo:guest-4', 'Sam Okafor', 'Drummer', NileColors.success),
    DemoGuest('demo:guest-5', 'Lena Brandt', 'Chef, Hearth', NileColors.coral),
    DemoGuest('demo:guest-6', 'Kofi Mensah', 'Photographer', NileColors.azure),
  ];

  static DemoGuest? guestById(String id) =>
      guests.where((g) => g.id == id).firstOrNull;

  final Map<String, GuestStatus> _status = {
    guests[0].id: GuestStatus.greenRoom,
    guests[1].id: GuestStatus.greenRoom,
    guests[2].id: GuestStatus.invited,
    for (final g in guests.skip(3)) g.id: GuestStatus.removed,
  };
  final Map<String, int> _joinAt = {};
  final Map<String, int> _unmuteAt = {};
  final Set<String> _muted = {};
  final Map<String, double> _levels = {};
  final Map<String, NileStudioQuality> _quality = {
    for (final g in guests) g.id: NileStudioQuality.excellent,
  };

  /// Who has been introduced since they last came on stage.
  final Set<String> _cameOn = {};
  StageState _stage = StageState.empty;
  String? _talkingTo;
  bool _talkingToAll = false;
  String? _speaker;
  double _phase = 0;
  int _ticks = 0;
  bool _begun = false;
  Timer? _timer;

  /// A guest's countdown ran out: the Studio shows their name lower third.
  void Function(DemoGuest guest)? onCameOn;

  /// An invited guest arrived in the green room.
  void Function(DemoGuest guest)? onJoined;

  int get now => _clock();
  StageState get stage => _stage;
  bool get isRunning => _timer != null;
  String? get talkingTo => _talkingTo;
  bool get talkingToAll => _talkingToAll;

  /// Drives the placeholder pictures' slow drift.
  double get phase => _phase;

  GuestStatus statusOf(String id) => _stage.contains(id)
      ? GuestStatus.onStage
      : id == hostId
      ? GuestStatus.greenRoom
      : _status[id] ?? GuestStatus.removed;
  double levelOf(String id) => _muted.contains(id) ? 0 : _levels[id] ?? 0;
  bool isMuted(String id) => _muted.contains(id);
  bool get canAddGuest => _status.containsValue(GuestStatus.removed);

  Duration? onStageFor(String id) {
    final e = _stage.entries.where((e) => e.id == id).firstOrNull;
    final t = now;
    return e == null || e.at > t ? null : Duration(milliseconds: t - e.at);
  }

  /// Starts (or resumes) the demo. The first start puts you on stage and sets
  /// the invited guest on their way.
  void start() {
    if (!_begun) {
      _begun = true;
      final t = now;
      _stage = StageState(entries: [StageEntry(hostId, t)]);
      _cameOn.add(hostId);
      _joinAt[guests[2].id] = t + lateJoin.inMilliseconds;
    }
    _timer ??= Timer.periodic(StudioLink.levelEvery, (_) => tick());
  }

  /// Pauses everything; the show state stays for when Interview comes back.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _talkingToAll = false;
  }

  // ── Host actions ───────────────────────────────────────────────────────────

  /// Starts their "you're on in 5" (you come straight on). False when the
  /// stage is full.
  bool bringOn(String id) {
    if (_stage.contains(id)) return true;
    if (_stage.isFull) return false;
    if (id != hostId && _status[id] != GuestStatus.greenRoom) return false;
    if (_talkingTo == id) _talkingTo = null;
    final at = id == hostId ? now : now + kStageCountdownSeconds * 1000;
    _stage = _with(entries: [..._stage.entries, StageEntry(id, at)]);
    notifyListeners();
    return true;
  }

  void sendBack(String id) {
    _cameOn.remove(id);
    _stage = _with(entries: [..._stage.entries.where((e) => e.id != id)]);
    notifyListeners();
  }

  /// They leave the show; Invite can bring them back.
  void remove(String id) {
    if (id == hostId) return;
    _status[id] = GuestStatus.removed;
    _joinAt.remove(id);
    _unmuteAt.remove(id);
    _muted.remove(id);
    if (_talkingTo == id) _talkingTo = null;
    sendBack(id);
  }

  /// Muting is instant; unmuting a guest asks them, and they tap it a moment
  /// later. Your own mic unmutes at once.
  void setMuted(String id, bool muted) {
    _unmuteAt.remove(id);
    if (muted) {
      _muted.add(id);
    } else if (id == hostId) {
      _muted.remove(id);
    } else {
      _unmuteAt[id] = now + _unmuteDelay;
    }
    notifyListeners();
  }

  /// Opens or closes the private line to one guest. True when now open.
  bool talk(String id) {
    _talkingTo = _talkingTo == id ? null : id;
    notifyListeners();
    return _talkingTo != null;
  }

  void talkToAll(bool on) {
    if (on == _talkingToAll) return;
    _talkingToAll = on;
    notifyListeners();
  }

  void feature(String id) {
    _stage = _with(focus: id);
    notifyListeners();
  }

  void setLayout(StageLayout layout) {
    if (layout == _stage.layout) return;
    _stage = _with(layout: layout);
    notifyListeners();
  }

  /// The extra viewer angle (`<identity>#share` or `el:<id>`); null = none.
  void setContent(String? content) {
    _stage = _with(content: content, clearContent: content == null);
    notifyListeners();
  }

  /// The next guest from Invite: on the list at once, in the green room a few
  /// seconds later. Null when everyone is already here.
  DemoGuest? addGuest() {
    final g = guests
        .where((g) => _status[g.id] == GuestStatus.removed)
        .firstOrNull;
    if (g == null) return null;
    _status[g.id] = GuestStatus.invited;
    _joinAt[g.id] = now + inviteJoin.inMilliseconds;
    notifyListeners();
    return g;
  }

  StageState _with({
    List<StageEntry>? entries,
    StageLayout? layout,
    String? focus,
    String? content,
    bool clearContent = false,
  }) {
    final list = entries ?? _stage.entries;
    final f = focus ?? _stage.focus;
    return StageState(
      entries: list,
      layout: layout ?? _stage.layout,
      focus: list.any((e) => e.id == f) ? f : null,
      content: clearContent ? null : content ?? _stage.content,
    );
  }

  // ── What the Studio draws ──────────────────────────────────────────────────

  /// The green room: on stage in stage order, then everyone else.
  List<GreenRoomEntry> greenRoomEntries({
    VideoTrack? hostTrack,
    required double hostLevel,
  }) {
    final t = now;
    GreenRoomEntry entry(String id) {
      final g = guestById(id);
      final status = statusOf(id);
      return GreenRoomEntry(
        identity: id,
        name: g?.name ?? 'You',
        title: g?.title ?? 'Host',
        kind: g == null ? GreenRoomKind.host : GreenRoomKind.guest,
        status: status,
        track: g == null ? hostTrack : null,
        level: g == null ? hostLevel : levelOf(id),
        micMuted: isMuted(id),
        quality: status == GuestStatus.invited
            ? NileStudioQuality.unknown
            : g == null
            ? NileStudioQuality.excellent
            : _quality[id]!,
        countdown: _stage.countdownFor(id, t),
        onStageFor: onStageFor(id),
        talking: _talkingTo == id,
      );
    }

    final ids = [
      ..._stage.ids,
      for (final id in [hostId, for (final g in guests) g.id])
        if (!_stage.contains(id) && statusOf(id) != GuestStatus.removed) id,
    ];
    return [for (final id in ids) entry(id)];
  }

  /// Everyone on stage, those still counting down included (the host sees
  /// them coming). The loudest unmuted voice gets the speaker outline.
  List<StageTile> stageTiles({
    VideoTrack? hostTrack,
    required double hostLevel,
  }) {
    final t = now;
    double level(String id) => isMuted(id)
        ? 0
        : id == hostId
        ? hostLevel
        : _levels[id] ?? 0;
    String? loudest;
    for (final id in _stage.visibleAt(t)) {
      if (level(id) > 0.2 && (loudest == null || level(id) > level(loudest))) {
        loudest = id;
      }
    }
    return [
      for (final id in _stage.ids)
        StageTile(
          identity: id,
          name: guestById(id)?.name ?? 'You',
          title: guestById(id)?.title ?? 'Host',
          track: id == hostId ? hostTrack : null,
          speaking: id == loudest,
          muted: isMuted(id),
          onStageFor: onStageFor(id),
          countdown: _stage.countdownFor(id, t),
        ),
    ];
  }

  // ── The clock ──────────────────────────────────────────────────────────────

  /// One beat: arrivals, unmutes, countdowns that ran out, meters, link
  /// quality and the pictures' drift. Public so a test can step it.
  @visibleForTesting
  void tick() {
    final t = now;
    _ticks++;
    for (final id in [..._joinAt.keys]) {
      if (_joinAt[id]! > t) continue;
      _joinAt.remove(id);
      if (_status[id] == GuestStatus.invited) {
        _status[id] = GuestStatus.greenRoom;
        onJoined?.call(guestById(id)!);
      }
    }
    for (final id in [..._unmuteAt.keys]) {
      if (_unmuteAt[id]! > t) continue;
      _unmuteAt.remove(id);
      _muted.remove(id);
    }
    for (final e in _stage.entries) {
      if (e.at <= t && _cameOn.add(e.id)) {
        if (guestById(e.id) case final g?) onCameOn?.call(g);
      }
    }
    _moveMeters();
    if (_ticks % 40 == 0) _rollQuality();
    _phase += 0.02;
    notifyListeners();
  }

  /// A conversation: one guest talks at a time (or nobody, while you do),
  /// in jumpy syllables; everyone else is quiet room noise.
  void _moveMeters() {
    final open = [
      for (final g in guests)
        if (_isHere(g.id) && !_muted.contains(g.id)) g.id,
    ];
    if ((_speaker != null && !open.contains(_speaker)) ||
        _random.nextDouble() < 0.04) {
      _speaker = open.isEmpty || _random.nextDouble() < 0.3
          ? null
          : open[_random.nextInt(open.length)];
    }
    for (final g in guests) {
      final id = g.id;
      final target = !open.contains(id)
          ? 0.0
          : id != _speaker
          ? 0.02 + _random.nextDouble() * 0.05
          : _random.nextDouble() < 0.15
          ? 0.05
          : 0.25 + _random.nextDouble() * 0.5;
      _levels[id] = (_levels[id] ?? 0) * 0.4 + target * 0.6;
    }
  }

  /// Every 5 s: mostly strong links, and Jordan's wifi now and then dips.
  void _rollQuality() {
    for (final g in guests) {
      final r = _random.nextDouble();
      _quality[g.id] = g.id == guests[1].id && r < 0.3
          ? NileStudioQuality.poor
          : r < 0.7
          ? NileStudioQuality.excellent
          : NileStudioQuality.good;
    }
  }

  bool _isHere(String id) {
    final s = statusOf(id);
    return s == GuestStatus.greenRoom || s == GuestStatus.onStage;
  }

  @override
  void dispose() {
    stop();
    onCameOn = null;
    onJoined = null;
    super.dispose();
  }
}

/// A demo guest's stand-in picture: a soft light drifting over their colour,
/// their initials, and a ring that swells while they talk.
class DemoGuestPicture extends StatelessWidget {
  const DemoGuestPicture({
    super.key,
    required this.guest,
    required this.phase,
    this.level = 0,
    this.dimmed = false,
  });

  final DemoGuest guest;
  final double phase;
  final double level;

  /// Not joined yet.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final seed = guest.id.codeUnits.last % 7;
    final light = Alignment(sin(phase + seed), cos(phase * 0.7 + seed) * 0.6);
    final l = level.clamp(0.0, 1.0);
    return Opacity(
      opacity: dimmed ? 0.4 : 1,
      child: AnimatedContainer(
        duration: StudioLink.levelEvery,
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: light,
            radius: 1.3,
            colors: [guest.color.withValues(alpha: 0.6), NileColors.bgRaised],
          ),
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            final d = min(box.maxWidth, box.maxHeight) * 0.42;
            return Center(
              child: AnimatedContainer(
                duration: StudioLink.levelEvery,
                width: d,
                height: d,
                alignment: Alignment.center,
                padding: EdgeInsets.all(d * 0.2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: guest.color,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.2 + l * 0.6),
                    width: 1 + l * 4,
                  ),
                ),
                child: FittedBox(
                  child: Text(
                    guest.initials,
                    style: NileTextStyles.headingMd().copyWith(
                      color: NileColors.onVolt,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
