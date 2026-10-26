import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../services/camera_status.dart';
import '../services/chat_service.dart' show ChatMessage, PinnedMessage;
import '../services/live_elements.dart'
    show
        ElementKinds,
        ElementTally,
        LiveElement,
        PollConfig,
        PollType,
        elementAngleId,
        isElementAngleId;
import 'nile_studio.dart';

/// Everything in Studio Preview that would normally come from other people:
/// a trickle of chat, two crew phones with their mic levels and health,
/// viewers moving between angles (element angles among them), votes on any
/// element open for taps, and a show clock. It also holds the show
/// controls the real Studio writes to the room — off air, default angle,
/// camera order, master audio — because here there is no room to write to.
/// Pure fiction, generated on timers — nothing here reads or writes the
/// network.
class StudioPreviewDemo extends ChangeNotifier {
  StudioPreviewDemo({Random? random}) : _random = random ?? Random();

  final Random _random;

  /// How long the pretend show has left when it goes live. Just over the
  /// ten-minute countdown window, so the countdown chip shows up within a
  /// minute instead of never.
  static const showLength = Duration(minutes: 11);
  static const countdownWindow = Duration(minutes: 10);
  static const maxMessages = 50;

  /// Your own camera, and the slot it pretends to hold.
  static const selfId = 'preview:self';
  static const selfSlot = 'demo-slot-1';

  /// You, as the chat sees you.
  static const hostId = 'demo:you';

  /// Two crew phones: connected, with no picture (nobody is really there).
  /// Not `crew:` identities — that prefix means an absent crew member, and an
  /// absent camera has no meter, health or operator to nudge.
  static const crew = <NileStudioSource>[
    NileStudioSource(
      identity: 'demo:cam-2',
      label: 'Camera 2 · Alex',
      sublabel: 'Ready',
      isReady: true,
      slotId: 'demo-slot-2',
    ),
    NileStudioSource(
      identity: 'demo:cam-3',
      label: 'Camera 3 · Sam',
      sublabel: 'Framing up',
      slotId: 'demo-slot-3',
    ),
  ];

  static const _operators = {'demo:cam-2': 'Alex', 'demo:cam-3': 'Sam'};

  /// Alex is plugged in with every control; Sam has no flashlight and a
  /// battery that runs low a minute or so in, so the alert can be rehearsed.
  static const _startHealth = {
    'demo:cam-2': CameraHealth(
      battery: 82,
      charging: true,
      thermal: ThermalLevel.nominal,
      width: 1920,
      height: 1080,
      fps: 30,
      caps: CameraCaps(
        torch: true,
        zoom: true,
        focusLock: true,
        exposureLock: true,
        flip: true,
      ),
    ),
    'demo:cam-3': CameraHealth(
      battery: 18,
      thermal: ThermalLevel.fair,
      width: 1920,
      height: 1080,
      fps: 30,
      caps: CameraCaps(
        zoom: true,
        focusLock: true,
        exposureLock: true,
        flip: true,
      ),
    ),
  };

  /// How loud each operator's room is.
  static const _gain = {'demo:cam-2': 1.0, 'demo:cam-3': 0.7};

  static const _people = [
    'maya.sings',
    'jordan_t',
    'kofi',
    'lena.b',
    'dre',
    'sunny',
    'priya.k',
    'marco',
    'ellie_r',
    'tomás',
  ];

  /// Never chatted in your shows before (the 👋 and the First-time filter).
  static const _newcomers = {'ellie_r', 'tomás'};

  static const _lines = [
    'Hey from Chicago 👋',
    'Sound is so clean tonight',
    'Can’t wait for this',
    'First time catching one of these live!',
    'Volume’s perfect',
    'Is this the new set?',
    'Love the lighting',
    '🔥🔥🔥',
    'Play the one from last week!',
    'Camera 2 angle is great',
    'Just got here, what did I miss?',
    'Hi from London 🇬🇧',
    'This is my favourite part',
    'Audio is a little quiet for me',
    'Sharing this with everyone',
    'So good 🙌',
    'What mic are you using?',
    'Crowd sounds amazing',
    'Can you say hi to Sam?',
    'Encore!!',
    'When’s the next show?',
  ];

  static const _tips = [2, 5, 5, 10, 20];

  /// Newest first, like the real Studio's list.
  final List<ChatMessage> messages = [];
  final Set<String> hiddenSenders = {};
  PinnedMessage? _pinned;

