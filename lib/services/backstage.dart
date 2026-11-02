import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import 'interview.dart';
import 'livekit_service.dart';
import 'studio_roles.dart';

/// Roles allowed behind the scenes: they see and hear green-room guests and
/// get backstage chat. Viewers never are.
const Set<String> kBackstageRoles = {
  NileRole.camera,
  NileRole.streamAudio,
  NileRole.studio,
  NileRole.guest,
};

/// Identities of everyone in [room] who is behind the scenes.
List<String> backstageIdentities(Iterable<Participant> participants) => [
  for (final p in participants)
    if (kBackstageRoles.contains(parseParticipantMeta(p.metadata)['role']))
      p.identity,
];

/// Who may subscribe to a guest's camera, mic and screen share. On stage:
/// anyone (viewers included). In the green room: only the people behind the
/// scenes. The SFU enforces it, so a modified viewer app can't peek.
({bool all, List<ParticipantTrackPermission> allowed}) guestTrackPermissions(
  Iterable<Participant> remotes, {
  required bool onStage,
}) => onStage
    ? (all: true, allowed: const [])
    : (
        all: false,
        allowed: [
          for (final id in backstageIdentities(remotes))
            ParticipantTrackPermission(id, true, null),
        ],
      );

/// Apply [guestTrackPermissions] to a guest's own connection. Call on join,
/// whenever someone joins or changes metadata, and when the stage changes.
void applyGuestPrivacy(Room room, {required bool onStage}) {
  final p = guestTrackPermissions(
    room.remoteParticipants.values,
    onStage: onStage,
  );
  room.localParticipant?.setTrackSubscriptionPermissions(
    allParticipantsAllowed: p.all,
    trackPermissions: p.allowed,
  );
}

@immutable
class BackstageMessage {
  const BackstageMessage({
    required this.from,
    required this.name,
    required this.text,
    required this.at,
    this.mine = false,
  });

  final String from;
  final String name;
  final String text;
  final DateTime at;
  final bool mine;

  static const maxLength = 500;
}

/// Backstage chat: host, crew and guests only, over the room's data channel
/// with explicit recipients (the SFU delivers to those identities alone).
/// Nothing is stored — it's the show's walkie-talkie, not the public chat.
class BackstageChat extends ChangeNotifier {
  BackstageChat(this._room, {required this.selfName}) {
    _listener = _room.createListener()
      ..on<DataReceivedEvent>((e) {
        if (e.topic != kBackstageTopic || e.participant == null) return;
        final role = parseParticipantMeta(e.participant!.metadata)['role'];
        if (!kBackstageRoles.contains(role)) return;
        try {
          final m = jsonDecode(utf8.decode(e.data));
          final text = (m is Map ? m['text'] : null) as String?;
          if (text == null || text.isEmpty) return;
          _add(
            BackstageMessage(
              from: e.participant!.identity,
              // The token's name, not the payload's: a guest can't post as
              // "Host".
              name: e.participant!.name.isNotEmpty
                  ? e.participant!.name
                  : e.participant!.identity,
              text: text.length > BackstageMessage.maxLength
                  ? text.substring(0, BackstageMessage.maxLength)
                  : text,
              at: DateTime.now(),
            ),
          );
        } catch (_) {}
      });
  }

  final Room _room;
  final String selfName;
  late final EventsListener<RoomEvent> _listener;
  final List<BackstageMessage> _messages = [];

  /// Newest last.
  List<BackstageMessage> get messages => List.unmodifiable(_messages);

  /// Unread since [markRead].
  int unread = 0;

  void markRead() {
    if (unread == 0) return;
    unread = 0;
    notifyListeners();
  }

  void _add(BackstageMessage m) {
    _messages.add(m);
    if (_messages.length > 200) _messages.removeAt(0);
    if (!m.mine) unread++;
    notifyListeners();
  }

