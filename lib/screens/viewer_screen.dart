import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';
import '../config.dart';

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
  final VideoTrack? track; // null when the camera operator has disabled video

  CameraFeed({
    required this.identity,
    required this.cameraName,
    this.track,
  });
}

class _ViewerScreenState extends State<ViewerScreen> {
  final _eventIdController = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.initialEventId != null) {
      _eventIdController.text = widget.initialEventId!;
    }
  }

  ViewerState _state = ViewerState.idle;
  Room? _room;
  EventsListener<RoomEvent>? _listener;
  final List<CameraFeed> _cameras = [];
  int _focusedIndex = 0;
  String? _errorMessage;

  // Audio management
  final Map<String, RemoteTrackPublication> _audioPublications = {};
  bool _audioEnabled = true;           // viewer's master mute toggle
  String? _masterAudioIdentity;        // identity of whoever is master audio

  @override
  void dispose() {
    _eventIdController.dispose();
    _listener?.dispose();
    _room?.disconnect();
    super.dispose();
  }

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

    try {
      final response = await http.post(
        Uri.parse('$backendUrl/api/viewer-token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'eventId': eventId,
          'viewerId': DateTime.now().millisecondsSinceEpoch.toString(),
        }),
      );

      if (response.statusCode != 200) {
        throw Exception('Server returned ${response.statusCode}');
      }

      final data = jsonDecode(response.body);
      final token = data['token'] as String;
      final wsUrl = data['wsUrl'] as String;

      final room = Room();
      final listener = room.createListener();

      listener
        ..on<TrackSubscribedEvent>(_onTrackSubscribed)
        ..on<TrackUnsubscribedEvent>(_onTrackUnsubscribed)
        ..on<ParticipantConnectedEvent>(_onParticipantConnected)
        ..on<ParticipantDisconnectedEvent>(_onParticipantDisconnected)
        ..on<ParticipantMetadataUpdatedEvent>(_onParticipantMetadataUpdated);

      await room.connect(wsUrl, token);

      // Handle participants already in the room when we join
      for (final participant in room.remoteParticipants.values) {
        for (final publication in participant.videoTrackPublications) {
          if (publication.subscribed &&
              publication.track != null &&
              publication.source == TrackSource.camera) {
            _addCamera(participant, publication.track as VideoTrack);
          }
        }
        for (final publication in participant.audioTrackPublications) {
          if (publication.subscribed && publication.track != null) {
            _storeAudioPublication(participant, publication);
          }
        }
      }

      setState(() {
        _room = room;
        _listener = listener;
        _masterAudioIdentity = _findMasterAudioIdentity(room);
        _state = ViewerState.watching;
      });

      _updateAudioRouting();
    } catch (e) {
      setState(() {
        _state = ViewerState.idle;
        _errorMessage = 'Failed to connect: ${e.toString()}';
      });
    }
  }

  // ── Event handlers ────────────────────────────────────────────────────

  void _onTrackSubscribed(TrackSubscribedEvent event) {
    if (event.track is VideoTrack &&
        event.publication.source == TrackSource.camera) {
      // If camera already in list (re-enabling video), update its track
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
      // Keep the camera slot visible but mark video as off
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

    // Re-detect master audio in case it was this participant
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

  // ── Audio management ──────────────────────────────────────────────────

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

  /// Scans room participants to find who is currently master audio.
  /// Standalone 'master-audio' role takes priority over camera isMasterAudio flag.
  String? _findMasterAudioIdentity(Room? room) {
    if (room == null) return null;

    // Priority 1: standalone master-audio device
    for (final p in room.remoteParticipants.values) {
      try {
        final meta = jsonDecode(p.metadata ?? '{}');
        if (meta['role'] == 'master-audio') return p.identity;
      } catch (_) {}
    }

    // Priority 2: camera with isMasterAudio: true
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

  /// Routes audio to master audio source. Falls back to focused camera
  /// if no master audio is designated. Honours the viewer's mute toggle.
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

  /// Returns true when the master audio source is a standalone Stream Audio
  /// device (role: 'master-audio') rather than a camera.
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

  // ── Camera helpers ────────────────────────────────────────────────────

  void _addCamera(RemoteParticipant participant, VideoTrack track) {
    try {
      final meta = jsonDecode(participant.metadata ?? '{}');
      if (meta['role'] != 'camera') return;
    } catch (_) {
      return;
    }

    // Guard against double-adds — one feed per participant identity
    if (_cameras.any((c) => c.identity == participant.identity)) return;

    String cameraName = participant.name ?? participant.identity;
    try {
      final meta = jsonDecode(participant.metadata ?? '{}');
      if (meta['cameraName'] != null) cameraName = meta['cameraName'];
    } catch (_) {}

    setState(() {
      _cameras.add(CameraFeed(
        identity: participant.identity,
        cameraName: cameraName,
        track: track,
      ));
    });

    _updateAudioRouting();
  }

  Future<void> _leave() async {
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
      _state = ViewerState.idle;
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Watch'),
        backgroundColor: Colors.transparent,
        actions: [
          if (_state == ViewerState.watching)
            TextButton(
              onPressed: _leave,
              child: const Text('Leave', style: TextStyle(color: Colors.red)),
            ),
        ],
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
          const Text(
            'Join a stream',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _eventIdController,
            decoration: const InputDecoration(
              labelText: 'Event ID',
              hintText: 'e.g. show-2024-01',
              border: OutlineInputBorder(),
            ),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
          ],
          const SizedBox(height: 32),
          FilledButton.icon(
            onPressed: _joinAsViewer,
            icon: const Icon(Icons.tv),
            label: const Text('Watch Now'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              textStyle: const TextStyle(fontSize: 18),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnecting() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Joining stream...'),
        ],
      ),
    );
  }

  Widget _buildCameraOffPlaceholder({required bool large}) {
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.videocam_off,
              size: large ? 48 : 24,
              color: Colors.white24,
            ),
            if (large) ...[
              const SizedBox(height: 8),
              const Text(
                'Camera Off',
                style: TextStyle(color: Colors.white38, fontSize: 14),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildWatching() {
    if (_cameras.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Waiting for cameras to connect...'),
          ],
        ),
      );
    }

    return OrientationBuilder(
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
    );
  }

  // ── Audio bar ─────────────────────────────────────────────────────────────

  Widget _buildAudioBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.black26,
      child: Row(
        children: [
          Icon(
            _isStreamAudioSource() ? Icons.tune : Icons.album,
            size: 16,
            color: _masterAudioIdentity != null
                ? Colors.greenAccent
                : Colors.white38,
          ),
          const SizedBox(width: 6),
          Text(
            _masterAudioIdentity == null
                ? 'No master audio'
                : _isStreamAudioSource()
                    ? 'Stream Audio'
                    : 'Master: ${_masterAudioName()}',
            style: TextStyle(
              color: _masterAudioIdentity != null
                  ? Colors.greenAccent
                  : Colors.white38,
              fontSize: 13,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(_audioEnabled ? Icons.volume_up : Icons.volume_off),
            color: _audioEnabled ? Colors.white : Colors.white38,
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

  // ── Portrait: main on top, thumbnail strip along the bottom ──────────────

  Widget _buildPortraitLayout() {
    return Column(
      children: [
        Expanded(child: _buildMainCamera()),
        if (_cameras.length > 1) _buildHorizontalThumbnails(),
      ],
    );
  }

  // ── Landscape: main on the left, thumbnail sidebar on the right ──────────

  Widget _buildLandscapeLayout() {
    return Row(
      children: [
        Expanded(child: _buildMainCamera()),
        if (_cameras.length > 1) _buildVerticalThumbnails(),
      ],
    );
  }

  // ── Main camera view ─────────────────────────────────────────────────────

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
            child: Icon(Icons.album, color: Colors.greenAccent, size: 18),
          ),
        Positioned(
          bottom: 12,
          left: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              focused.cameraName,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      ],
    );
  }

  // ── Thumbnail helpers ────────────────────────────────────────────────────

  Widget _buildHorizontalThumbnails() {
    return SizedBox(
      height: 100,
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
    return SizedBox(
      width: 110,
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
            color: isFocused ? Colors.blue : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
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
                  child: Icon(Icons.album, color: Colors.greenAccent, size: 14),
                ),
              Positioned(
                bottom: 4,
                left: 4,
                right: 4,
                child: Text(
                  camera.cameraName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    shadows: [Shadow(blurRadius: 4)],
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
}