  bool _live = false;
  DateTime? _liveSince;
  int _seq = 0;
  int _said = 0;
  int _seconds = 0;
  Timer? _chatTimer;
  Timer? _clock;
  Timer? _meter;
  bool _disposed = false;

  List<String> _order = [selfSlot, for (final c in crew) c.slotId!];
  final Set<String> _offAir = {};
  String? _defaultSlot;
  String _master = selfId;
  final Map<String, int> _angleViewers = {};

  /// Element angles the host turned on (`el:` ids), and the elements open
  /// for taps with their running totals.
  List<String> _elementAngles = const [];
  final Map<String, LiveElement> _voting = {};
  final Map<String, ElementTally> _tallies = {};

  /// Each poll's round when last voting: a reset (new round) starts over.
  final Map<String, int> _rounds = {};
  Timer? _votes;

  /// Told whenever an element's pretend totals move.
  void Function(String elementId, ElementTally tally)? onTally;

  final Map<String, CameraHealth> _health = Map.of(_startHealth);
  final Map<String, double> _levels = {};
  final Set<String> _talking = {};
  final Map<String, DateTime> _ackUntil = {};
  final _alerts = CameraAlerts();

  /// Told when a crew phone's health crosses an alert line (once until it
  /// clears) — the Studio shows a toast.
  void Function(String identity, CameraAlertKind kind)? onAlert;

  bool get isLive => _live;
  int get viewerCount => _angleViewers.values.fold(0, (a, b) => a + b);
  int get readyCount => crew.where((c) => c.isReady).length;
  int get crewCount => crew.length;
  PinnedMessage? get pinned => _pinned;

  /// Camera slots and element angles top to bottom, as the host last dragged
  /// them; a new element angle starts at the bottom.
  List<String> get order => [
    for (final s in _order)
      if (!isElementAngleId(s) || _elementAngles.contains(s)) s,
    for (final a in _elementAngles)
      if (!_order.contains(a)) a,
  ];
  bool isOffAir(String slotId) => _offAir.contains(slotId);
  String? get defaultSlot => _defaultSlot;
  String get master => _master;

  /// Studio-only 👁 N for an angle; null outside a live show.
  int? viewersOn(String slotId) => _live ? _angleViewers[slotId] ?? 0 : null;

  double? levelOf(String identity) => _levels[identity];
  CameraHealth? healthOf(String identity) => _health[identity];
  bool ackedNudge(String identity) =>
      _ackUntil[identity]?.isAfter(DateTime.now()) ?? false;

  /// "Camera N · Alex" — the number follows the camera's place in [order],
  /// counting cameras only.
  String labelOf(NileStudioSource camera) =>
      'Camera ${_order.where((s) => !isElementAngleId(s)).toList().indexOf(camera.slotId!) + 1} · '
      '${_operators[camera.identity]}';

  Duration? get elapsed =>
      _liveSince == null ? null : DateTime.now().difference(_liveSince!);

  /// Same contract as the real stats row: non-null only inside the last ten
  /// minutes.
  Duration? get remaining {
    final e = elapsed;
    if (e == null) return null;
    final left = showLength - e;
    return left > countdownWindow ? null : left;
  }

  void start() {
    _scheduleChat();
    _clock ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _meter ??= Timer.periodic(StudioLink.levelEvery, (_) => _moveMeters());
  }

  set isLive(bool live) {
    if (live == _live) return;
    _live = live;
    _liveSince = live ? DateTime.now() : null;
    _angleViewers.clear();
    if (live) _seatAudience(48 + _random.nextInt(30));
    notifyListeners();
  }

  // ── Show controls ──────────────────────────────────────────────────────────

  /// Off air: anyone watching moves to the default angle, as on a real show.
  void toggleOffAir(String slotId) {
    if (_offAir.remove(slotId)) {
      notifyListeners();
      return;
    }
    _offAir.add(slotId);
    final to = _fallback;
    if (to != null && to != slotId) _move(slotId, to);
    notifyListeners();
  }

  void toggleDefault(String slotId) {
    _defaultSlot = _defaultSlot == slotId ? null : slotId;
    notifyListeners();
  }

  void sendEveryone(String slotId) {
    if (_live) {
      final total = viewerCount;
      _angleViewers
        ..clear()
        ..[slotId] = total;
    }
    notifyListeners();
  }