  Future<void> send(String raw) async {
    final text = raw.trim();
    final lp = _room.localParticipant;
    if (text.isEmpty || lp == null) return;
    final to = backstageIdentities(_room.remoteParticipants.values);
    final clipped = text.length > BackstageMessage.maxLength
        ? text.substring(0, BackstageMessage.maxLength)
        : text;
    if (to.isNotEmpty) {
      await lp.publishData(
        utf8.encode(jsonEncode({'text': clipped, 'name': selfName})),
        reliable: true,
        destinationIdentities: to,
        topic: kBackstageTopic,
      );
    }
    _add(
      BackstageMessage(
        from: lp.identity,
        name: selfName,
        text: clipped,
        at: DateTime.now(),
        mine: true,
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_listener.dispose());
    super.dispose();
  }
}

/// The Studio's talkback: a second, publish-only connection (identity
/// `backstage-<eventId>`) whose mic only the guests being talked to may hear.
/// A second connection because subscription permissions are per participant —
/// limiting the Studio's own connection would cut viewers off its show audio.
class BackstageLine extends ChangeNotifier {
  BackstageLine(this.eventId);

  final String eventId;
  Room? _room;
  LocalAudioTrack? _mic;
  EventsListener<RoomEvent>? _listener;
  bool _disposed = false;

  /// Who hears the host right now. Empty = nobody (mic muted).
  Set<String> get talkingTo => Set.unmodifiable(_to);
  final Set<String> _to = {};

  bool get isTalking => _to.isNotEmpty;
  int _calls = 0;

  Future<void>? _connectingFuture;

  Future<void> _ensure() => _connectingFuture ??= _connect().whenComplete(
    () => _connectingFuture = null,
  );

  Future<void> _connect() async {
    if (_room != null) return;
    try {
      final t = await LivekitService.backstageToken(eventId: eventId);
      final room = Room(roomOptions: const RoomOptions(adaptiveStream: false));
      await room.connect(
        t.wsUrl,
        t.token,
        connectOptions: const ConnectOptions(autoSubscribe: false),
      );
      room.localParticipant?.setTrackSubscriptionPermissions(
        allParticipantsAllowed: false,
      );
      // A full reconnect republishes the mic without resending permissions
      // (livekit_client 2.7) and the new session starts open to everyone:
      // mute until they've gone out again.
      _listener = room.createListener()
        ..on<RoomReconnectingEvent>((_) => unawaited(_mic?.mute()))
        ..on<RoomReconnectedEvent>((_) => unawaited(talkTo({..._to})));
      final mic = await LocalAudioTrack.create(const AudioCaptureOptions());
      await room.localParticipant?.publishAudioTrack(mic);
      await mic.mute();
      if (_disposed) {
        unawaited(mic.stop());
        unawaited(room.disconnect());
        return;
      }
      _room = room;
      _mic = mic;
    } catch (_) {
      _to.clear();
      if (!_disposed) notifyListeners();
      rethrow;
    }
  }

  /// Open the line to [identities] (guests); empty closes it. Calls can
  /// overlap (Hold to talk released while the first connect is in flight):
  /// only the latest one acts once the connection is up.
  Future<void> talkTo(Set<String> identities) async {
    final call = ++_calls;
    _to
      ..clear()
      ..addAll(identities);
    notifyListeners();
    if (identities.isEmpty) {
      await _mic?.mute();
      _room?.localParticipant?.setTrackSubscriptionPermissions(
        allParticipantsAllowed: false,
      );
      return;
    }
    await _ensure();
    if (call != _calls || _room == null) return;
    _room?.localParticipant?.setTrackSubscriptionPermissions(
      allParticipantsAllowed: false,
      trackPermissions: [
        for (final id in identities) ParticipantTrackPermission(id, true, null),
      ],
    );
    await _mic?.unmute();
  }

  Future<void> stop() => talkTo(const {});

  @override
  void dispose() {
    _disposed = true;
    unawaited(_listener?.dispose());
    final room = _room;
    _room = null;
    unawaited(_mic?.stop());
    unawaited(room?.disconnect());
    super.dispose();
  }
}
