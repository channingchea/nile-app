import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../services/chat_service.dart' show ChatMessage;
import 'nile_studio.dart';

/// Everything in Studio Preview that would normally come from other people:
/// a trickle of chat, two crew cameras, a moving viewer count and a show clock.
/// Pure fiction, generated on a timer — nothing here reads or writes the
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

  /// Two crew cameras that never connect, drawn the way the real Studio draws
  /// assigned crew who haven't joined yet.
  static const crew = <NileStudioSource>[
    NileStudioSource(
      identity: 'crew:demo-2',
      label: 'Camera 2 · Alex',
      sublabel: 'Ready',
      isReady: true,
    ),
    NileStudioSource(
      identity: 'crew:demo-3',
      label: 'Camera 3 · Sam',
      sublabel: 'Camera 3 · not connected',
    ),
  ];

  static const _people = [
    'maya.sings', 'jordan_t', 'kofi', 'lena.b', 'dre', 'sunny', 'priya.k',
    'marco', 'ellie_r', 'tomás',
  ];

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
    'Watching with the whole family',
    'Crowd sounds amazing',
    'Can you say hi to Sam?',
    'Encore!!',
  ];

  final List<ChatMessage> messages = [];
  final Set<String> hiddenSenders = {};

  bool _live = false;
  DateTime? _liveSince;
  int _viewers = 0;
  int _seq = 0;
  Timer? _chatTimer;
  Timer? _clock;
  bool _disposed = false;

  bool get isLive => _live;
  int get viewerCount => _viewers;
  int get readyCount => crew.where((c) => c.isReady).length;
  int get crewCount => crew.length;

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
  }

  set isLive(bool live) {
    if (live == _live) return;
    _live = live;
    _liveSince = live ? DateTime.now() : null;
    _viewers = live ? 48 + _random.nextInt(30) : 0;
    notifyListeners();
  }

  void hide(String senderId) {
    hiddenSenders.add(senderId);
    notifyListeners();
  }

  void showAll() {
    hiddenSenders.clear();
    notifyListeners();
  }

  void _tick() {
    if (_live) {
      // The pretend show never ends — it just starts its clock again, so the
      // countdown can be watched as many times as anyone likes.
      if (elapsed! >= showLength) _liveSince = DateTime.now();
      if (_random.nextInt(3) == 0) {
        _viewers = (_viewers + _random.nextInt(9) - 4).clamp(40, 120);
      }
    }
    notifyListeners();
  }

  void _scheduleChat() {
    _chatTimer?.cancel();
    _chatTimer = Timer(Duration(milliseconds: 3000 + _random.nextInt(3000)), () {
      if (_disposed) return;
      addMessage();
      _scheduleChat();
    });
  }

  /// One more line of pretend chat. Public so a test can fill the column
  /// without waiting on the timer.
  @visibleForTesting
  void addMessage() {
    final who = _people[_random.nextInt(_people.length)];
    messages.add(
      ChatMessage(
        id: 'demo-${_seq++}',
        senderId: 'demo:$who',
        username: who,
        content: _lines[_random.nextInt(_lines.length)],
        sentAt: DateTime.now(),
      ),
    );
    if (messages.length > maxMessages) messages.removeAt(0);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _chatTimer?.cancel();
    _clock?.cancel();
    super.dispose();
  }
}