  void reorder(List<String> slotIds) {
    _order = [...slotIds, ..._order.where((s) => !slotIds.contains(s))];
    notifyListeners();
  }

  set master(String identity) {
    _master = identity;
    notifyListeners();
  }

  /// The elements shown as their own angle. One that goes away takes its
  /// viewers to the default angle and forgets its show settings.
  set elementAngles(List<String> elementIds) {
    final next = [for (final id in elementIds) elementAngleId(id)];
    if (listEquals(next, _elementAngles)) return;
    final gone = _elementAngles.where((a) => !next.contains(a)).toList();
    _elementAngles = next;
    for (final a in gone) {
      _offAir.remove(a);
      if (_defaultSlot == a) _defaultSlot = null;
      final to = _fallback;
      if (to != null) _move(a, to);
    }
    notifyListeners();
  }

  // ── Votes ──────────────────────────────────────────────────────────────────

  /// Its pretend totals so far (kept after taps close).
  ElementTally? tallyOf(String elementId) => _tallies[elementId];

  /// Viewers vote on exactly these elements (open for taps); any other
  /// stops. Totals stay where they got to, until a reset starts a new round.
  void vote(Iterable<LiveElement> open) {
    _voting
      ..clear()
      ..addEntries(open.map((e) => MapEntry(e.id, e)));
    for (final e in open) {
      final round = (e.state['round'] as num?)?.toInt() ?? 0;
      if (_rounds[e.id] != round) _tallies.remove(e.id);
      _rounds[e.id] = round;
      final t = _tallies[e.id];
      _tallies[e.id] = ElementTally({
        for (final c in e.choices) c: t?[c] ?? 0,
      }, t?.voters);
    }
    if (_voting.isEmpty) {
      _votes?.cancel();
      _votes = null;
    } else {
      _votes ??= Timer.periodic(
        const Duration(milliseconds: 900),
        (_) => addVotes(),
      );
    }
  }

  /// Rating answers lean toward 4 stars.
  static const _ratingWeights = [1, 2, 5, 9, 6];

  /// One beat of the audience voting: a few new votes (fast at first,
  /// slowing as most of the room has voted), now and then someone changing
  /// their mind. Leans toward the first choice so the race has a leader;
  /// ratings spread around 4; pick several honours its limit. Stops on an
  /// element whose timer ran out. Public so a test can move totals without
  /// waiting on the timer.
  @visibleForTesting
  void addVotes() {
    final room = _live ? max(viewerCount, 1) : 24;
    for (final e in [..._voting.values]) {
      final choices = e.openChoices;
      if (choices.isEmpty) continue;
      final poll = e.kind == ElementKinds.poll.wire
          ? PollConfig.fromJson(e.config)
          : null;
      final rating = poll?.type == PollType.rating;
      final limit = e.maxPicks;
      final old = _tallies[e.id];
      final t = {...?old?.counts};
      var voters = old?.people ?? 0;
      String pick() {
        if (rating) {
          var r = _random.nextInt(_ratingWeights.reduce((a, b) => a + b));
          for (final (i, w) in _ratingWeights.indexed) {
            if ((r -= w) < 0) return choices[i];
          }
        }
        return choices[_random.nextDouble() < 0.45
            ? 0
            : _random.nextInt(choices.length)];
      }

      final left = (room * 0.8).round() - voters;
      final add = left <= 0
          ? 0
          : 1 + _random.nextInt(max(1, min(4, left ~/ 4)));
      for (var i = 0; i < add; i++) {
        final picks = {pick()};
        if (limit > 1) {
          final more = _random.nextInt(limit);
          for (var k = 0; k < more; k++) {
            picks.add(choices[_random.nextInt(choices.length)]);
          }
        }
        for (final c in picks) {
          t[c] = (t[c] ?? 0) + 1;
        }
        voters++;
      }
      if (voters > 4 && _random.nextInt(4) == 0) {
        final from = choices[_random.nextInt(choices.length)];
        final to = pick();
        if (from != to &&
            (t[from] ?? 0) > 0 &&
            (limit == 1 || (t[to] ?? 0) < voters)) {
          t[from] = t[from]! - 1;
          t[to] = (t[to] ?? 0) + 1;
        }
      }
      final next = ElementTally(t, limit > 1 ? voters : null);
      _tallies[e.id] = next;
      onTally?.call(e.id, next);
    }
  }

