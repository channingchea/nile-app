import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' hide ChatMessage;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/chat_service.dart';
import '../services/event_service.dart';
import '../services/livekit_service.dart';
import '../services/profile_service.dart';
import '../services/realtime.dart';
import '../theme.dart';
import '../widgets/rolling_number.dart';

class ViewerScreen extends StatefulWidget {
  final String? initialEventId;

  const ViewerScreen({super.key, this.initialEventId});

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

enum ViewerState { idle, connecting, watching }

class CameraFeed {
  final String identity;
  final String cameraName;
  final VideoTrack? track;

  CameraFeed({required this.identity, required this.cameraName, this.track});
}

class _ViewerScreenState extends State<ViewerScreen> {
  final _eventIdController = TextEditingController();

  ViewerState _state = ViewerState.idle;
  Room? _room;
  EventsListener<RoomEvent>? _listener;
  final List<CameraFeed> _cameras = [];
  int _focusedIndex = 0;
  String? _errorMessage;

  // Audio management
  final Map<String, RemoteTrackPublication> _audioPublications = {};
  bool _audioEnabled = true;
  String? _masterAudioIdentity;

  // Camera sync. Stream Audio is the zero reference: each camera's video
  // subscribe is held back by (audioJoinedAt - cameraJoinedAt), clamped to
  // [0, 2000]ms, so switchable angles align with the audio timeline. Both
  // anchors are server-stamped (no device clock skew). The room's showStartedAt
  // isn't needed for the math — offsets derive purely from joinedAt deltas.
  static const int _maxSyncDelayMs = 2000;
  int? _audioJoinedAt;

  // Phase 7: viewer count + realtime
  int _viewerCount = 0;
  String? _streamEventId; // liveKitEventId for cleanup
  bool _streamEnded = false;
  // True while the room dropped (e.g. all cameras left) but the show is still
  // live in the DB — we hold a "reconnecting" overlay and retry rather than
  // ending. Only an `ended` DB status actually ends the show.
  bool _reconnecting = false;
  int _reconnectAttempt = 0;
  // Event status drives the Lobby: 'soundcheck' → Lobby, 'live' → stream.
  String? _eventStatus;
  ResilientChannel? _eventConn;
  bool _hasIncrementedViewerCount = false;

