import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/event_service.dart';
import '../services/livekit_service.dart';
import '../theme.dart';

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

  // Phase 7: viewer count + realtime
  int _viewerCount = 0;
  String? _streamEventId; // liveKitEventId for cleanup
  bool _streamEnded = false;
  RealtimeChannel? _realtimeChannel;
  bool _hasIncrementedViewerCount = false;

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
    _listener?.dispose();
    _room?.disconnect();
    super.dispose();
  }

  void _decrementAndCleanup() {
    if (_hasIncrementedViewerCount && _streamEventId != null) {
      EventService.decrementViewerCount(_streamEventId!).catchError((_) {});
      _hasIncrementedViewerCount = false;
    }
    _realtimeChannel?.unsubscribe();
    _realtimeChannel = null;
  }

  // ── Realtime callback ─────────────────────────────────────────────────────

  void _onRealtimeUpdate(Map<String, dynamic> record) {
    if (!mounted) return;
    setState(() {
      if (record['viewer_count'] != null) {
        _viewerCount = record['viewer_count'] as int;
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
      await room.connect(wsUrl, token).timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw Exception('Connection timed out. Try again.'),
          );

      for (final participant in room.remoteParticipants.values) {
        for (final publication in participant.videoTrackPublications) {
          // Don't gate on TrackSource — it can still be `unknown` at this point.
          // _addCamera authoritatively checks the participant's role == 'camera'.
          if (publication.subscribed && publication.track != null) {
            _addCamera(participant, publication.track as VideoTrack);
          } else {
            // Not yet subscribed — pull it; the track arrives via
            // TrackSubscribedEvent. Covers autoSubscribe timing/off.
            publication.subscribe();
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

      final channel = EventService.subscribeToEvent(
        liveKitEventId: eventId,
        onUpdate: _onRealtimeUpdate,
      );

      setState(() {
        _room = room;
        _listener = listener;
        _masterAudioIdentity = _findMasterAudioIdentity(room);
        _streamEventId = eventId;
        _viewerCount = eventState?['viewer_count'] as int? ?? 0;
        _hasIncrementedViewerCount = true;
        _realtimeChannel = channel;
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
      final idx = _cameras.indexWhere((c) => c.identity == event.participant.identity);
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
      final idx = _cameras.indexWhere((c) => c.identity == event.participant.identity);
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
  }

  void _onParticipantMetadataUpdated(ParticipantMetadataUpdatedEvent event) {
    final newIdentity = _findMasterAudioIdentity(_room);
    if (newIdentity != _masterAudioIdentity) {
      setState(() => _masterAudioIdentity = newIdentity);
      _updateAudioRouting();
    }
  }

  void _onRoomDisconnected(RoomDisconnectedEvent event) {
    // LiveKit room dropped — treat as stream ended if we're still watching
    if (mounted && _state == ViewerState.watching && !_streamEnded) {
      setState(() => _streamEnded = true);
    }
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
    final target = _masterAudioIdentity ??
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

    final cameraName = (meta['cameraName'] as String?)
        ?? (participant.name.isNotEmpty ? participant.name : participant.identity);

    setState(() {
      _cameras.add(CameraFeed(
        identity: participant.identity,
        cameraName: cameraName,
        track: track,
      ));
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
      padding: const EdgeInsets.all(32.0),
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
              foregroundColor: NileColors.bgPage,
              padding: const EdgeInsets.symmetric(vertical: 16),
              textStyle: NileTextStyles.labelLg(),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(NileRadius.sm),
              ),
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
          const CircularProgressIndicator(color: NileColors.volt),
          const SizedBox(height: 16),
          Text('Joining stream...', style: NileTextStyles.bodyMd()),
        ],
      ),
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
                style: NileTextStyles.bodyMd().copyWith(color: NileColors.txtTertiary),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildWatching() {
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
                      const CircularProgressIndicator(color: NileColors.volt),
                      const SizedBox(height: 16),
                      Text(
                        'Waiting for cameras to connect...',
                        style: NileTextStyles.bodyMd()
                            .copyWith(color: NileColors.txtSecondary),
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

        // Stream ended overlay
        if (_streamEnded) _buildStreamEndedOverlay(),
      ],
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
          // LIVE badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: NileColors.coral,
              borderRadius: BorderRadius.circular(NileRadius.xs),
            ),
            child: Text(
              'LIVE',
              style: NileTextStyles.caption().copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Viewer count
          const Icon(Icons.visibility, size: 14, color: NileColors.txtTertiary),
          const SizedBox(width: 4),
          Text(
            '$_viewerCount',
            style: NileTextStyles.bodySm().copyWith(color: NileColors.txtSecondary),
          ),
          const Spacer(),
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

  // ── Audio bar ─────────────────────────────────────────────────────────────

  Widget _buildAudioBar() {
    final hasAudio = _masterAudioIdentity != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
            color: _audioEnabled ? NileColors.txtPrimary : NileColors.txtTertiary,
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
          const Positioned(
            top: 12,
            right: 12,
            child: Icon(Icons.album, color: NileColors.volt, size: 18),
          ),
        Positioned(
          bottom: 12,
          left: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
        padding: const EdgeInsets.all(8),
        itemCount: _cameras.length,
        itemBuilder: (context, index) => _buildThumbnailItem(
          index: index,
          width: 140,
          height: double.infinity,
          margin: const EdgeInsets.only(right: 8),
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
        padding: const EdgeInsets.all(6),
        itemCount: _cameras.length,
        itemBuilder: (context, index) => _buildThumbnailItem(
          index: index,
          width: double.infinity,
          height: 80,
          margin: const EdgeInsets.only(bottom: 6),
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
                const Positioned(
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
            const Icon(
              Icons.stop_circle_outlined,
              size: 72,
              color: NileColors.txtTertiary,
            ),
            const SizedBox(height: 20),
            Text('Stream Ended', style: NileTextStyles.headingLg()),
            const SizedBox(height: 8),
            Text(
              'The host has ended the stream.',
              style: NileTextStyles.bodyMd().copyWith(color: NileColors.txtSecondary),
            ),
            const SizedBox(height: 36),
            FilledButton(
              onPressed: _leave,
              style: FilledButton.styleFrom(
                backgroundColor: NileColors.volt,
                foregroundColor: NileColors.bgPage,
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
                textStyle: NileTextStyles.labelLg(),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(NileRadius.sm),
                ),
              ),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}