  /// Where viewers land when their angle goes: the default angle if it's on
  /// air, else the first camera that is.
  String? get _fallback =>
      _defaultSlot != null && !_offAir.contains(_defaultSlot)
      ? _defaultSlot
      : order.where((s) => !_offAir.contains(s)).firstOrNull;

  void _move(String from, String to) {
    final n = _angleViewers.remove(from) ?? 0;
    _angleViewers[to] = (_angleViewers[to] ?? 0) + n;
  }

  void _seatAudience(int total) {
    final onAir = order.where((s) => !_offAir.contains(s)).toList();
    if (onAir.isEmpty) return;
    final home = _fallback ?? onAir.first;
    for (var i = 0; i < total; i++) {
      // Half stay where they landed; the rest wander.
      final s = _random.nextBool()
          ? home
          : onAir[_random.nextInt(onAir.length)];
      _angleViewers[s] = (_angleViewers[s] ?? 0) + 1;
    }
  }

  // ── Operators ──────────────────────────────────────────────────────────────

  /// The operator reads it and taps 👍 a couple of seconds later — and, asked
  /// to charge, plugs in.
  void nudge(String identity, String text) {
    Timer(const Duration(seconds: 2), () {
      if (_disposed) return;
      _ackUntil[identity] = DateTime.now().add(const Duration(seconds: 10));
      if (text == NudgePresets.chargeSoon) _setHealth(identity, charging: true);
      notifyListeners();
    });
  }

  /// A remote control lands on the phone at once. Returns what the operator
  /// is told.
  String? command(String identity, StudioCommand c) {
    switch (c) {
      case TorchCommand(:final on):
        _setHealth(identity, torchOn: on);
      case ZoomCommand(:final zoom):
        _setHealth(identity, zoom: zoom);
      case LockCommand(:final focus, :final exposure):
        _setHealth(identity, focusLocked: focus, exposureLocked: exposure);
      case FlipCommand() || NudgeCommand():
        break;
    }
    notifyListeners();
    return c.operatorNotice;
  }

  void _setHealth(
    String identity, {
    int? battery,
    bool? charging,
    bool? torchOn,
    double? zoom,
    bool? focusLocked,
    bool? exposureLocked,
  }) {
    final h = _health[identity];
    if (h == null) return;
    _health[identity] = CameraHealth(
      battery: battery ?? h.battery,
      charging: charging ?? h.charging,
      thermal: h.thermal,
      width: h.width,
      height: h.height,
      fps: h.fps,
      caps: h.caps,
      torchOn: torchOn ?? h.torchOn,
      zoom: zoom ?? h.zoom,
      focusLocked: focusLocked ?? h.focusLocked,
      exposureLocked: exposureLocked ?? h.exposureLocked,
    );
  }

  /// Speech-ish: phrases of jumpy syllables, quiet room noise between them.
  void _moveMeters() {
    for (final c in crew) {
      final id = c.identity;
      if (_random.nextDouble() < (_talking.contains(id) ? 0.06 : 0.1)) {
        if (!_talking.remove(id)) _talking.add(id);
      }
      final target = !_talking.contains(id)
          ? 0.02 + _random.nextDouble() * 0.05
          : _random.nextDouble() < 0.03
          ? 0.95
          : 0.25 + _random.nextDouble() * 0.5;
      _levels[id] = (_levels[id] ?? 0) * 0.4 + target * (_gain[id] ?? 1) * 0.6;
    }
    notifyListeners();
  }

  /// Every 5 s, like a phone's health message: batteries drift a percent
  /// every 15 s, and anything crossing an alert line is reported once.
  void _reportHealth() {
    final drift = _seconds % 15 == 0;
    final now = DateTime.now();
    for (final c in crew) {
      final id = c.identity;
      final h = _health[id]!;
      if (drift && h.battery != null) {
        _setHealth(
          id,
          battery: (h.battery! + (h.charging ? 1 : -1)).clamp(1, 100),
        );
      }
      for (final kind in _alerts.update(
        id,
        health: _health[id],
        poorSignal: false,
        now: now,
      )) {
        onAlert?.call(id, kind);
      }
    }
  }

  // ── Chat ───────────────────────────────────────────────────────────────────

  void hide(String senderId) {
    hiddenSenders.add(senderId);
    notifyListeners();
  }