  // Live chat (ephemeral broadcast). Capped in-memory buffer so a session feels
  // populated without persisting anything server-side.
  static const int _maxChatMessages = 200;
  RealtimeChannel? _chatChannel;
  final List<ChatMessage> _chatMessages = [];
  final _chatController = TextEditingController();
  final _chatScrollController = ScrollController();
  String? _myUsername;
  bool _chatOpen = false;
  bool _hasUnreadChat = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialEventId != null) {
      _eventIdController.text = widget.initialEventId!;
      // Auto-join when launched from the feed
      WidgetsBinding.instance.addPostFrameCallback((_) => _joinAsViewer());
    }
  }

  @override
  void dispose() {
    _decrementAndCleanup();
    _eventIdController.dispose();
    _chatController.dispose();
    _chatScrollController.dispose();
    _listener?.dispose();
    _room?.disconnect();
    super.dispose();
  }

  void _decrementAndCleanup() {
    if (_hasIncrementedViewerCount && _streamEventId != null) {
      EventService.decrementViewerCount(_streamEventId!).catchError((_) {});
      _hasIncrementedViewerCount = false;
    }
    _eventConn?.dispose();
    _eventConn = null;
    _chatChannel?.unsubscribe();
    _chatChannel = null;
  }

  /// Re-pull authoritative event state after a realtime drop/rejoin, so a status
  /// or viewer-count change missed while disconnected is applied on reconnect.
  Future<void> _resyncEventState(String liveKitEventId) async {
    try {
      final state = await EventService.fetchEventState(liveKitEventId);
      if (!mounted || state == null) return;
      _onRealtimeUpdate(state);
    } catch (_) {}
  }

  // ── Chat ──────────────────────────────────────────────────────────────────

  void _onChatMessage(ChatMessage msg) {
    if (!mounted) return;
    setState(() {
      _chatMessages.add(msg);
      if (_chatMessages.length > _maxChatMessages) {
        _chatMessages.removeRange(0, _chatMessages.length - _maxChatMessages);
      }
      if (!_chatOpen && !msg.isMine) _hasUnreadChat = true;
    });
    if (_chatOpen) _scrollChatToBottom();
  }

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.jumpTo(
          _chatScrollController.position.maxScrollExtent,
        );
      }
    });
  }

  void _toggleChat() {
    setState(() {
      _chatOpen = !_chatOpen;
      if (_chatOpen) _hasUnreadChat = false;
    });
    if (_chatOpen) _scrollChatToBottom();
  }

  Future<void> _sendChat() async {
    final raw = _chatController.text.trim();
    if (raw.isEmpty || _chatChannel == null) return;
    final text = raw.length > 250 ? raw.substring(0, 250) : raw;
    _chatController.clear();
    await ChatService.send(
      _chatChannel!,
      username: _myUsername ?? 'viewer',
      content: text,
    );
  }

  // ── Realtime callback ─────────────────────────────────────────────────────

  void _onRealtimeUpdate(Map<String, dynamic> record) {
    if (!mounted) return;
    setState(() {
      if (record['viewer_count'] != null) {
        _viewerCount = record['viewer_count'] as int;
      }
      // Status flips drive the Lobby → stream transition. When Start Show is
      // pressed, status becomes 'live' and the build switches automatically.
      if (record['status'] is String) {
        _eventStatus = record['status'] as String;
      }
      if (record['status'] == 'ended') {
        _streamEnded = true;
      }
    });
  }

  // ── Join ──────────────────────────────────────────────────────────────────

  Future<void> _joinAsViewer() async {
    final eventId = _eventIdController.text.trim();
    if (eventId.isEmpty) {
      setState(() => _errorMessage = 'Please enter an Event ID.');
      return;
    }

    setState(() {
      _state = ViewerState.connecting;
      _errorMessage = null;
    });

    Room? room;
    try {
      // Fetch initial event state (viewer count + guard against already-ended)
      final eventState = await EventService.fetchEventState(eventId);
      if (eventState != null && eventState['status'] == 'ended') {
        setState(() {
          _state = ViewerState.idle;
          _errorMessage = 'This stream has already ended.';
        });
        return;
      }

      // Viewer identity now comes from the signed-in user's JWT (the Edge
      // Function reads it server-side) — we no longer send a viewerId.
      final conn = await LivekitService.viewerToken(eventId: eventId);

      // The descriptor's mode is "webrtc" today; an "hls" mode is reserved for
      // much higher scale and would connect differently here.
      if (conn.mode != 'webrtc') {
        throw Exception('Unsupported stream mode: ${conn.mode}');
      }
      final token = conn.token;
      final wsUrl = conn.wsUrl;

      room = Room();
      final listener = room.createListener();

      listener
        ..on<TrackSubscribedEvent>(_onTrackSubscribed)
        ..on<TrackUnsubscribedEvent>(_onTrackUnsubscribed)
        ..on<ParticipantConnectedEvent>(_onParticipantConnected)
        ..on<ParticipantDisconnectedEvent>(_onParticipantDisconnected)
        ..on<ParticipantMetadataUpdatedEvent>(_onParticipantMetadataUpdated)
        ..on<RoomDisconnectedEvent>(_onRoomDisconnected);

      // Fail loudly instead of hanging on "Joining stream…" forever.
      await room
          .connect(wsUrl, token)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () =>
                throw Exception('Connection timed out. Try again.'),
          );

      // Read the master-audio participant's joinedAt before touching any
      // camera — it's the zero reference every camera offset is measured against.
      _audioJoinedAt = _findAudioJoinedAt(room);

      for (final participant in room.remoteParticipants.values) {
        for (final publication in participant.videoTrackPublications) {
          // Don't gate on TrackSource — it can still be `unknown` at this point.
          // _addCamera authoritatively checks the participant's role == 'camera'.
          if (publication.subscribed && publication.track != null) {
            _addCamera(participant, publication.track as VideoTrack);
          } else {
            // Hold the video back until it aligns with the audio timeline; the
            // track arrives via TrackSubscribedEvent. Covers autoSubscribe off.
            _delayedSubscribeVideo(participant, publication);
          }
        }
        for (final publication in participant.audioTrackPublications) {
          if (publication.subscribed && publication.track != null) {
            _storeAudioPublication(participant, publication);
          } else {
            publication.subscribe();
          }
        }
      }

      // Increment viewer count + subscribe to realtime
      EventService.incrementViewerCount(eventId).catchError((_) {});

      final eventConn = ResilientChannel(
        onResync: () => _resyncEventState(eventId),
        build: (onStatus) => EventService.subscribeToEvent(
          liveKitEventId: eventId,
          onUpdate: _onRealtimeUpdate,
          onStatus: onStatus,
        ),
      );

      // Open the ephemeral chat channel and resolve our username once for
      // outgoing messages (broadcast carries no profile join).
      final chatChannel = ChatService.subscribe(eventId, _onChatMessage);
      ProfileService.fetchCurrentProfile()
          .then((p) => _myUsername = p?.username)
          .catchError((_) => null);

      setState(() {
        _room = room;
        _listener = listener;
        _masterAudioIdentity = _findMasterAudioIdentity(room);
        _streamEventId = eventId;
        _viewerCount = eventState?['viewer_count'] as int? ?? 0;
        _eventStatus = eventState?['status'] as String?;
        _hasIncrementedViewerCount = true;
        _eventConn = eventConn;
        _chatChannel = chatChannel;
        _state = ViewerState.watching;
      });

      _updateAudioRouting();
    } catch (e) {
      await room?.disconnect();
      if (!mounted) return;
      setState(() {
        _state = ViewerState.idle;
        _errorMessage = 'Failed to connect: ${e.toString()}';
      });
    }
  }

  // ── LiveKit event handlers ────────────────────────────────────────────────

  void _onTrackSubscribed(TrackSubscribedEvent event) {
    // Don't gate on TrackSource (can be `unknown` at subscribe time) — _addCamera
    // checks the participant's role == 'camera' authoritatively.
    if (event.track is VideoTrack) {
      final idx = _cameras.indexWhere(
        (c) => c.identity == event.participant.identity,
      );
      if (idx != -1) {
        setState(() {
          _cameras[idx] = CameraFeed(
            identity: _cameras[idx].identity,
            cameraName: _cameras[idx].cameraName,
            track: event.track as VideoTrack,
          );
        });
      } else {
        _addCamera(event.participant, event.track as VideoTrack);
      }
    } else if (event.track is AudioTrack) {
      _storeAudioPublication(event.participant, event.publication);
    }
  }

  void _onTrackUnsubscribed(TrackUnsubscribedEvent event) {
    if (event.track is VideoTrack) {
      final idx = _cameras.indexWhere(
        (c) => c.identity == event.participant.identity,
      );
      if (idx != -1) {
        setState(() {
          _cameras[idx] = CameraFeed(
            identity: _cameras[idx].identity,
            cameraName: _cameras[idx].cameraName,
            track: null,
          );
        });
      }
      _updateAudioRouting();
    } else if (event.track is AudioTrack) {
      _audioPublications.remove(event.participant.identity);
    }
  }

  void _onParticipantDisconnected(ParticipantDisconnectedEvent event) {
    _audioPublications.remove(event.participant.identity);
    setState(() {
      _cameras.removeWhere((c) => c.identity == event.participant.identity);
      if (_focusedIndex >= _cameras.length && _cameras.isNotEmpty) {
        _focusedIndex = _cameras.length - 1;
      }
    });
    if (event.participant.identity == _masterAudioIdentity) {
      final newIdentity = _findMasterAudioIdentity(_room);
      setState(() => _masterAudioIdentity = newIdentity);
    }
    _updateAudioRouting();
  }

  void _onParticipantConnected(ParticipantConnectedEvent event) {
    final newIdentity = _findMasterAudioIdentity(_room);
    if (newIdentity != _masterAudioIdentity) {
      setState(() => _masterAudioIdentity = newIdentity);
      _updateAudioRouting();
    }

    // Camera sync on (re)join: a fresh token carries a fresh server-stamped
    // joinedAt. If the master-audio participant (re)joined, refresh the zero
    // reference so every subsequent camera offset is measured against it.
    final meta = _parseMeta(event.participant.metadata);
    final role = meta['role'];
    if (role == 'master-audio' ||
        (role == 'camera' && meta['isMasterAudio'] == true)) {
      final ja = (meta['joinedAt'] as num?)?.toInt();
      if (ja != null) _audioJoinedAt = ja;
    }
    // Subscribe this participant's video held back to the audio timeline. Same
    // path as initial join — no special-casing.
    for (final publication in event.participant.videoTrackPublications) {
      if (!publication.subscribed) {
        _delayedSubscribeVideo(event.participant, publication);
      }
    }
  }

  // ── Camera sync ───────────────────────────────────────────────────────────

  Map<String, dynamic> _parseMeta(String? raw) {
    try {
      final m = jsonDecode(raw ?? '{}');
      return m is Map<String, dynamic> ? m : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// joinedAt of the master-audio source — the zero reference for offsets.
  int? _findAudioJoinedAt(Room? room) {
    if (room == null) return null;
    for (final p in room.remoteParticipants.values) {
      final meta = _parseMeta(p.metadata);
      if (meta['role'] == 'master-audio') {
        return (meta['joinedAt'] as num?)?.toInt();
      }
    }
    for (final p in room.remoteParticipants.values) {
      final meta = _parseMeta(p.metadata);
      if (meta['role'] == 'camera' && meta['isMasterAudio'] == true) {
        return (meta['joinedAt'] as num?)?.toInt();
      }
    }
    return null;
  }

  /// Subscribe a camera's video held back so it aligns with the audio timeline.
  /// A camera that joined before audio is delayed by (audioJoinedAt -
  /// cameraJoinedAt), clamped to [0, _maxSyncDelayMs]; one that joined after
  /// (or any case with missing data) subscribes immediately.
  void _delayedSubscribeVideo(
    RemoteParticipant participant,
    RemoteTrackPublication publication,
  ) {
    final cameraJoinedAt =
        (_parseMeta(participant.metadata)['joinedAt'] as num?)?.toInt();
    int delayMs = 0;
    if (_audioJoinedAt != null && cameraJoinedAt != null) {
      delayMs = (_audioJoinedAt! - cameraJoinedAt).clamp(0, _maxSyncDelayMs);
    }
    if (delayMs == 0) {
      publication.subscribe();
      return;
    }
    Future.delayed(Duration(milliseconds: delayMs), () {
      if (!mounted || _room == null) return;
      if (!publication.subscribed) publication.subscribe();
    });
  }

  void _onParticipantMetadataUpdated(ParticipantMetadataUpdatedEvent event) {
    final newIdentity = _findMasterAudioIdentity(_room);
    if (newIdentity != _masterAudioIdentity) {
      setState(() => _masterAudioIdentity = newIdentity);
      _updateAudioRouting();
    }
  }

  void _onRoomDisconnected(RoomDisconnectedEvent event) {
    // The LiveKit room dropped. This is NOT the same as the show ending — the
    // room also closes when the last camera leaves (app backgrounded, network
    // blip, crash) while the host hasn't pressed End Stream. The DB `status`
    // column is the single source of truth for "is this show over". So instead
    // of ending here, attempt to reconnect; only `status == 'ended'` (handled
    // in _onRealtimeUpdate / the poll below) actually ends the show.
    if (!mounted ||
        _state != ViewerState.watching ||
        _streamEnded ||
        _reconnecting) {
      return;
    }
    _reconnecting = true;
    _reconnectAttempt = 0;
    _attemptReconnect();
  }

  /// Poll the DB status and re-join the room with a fresh token. Retries with
  /// backoff while the show is still live/soundcheck; stops (and ends) only if
  /// the DB says `ended`. The realtime channel stays subscribed throughout, so
  /// a host pressing End Stream mid-reconnect flips _streamEnded immediately.
  Future<void> _attemptReconnect() async {
    final eventId = _streamEventId;
    if (!mounted || eventId == null || _streamEnded) {
      if (mounted) setState(() => _reconnecting = false);
      return;
    }

    final state = await EventService.fetchEventState(eventId);
    if (!mounted) return;
    if (state?['status'] == 'ended') {
      setState(() {
        _reconnecting = false;
        _streamEnded = true;
      });
      return;
    }

    try {
      await _rejoinRoom(eventId);
      if (mounted) setState(() => _reconnecting = false);
    } catch (_) {
      _reconnectAttempt++;
      // Back off: 2s, 4s, 6s … capped at 10s. Keep trying until the host ends.
      final delay = Duration(seconds: (2 * _reconnectAttempt).clamp(2, 10));
      Future.delayed(delay, () {
        if (mounted && _reconnecting && !_streamEnded) _attemptReconnect();
      });
    }
  }

  /// Tear down the dead room and connect a fresh one for [eventId], re-wiring
  /// listeners and re-subscribing to existing tracks. Throws on failure so the
  /// caller can back off and retry.
  Future<void> _rejoinRoom(String eventId) async {
    await _listener?.dispose();
    await _room?.disconnect();

    final conn = await LivekitService.viewerToken(eventId: eventId);
    if (conn.mode != 'webrtc') {
      throw Exception('Unsupported stream mode: ${conn.mode}');
    }

    final room = Room();
    final listener = room.createListener();
    listener
      ..on<TrackSubscribedEvent>(_onTrackSubscribed)
      ..on<TrackUnsubscribedEvent>(_onTrackUnsubscribed)
      ..on<ParticipantConnectedEvent>(_onParticipantConnected)
      ..on<ParticipantDisconnectedEvent>(_onParticipantDisconnected)
      ..on<ParticipantMetadataUpdatedEvent>(_onParticipantMetadataUpdated)
      ..on<RoomDisconnectedEvent>(_onRoomDisconnected);

    await room
        .connect(conn.wsUrl, conn.token)
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw Exception('Reconnect timed out.'),
        );

    _audioJoinedAt = _findAudioJoinedAt(room);
    setState(() {
      _cameras.clear();
      _audioPublications.clear();
      _focusedIndex = 0;
      _room = room;
      _listener = listener;
      _masterAudioIdentity = _findMasterAudioIdentity(room);
    });

    for (final participant in room.remoteParticipants.values) {
      for (final publication in participant.videoTrackPublications) {
        if (publication.subscribed && publication.track != null) {
          _addCamera(participant, publication.track as VideoTrack);
        } else {
          _delayedSubscribeVideo(participant, publication);
        }
      }
      for (final publication in participant.audioTrackPublications) {
        if (publication.subscribed && publication.track != null) {
          _storeAudioPublication(participant, publication);
        } else {
          publication.subscribe();
        }
      }
    }
    _updateAudioRouting();
  }

  // ── Audio management ──────────────────────────────────────────────────────

  void _storeAudioPublication(
    RemoteParticipant participant,
    RemoteTrackPublication publication,
  ) {
    try {
      final meta = jsonDecode(participant.metadata ?? '{}');
      final role = meta['role'] as String?;
      if (role == 'camera' || role == 'master-audio') {
        _audioPublications[participant.identity] = publication;
        _updateAudioRouting();
      }
    } catch (_) {}
  }

  String? _findMasterAudioIdentity(Room? room) {
    if (room == null) return null;
    for (final p in room.remoteParticipants.values) {
      try {
        final meta = jsonDecode(p.metadata ?? '{}');
        if (meta['role'] == 'master-audio') return p.identity;
      } catch (_) {}
    }
    for (final p in room.remoteParticipants.values) {
      try {
        final meta = jsonDecode(p.metadata ?? '{}');
        if (meta['role'] == 'camera' && meta['isMasterAudio'] == true) {
          return p.identity;
        }
      } catch (_) {}
    }
    return null;
  }

  void _updateAudioRouting() {
    if (!_audioEnabled) {
      for (final pub in _audioPublications.values) {
        pub.unsubscribe();
      }
      return;
    }
    final target =
        _masterAudioIdentity ??
        (_cameras.isNotEmpty
            ? _cameras[_focusedIndex.clamp(0, _cameras.length - 1)].identity
            : null);
    if (target == null) return;
    for (final entry in _audioPublications.entries) {
      if (entry.key == target) {
        entry.value.subscribe();
      } else {
        entry.value.unsubscribe();
      }
    }
  }

  String _masterAudioName() {
    if (_masterAudioIdentity == null) return '';
    for (final c in _cameras) {
      if (c.identity == _masterAudioIdentity) return c.cameraName;
    }
    return _room?.remoteParticipants[_masterAudioIdentity]?.name ??
        _masterAudioIdentity!;
  }

  bool _isStreamAudioSource() {
    if (_masterAudioIdentity == null || _room == null) return false;
    try {
      final meta = jsonDecode(
        _room!.remoteParticipants[_masterAudioIdentity]?.metadata ?? '{}',
      );
      return meta['role'] == 'master-audio';
    } catch (_) {
      return false;
    }
  }

  // ── Camera helpers ────────────────────────────────────────────────────────

  void _addCamera(RemoteParticipant participant, VideoTrack track) {
    Map<String, dynamic> meta;
    try {
      meta = jsonDecode(participant.metadata ?? '{}') as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (meta['role'] != 'camera') return;
    if (_cameras.any((c) => c.identity == participant.identity)) return;

    final cameraName =
        (meta['cameraName'] as String?) ??
        (participant.name.isNotEmpty ? participant.name : participant.identity);

    setState(() {
      _cameras.add(
        CameraFeed(
          identity: participant.identity,
          cameraName: cameraName,
          track: track,
        ),
      );
    });
    _updateAudioRouting();
  }

  // ── Leave ─────────────────────────────────────────────────────────────────

  Future<void> _leave() async {
    _decrementAndCleanup();
    await _listener?.dispose();
    await _room?.disconnect();
    setState(() {
      _room = null;
      _listener = null;
      _cameras.clear();
      _audioPublications.clear();
      _focusedIndex = 0;
      _masterAudioIdentity = null;
      _audioEnabled = true;
      _viewerCount = 0;
      _streamEventId = null;
      _streamEnded = false;
      _eventStatus = null;
      _chatMessages.clear();
      _chatController.clear();
      _chatOpen = false;
      _hasUnreadChat = false;
      _myUsername = null;
      _state = ViewerState.idle;
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: _state == ViewerState.watching
          ? null // full-screen watching: no AppBar
          : AppBar(
              title: Text('Watch', style: NileTextStyles.headingMd()),
              backgroundColor: Colors.transparent,
            ),
      body: switch (_state) {
        ViewerState.idle => _buildForm(),
        ViewerState.connecting => _buildConnecting(),
        ViewerState.watching => _buildWatching(),
      },
    );
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(NileSpacing.s32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Join a stream', style: NileTextStyles.headingLg()),
          const SizedBox(height: 32),
          TextField(
            controller: _eventIdController,
            style: NileTextStyles.bodyLg(),
            decoration: const InputDecoration(
              labelText: 'Event ID',
              hintText: 'e.g. show-2024-01',
            ),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: NileTextStyles.bodyMd().copyWith(color: NileColors.error),
            ),
          ],
          const SizedBox(height: 32),
          FilledButton.icon(
            onPressed: _joinAsViewer,
            icon: const Icon(Icons.tv),
            label: const Text('Watch Now'),
            style: FilledButton.styleFrom(
              backgroundColor: NileColors.volt,
              foregroundColor: NileColors.onVolt,
              padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
              textStyle: NileTextStyles.labelLg(),
              shape: const StadiumBorder(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnecting() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: NileColors.volt),
          const SizedBox(height: 16),
          Text('Joining stream...', style: NileTextStyles.bodyMd()),
        ],
      ),
    );
  }

  // ── Lobby (host in Sound Check) ───────────────────────────────────────────

  Widget _buildLobby() {
    return Column(
      children: [
        _buildTopBar(),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.tune, size: 56, color: NileColors.volt),
                  const SizedBox(height: 24),
                  Text(
                    'Your host is in Sound Check.',
                    style: NileTextStyles.headingMd(),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'The show will begin soon.',
                    style: NileTextStyles.bodyMd().copyWith(
                      color: NileColors.txtSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  CircularProgressIndicator(color: NileColors.volt),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCameraOffPlaceholder({required bool large}) {
    return Container(
      color: NileColors.bgSurface,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.videocam_off,
              size: large ? 48 : 24,
              color: NileColors.border,
            ),
            if (large) ...[
              const SizedBox(height: 8),
              Text(
                'Camera Off',
                style: NileTextStyles.bodyMd().copyWith(
                  color: NileColors.txtTertiary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildWatching() {
    // Lobby: the host is in Sound Check — hold viewers here until Start Show
    // flips status to 'live' (handled by realtime in _onRealtimeUpdate).
    if (_eventStatus == 'soundcheck' && !_streamEnded) {
      return _buildLobby();
    }
    return Stack(
      children: [
        Column(
          children: [
            _buildTopBar(),
            if (_cameras.isEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(color: NileColors.volt),
                      const SizedBox(height: 16),
                      Text(
                        'Waiting for cameras to connect...',
                        style: NileTextStyles.bodyMd().copyWith(
                          color: NileColors.txtSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: OrientationBuilder(
                  builder: (context, orientation) {
                    final isLandscape = orientation == Orientation.landscape;
                    return Column(
                      children: [
                        _buildAudioBar(),
                        Expanded(
                          child: isLandscape
                              ? _buildLandscapeLayout()
                              : _buildPortraitLayout(),
                        ),
                      ],
                    );
                  },
                ),
              ),
          ],
        ),

        // Collapsible live chat — sits above the video, slides off when closed
        if (!_streamEnded) _buildChatOverlay(),

        // Reconnecting overlay — room dropped but the show is still live.
        if (_reconnecting && !_streamEnded) _buildReconnectingOverlay(),

        // Stream ended overlay
        if (_streamEnded) _buildStreamEndedOverlay(),
      ],
    );
  }

  Widget _buildReconnectingOverlay() {
    return Positioned.fill(
      child: ColoredBox(
        color: NileColors.bgPage.withValues(alpha: 0.85),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: NileColors.volt),
              const SizedBox(height: 16),
              Text('Reconnecting…', style: NileTextStyles.headingMd()),
              const SizedBox(height: 8),
              Text(
                'The stream dropped briefly. Hang tight.',
                style: NileTextStyles.bodyMd().copyWith(
                  color: NileColors.txtSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Top bar (viewer count + leave) ────────────────────────────────────────

  Widget _buildTopBar() {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 8,
        left: 16,
        right: 8,
        bottom: 8,
      ),
      color: NileColors.bgPage,
      child: Row(
        children: [
          // Status badge — SOUND CHECK (volt) in the Lobby, LIVE (coral) once live
          Builder(
            builder: (_) {
              final inLobby = _eventStatus == 'soundcheck' && !_streamEnded;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s8, vertical: NileSpacing.s4),
                decoration: BoxDecoration(
                  color: inLobby ? NileColors.volt : NileColors.coral,
                  borderRadius: BorderRadius.circular(NileRadius.xs),
                ),
                child: Text(
                  inLobby ? 'SOUND CHECK' : 'LIVE',
                  style: NileTextStyles.caption().copyWith(
                    color: inLobby ? NileColors.onVolt : Colors.white,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 10),
          // Viewer count
          Icon(Icons.visibility, size: 14, color: NileColors.txtTertiary),
          const SizedBox(width: 4),
          NileRollingNumber(
            value: _viewerCount,
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
          const Spacer(),
          // Chat toggle (hidden in the Lobby — no live chat before the show)
          if (_eventStatus != 'soundcheck' && !_streamEnded)
            Stack(
              clipBehavior: Clip.none,
              children: [
                IconButton(
                  icon: Icon(
                    _chatOpen ? Icons.chat_bubble : Icons.chat_bubble_outline,
                  ),
                  color: _chatOpen ? NileColors.volt : NileColors.txtSecondary,
                  iconSize: 20,
                  onPressed: _toggleChat,
                ),
                if (_hasUnreadChat && !_chatOpen)
                  const Positioned(
                    top: 8,
                    right: 8,
                    child: CircleAvatar(
                      radius: 4,
                      backgroundColor: NileColors.coral,
                    ),
                  ),
              ],
            ),
          // Leave button
          TextButton(
            onPressed: _leave,
            child: Text(
              'Leave',
              style: NileTextStyles.bodyMd().copyWith(color: NileColors.error),
            ),
          ),
        ],
      ),
    );
  }

  // ── Chat overlay ──────────────────────────────────────────────────────────

  Widget _buildChatOverlay() {
    final media = MediaQuery.of(context);
    // Panel covers the lower ~42% of the screen; slides fully off-screen when
    // collapsed so it never blocks the video.
    final panelHeight = media.size.height * 0.42;
    // On desktop/web (width > 600) pin the panel to the right at 25% width.
    final isWide = kIsWeb || media.size.width > 600;
    final panelWidth = isWide ? media.size.width * 0.25 : null;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      left: isWide ? null : 0,
      right: 0,
      bottom: _chatOpen ? 0 : -panelHeight,
      height: panelHeight,
      width: panelWidth,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              NileColors.bgPage.withValues(alpha: 0.0),
              NileColors.bgPage.withValues(alpha: 0.75),
              NileColors.bgPage.withValues(alpha: 0.92),
            ],
            stops: const [0.0, 0.35, 1.0],
          ),
        ),
        child: Column(
          children: [
            Expanded(child: _buildChatList()),
            _buildChatInput(media.padding.bottom),
          ],
        ),
      ),
    );
  }

  Widget _buildChatList() {
    if (_chatMessages.isEmpty) {
      return Center(
        child: Text(
          'No messages yet. Say hi 👋',
          style: NileTextStyles.bodySm().copyWith(
            color: NileColors.txtTertiary,
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _chatScrollController,
      padding: const EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s8, NileSpacing.s16, NileSpacing.s8),
      itemCount: _chatMessages.length,
      itemBuilder: (context, i) {
        final m = _chatMessages[i];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: NileSpacing.s2),
          child: RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: '${m.username}  ',
                  style: NileTextStyles.bodySm().copyWith(
                    color: m.isMine ? NileColors.volt : NileColors.azure,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                TextSpan(text: m.content, style: NileTextStyles.bodyMd()),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildChatInput(double bottomInset) {
    return Padding(
      padding: EdgeInsets.fromLTRB(NileSpacing.s12, NileSpacing.s8, NileSpacing.s12, NileSpacing.s8 + bottomInset),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _chatController,
              style: NileTextStyles.bodyMd(),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendChat(),
              maxLength: 250,
              buildCounter:
                  (
                    _, {
                    required currentLength,
                    required isFocused,
                    maxLength,
                  }) => null,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Chat…',
                fillColor: NileColors.bgRaised,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: NileSpacing.s12,
                  vertical: NileSpacing.s8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(NileRadius.pill),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(NileRadius.pill),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.send),
            color: NileColors.volt,
            onPressed: _sendChat,
          ),
        ],
      ),
    );
  }

  // ── Audio bar ─────────────────────────────────────────────────────────────

  Widget _buildAudioBar() {
    final hasAudio = _masterAudioIdentity != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16, vertical: NileSpacing.s8),
      color: NileColors.bgSurface,
      child: Row(
        children: [
          Icon(
            _isStreamAudioSource() ? Icons.tune : Icons.album,
            size: 16,
            color: hasAudio ? NileColors.volt : NileColors.txtTertiary,
          ),
          const SizedBox(width: 6),
          Text(
            _masterAudioIdentity == null
                ? 'No master audio'
                : _isStreamAudioSource()
                ? 'Stream Audio'
                : 'Master: ${_masterAudioName()}',
            style: NileTextStyles.bodySm().copyWith(
              color: hasAudio ? NileColors.volt : NileColors.txtTertiary,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(_audioEnabled ? Icons.volume_up : Icons.volume_off),
            color: _audioEnabled
                ? NileColors.txtPrimary
                : NileColors.txtTertiary,
            iconSize: 20,
            onPressed: () {
              setState(() => _audioEnabled = !_audioEnabled);
              _updateAudioRouting();
            },
          ),
        ],
      ),
    );
  }

  // ── Layouts ───────────────────────────────────────────────────────────────

  Widget _buildPortraitLayout() {
    return Column(
      children: [
        Expanded(child: _buildMainCamera()),
        if (_cameras.length > 1) _buildHorizontalThumbnails(),
      ],
    );
  }

  Widget _buildLandscapeLayout() {
    return Row(
      children: [
        Expanded(child: _buildMainCamera()),
        if (_cameras.length > 1) _buildVerticalThumbnails(),
      ],
    );
  }

  Widget _buildMainCamera() {
    final focused = _cameras[_focusedIndex.clamp(0, _cameras.length - 1)];
    return Stack(
      fit: StackFit.expand,
      children: [
        focused.track != null
            ? VideoTrackRenderer(focused.track!)
            : _buildCameraOffPlaceholder(large: true),
        if (focused.identity == _masterAudioIdentity)
          Positioned(
            top: 12,
            right: 12,
            child: Icon(Icons.album, color: NileColors.volt, size: 18),
          ),
        Positioned(
          bottom: 12,
          left: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s8, vertical: NileSpacing.s4),
            decoration: BoxDecoration(
              color: NileColors.bgPage.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(NileRadius.sm),
            ),
            child: Text(focused.cameraName, style: NileTextStyles.bodyMd()),
          ),
        ),
      ],
    );
  }

  Widget _buildHorizontalThumbnails() {
    return Container(
      height: 100,
      color: NileColors.bgPage,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(NileSpacing.s8),
        itemCount: _cameras.length,
        itemBuilder: (context, index) => _buildThumbnailItem(
          index: index,
          width: 140,
          height: double.infinity,
          margin: const EdgeInsets.only(right: NileSpacing.s8),
        ),
      ),
    );
  }

  Widget _buildVerticalThumbnails() {
    return Container(
      width: 110,
      color: NileColors.bgPage,
      child: ListView.builder(
        scrollDirection: Axis.vertical,
        padding: const EdgeInsets.all(NileSpacing.s6),
        itemCount: _cameras.length,
        itemBuilder: (context, index) => _buildThumbnailItem(
          index: index,
          width: double.infinity,
          height: 80,
          margin: const EdgeInsets.only(bottom: NileSpacing.s8),
        ),
      ),
    );
  }

  Widget _buildThumbnailItem({
    required int index,
    required double width,
    required double height,
    required EdgeInsets margin,
  }) {
    final camera = _cameras[index];
    final isFocused = index == _focusedIndex;
    final isMasterAudio = camera.identity == _masterAudioIdentity;

    return GestureDetector(
      onTap: () {
        setState(() => _focusedIndex = index);
        _updateAudioRouting();
      },
      child: Container(
        width: width,
        height: height,
        margin: margin,
        decoration: BoxDecoration(
          border: Border.all(
            color: isFocused ? NileColors.volt : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(NileRadius.sm),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(NileRadius.sm - 2),
          child: Stack(
            fit: StackFit.expand,
            children: [
              camera.track != null
                  ? VideoTrackRenderer(camera.track!)
                  : _buildCameraOffPlaceholder(large: false),
              if (isMasterAudio)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Icon(Icons.album, color: NileColors.volt, size: 14),
                ),
              Positioned(
                bottom: 4,
                left: 4,
                right: 4,
                child: Text(
                  camera.cameraName,
                  style: NileTextStyles.caption().copyWith(
                    color: NileColors.txtPrimary,
                    shadows: const [Shadow(blurRadius: 4)],
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Stream ended overlay ──────────────────────────────────────────────────

  Widget _buildStreamEndedOverlay() {
    return Container(
      color: Colors.black87,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.stop_circle_outlined,
              size: 72,
              color: NileColors.txtTertiary,
            ),
            const SizedBox(height: 20),
            Text('Stream Ended', style: NileTextStyles.headingLg()),
            const SizedBox(height: 8),
            Text(
              'The host has ended the stream.',
              style: NileTextStyles.bodyMd().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
            const SizedBox(height: 36),
            FilledButton(
              onPressed: _leave,
              style: FilledButton.styleFrom(
                backgroundColor: NileColors.volt,
                foregroundColor: NileColors.onVolt,
                padding: const EdgeInsets.symmetric(
                  horizontal: NileSpacing.s40,
                  vertical: NileSpacing.s16,
                ),
                textStyle: NileTextStyles.labelLg(),
                shape: const StadiumBorder(),
              ),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}