  void showAll() {
    hiddenSenders.clear();
    notifyListeners();
  }

  /// What you type appears at once, as the host.
  Future<String?> send(String text) async {
    _add(
      ChatMessage(
        id: 'demo-${_seq++}',
        senderId: hostId,
        username: 'you',
        content: text.trim(),
        sentAt: DateTime.now(),
        senderRole: 'host',
      ),
    );
    return null;
  }

  /// "Show anyway": the held-back line becomes an ordinary one.
  void release(ChatMessage m) {
    final i = messages.indexOf(m);
    if (i < 0) return;
    messages[i] = m.copyWith(filtered: false);
    notifyListeners();
  }

  /// One pin at a time; pinning another replaces it.
  void pin(ChatMessage m) {
    _pinned = PinnedMessage(
      messageId: m.id ?? '',
      senderId: m.senderId,
      username: m.username,
      body: m.content,
      pinnedAt: DateTime.now(),
      senderRole: m.senderRole,
    );
    notifyListeners();
  }

  void unpin() {
    _pinned = null;
    notifyListeners();
  }

  void _tick() {
    _seconds++;
    if (_live) {
      // The pretend show never ends — it just starts its clock again, so the
      // countdown can be watched as many times as anyone likes.
      if (elapsed! >= showLength) _liveSince = DateTime.now();
      if (_random.nextInt(3) == 0) _driftAudience();
    }
    if (_seconds % 5 == 0) _reportHealth();
    notifyListeners();
  }

  /// A viewer arrives, leaves, or switches angle.
  void _driftAudience() {
    final onAir = order.where((s) => !_offAir.contains(s)).toList();
    if (onAir.isEmpty) return;
    final s = onAir[_random.nextInt(onAir.length)];
    final n = _angleViewers[s] ?? 0;
    switch (_random.nextInt(3)) {
      case 0 when viewerCount < 120:
        _angleViewers[s] = n + 1;
      case 1 when viewerCount > 40 && n > 0:
        _angleViewers[s] = n - 1;
      case 2 when n > 0:
        final to = onAir[_random.nextInt(onAir.length)];
        _angleViewers[s] = n - 1;
        _angleViewers[to] = (_angleViewers[to] ?? 0) + 1;
    }
  }

  void _scheduleChat() {
    _chatTimer?.cancel();
    _chatTimer = Timer(
      Duration(milliseconds: 3000 + _random.nextInt(3000)),
      () {
        if (_disposed) return;
        addMessage();
        _scheduleChat();
      },
    );
  }

  /// One more line of pretend chat — mostly viewers, now and then a tip or a
  /// crew member, and once a line your blocked words caught. Public so a test
  /// can fill the column without waiting on the timer.
  @visibleForTesting
  void addMessage() {
    final n = _said++;
    final who = _people[_random.nextInt(_people.length)];
    final roll = n == 0 ? -1 : _random.nextInt(14);
    _add(switch (roll) {
      _ when n == 3 => ChatMessage(
        id: 'demo-${_seq++}',
        senderId: 'demo:spam',
        username: 'free.followers',
        content: 'Get 10k free followers at followers4u dot biz',
        sentAt: DateTime.now(),
        filtered: true,
      ),
      0 => ChatMessage(
        id: 'demo-${_seq++}',
        senderId: '',
        username: 'Nile',
        content: '@$who tipped \$${_tips[_random.nextInt(_tips.length)]} 🎉',
        sentAt: DateTime.now(),
        kind: 'system',
      ),
      1 => ChatMessage(
        id: 'demo-${_seq++}',
        senderId: 'demo:cam-2',
        username: 'alex',
        content: 'Tonight’s setlist is up at joinnile.com',
        sentAt: DateTime.now(),
        senderRole: 'crew',
      ),
      _ => ChatMessage(
        id: 'demo-${_seq++}',
        senderId: 'demo:$who',
        username: who,
        content: _lines[_random.nextInt(_lines.length)],
        sentAt: DateTime.now(),
        firstTime: _newcomers.contains(who),
      ),
    });
  }

  void _add(ChatMessage m) {
    messages.insert(0, m);
    if (messages.length > maxMessages) messages.removeLast();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _chatTimer?.cancel();
    _clock?.cancel();
    _meter?.cancel();
    _votes?.cancel();
    onAlert = null;
    onTally = null;
    super.dispose();
  }
}
