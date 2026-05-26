import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';
import 'package:flutter/foundation.dart';
import '../config.dart';

class CameraScreen extends StatefulWidget {
  final String? initialEventId;

  const CameraScreen({super.key, this.initialEventId});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

enum CameraState { idle, connecting, live }

class _CameraScreenState extends State<CameraScreen> {
  final _eventIdController = TextEditingController();
  final _cameraNameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.initialEventId != null) {
      _eventIdController.text = widget.initialEventId!;
    }
  }

  CameraState _state = CameraState.idle;
  Room? _room;
  EventsListener<RoomEvent>? _listener;
  VideoTrack? _localVideoTrack;
  String? _errorMessage;

  // Master audio state
  bool _isMasterAudio = false;
  bool _videoEnabled = true;
  bool _streamAudioActive = false; // true when a standalone Stream Audio device is in the room

  // Camera position (mobile only)
  bool _isFrontCamera = false; // default to back camera for camera operators

  // Stored for API calls
  String? _eventId;
  String? _cameraIdentity;

  @override
  void dispose() {
    _eventIdController.dispose();
    _cameraNameController.dispose();
    _listener?.dispose();
    _room?.disconnect();
    super.dispose();
  }

  Future<void> _goLive() async {
    final eventId = _eventIdController.text.trim();
    final cameraName = _cameraNameController.text.trim();

    if (eventId.isEmpty || cameraName.isEmpty) {
      setState(() => _errorMessage = 'Please fill in all fields.');
      return;
    }

    setState(() {
      _state = CameraState.connecting;
      _errorMessage = null;
    });

    try {
      final response = await http.post(
        Uri.parse('$backendUrl/api/camera-token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'eventId': eventId,
          'cameraId': DateTime.now().millisecondsSinceEpoch.toString(),
          'cameraName': cameraName,
        }),
      );

      if (response.statusCode != 200) {
        throw Exception('Server returned ${response.statusCode}');
      }

      final data = jsonDecode(response.body);
      final token = data['token'] as String;
      final wsUrl = data['wsUrl'] as String;
      final isMasterAudio = data['isMasterAudio'] == true;

      // Connect to the LiveKit room
      final room = Room();
      final listener = room.createListener();

      // Track our own master audio status via metadata updates
      listener.on<ParticipantMetadataUpdatedEvent>((event) {
        if (event.participant.identity == _room?.localParticipant?.identity) {
          try {
            final meta = jsonDecode(event.participant.metadata ?? '{}');
            setState(() => _isMasterAudio = meta['isMasterAudio'] == true);
          } catch (_) {}
        }
      });

      // Detect when a standalone Stream Audio device joins or leaves
      listener.on<ParticipantConnectedEvent>((event) {
        try {
          final meta = jsonDecode(event.participant.metadata ?? '{}');
          if (meta['role'] == 'master-audio') {
            setState(() => _streamAudioActive = true);
          }
        } catch (_) {}
      });

      listener.on<ParticipantDisconnectedEvent>((event) {
        try {
          final meta = jsonDecode(event.participant.metadata ?? '{}');
          if (meta['role'] == 'master-audio') {
            setState(() => _streamAudioActive = false);
          }
        } catch (_) {}
      });

      await room.connect(wsUrl, token);
      await room.localParticipant?.setCameraEnabled(
        true,
        cameraCaptureOptions: CameraCaptureOptions(
          cameraPosition: _isFrontCamera ? CameraPosition.front : CameraPosition.back,
        ),
      );
      await room.localParticipant?.setMicrophoneEnabled(true);

      final publication = room.localParticipant?.videoTrackPublications.firstOrNull;
      final track = publication?.track;

      // Check if a standalone Stream Audio device is already in the room
      final streamAudioActive = room.remoteParticipants.values.any((p) {
        try {
          return jsonDecode(p.metadata ?? '{}')['role'] == 'master-audio';
        } catch (_) {
          return false;
        }
      });

      setState(() {
        _room = room;
        _listener = listener;
        _localVideoTrack = track as VideoTrack?;
        _isMasterAudio = isMasterAudio;
        _videoEnabled = true;
        _streamAudioActive = streamAudioActive;
        _eventId = eventId;
        _cameraIdentity = room.localParticipant?.identity;
        _state = CameraState.live;
      });
    } catch (e) {
      setState(() {
        _state = CameraState.idle;
        _errorMessage = 'Failed to connect: ${e.toString()}';
      });
    }
  }

  Future<void> _claimMasterAudio() async {
    if (_eventId == null || _cameraIdentity == null) return;
    try {
      await http.post(
        Uri.parse('$backendUrl/api/set-master-audio'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'eventId': _eventId,
          'cameraIdentity': _cameraIdentity,
        }),
      );
      // State updates via ParticipantMetadataUpdatedEvent
    } catch (_) {}
  }

  Future<void> _toggleVideo() async {
    final newEnabled = !_videoEnabled;
    await _room?.localParticipant?.setCameraEnabled(
      newEnabled,
      cameraCaptureOptions: newEnabled
          ? CameraCaptureOptions(
              cameraPosition: _isFrontCamera ? CameraPosition.front : CameraPosition.back,
            )
          : null,
    );

    VideoTrack? newTrack;
    if (newEnabled) {
      final publication = _room?.localParticipant?.videoTrackPublications.firstOrNull;
      newTrack = publication?.track as VideoTrack?;
    }

    setState(() {
      _videoEnabled = newEnabled;
      _localVideoTrack = newTrack;
    });
  }

  Future<void> _switchCamera() async {
    if (_room == null) return;
    final newFront = !_isFrontCamera;
    try {
      await _room!.localParticipant?.setCameraEnabled(
        true,
        cameraCaptureOptions: CameraCaptureOptions(
          cameraPosition: newFront ? CameraPosition.front : CameraPosition.back,
        ),
      );
      final publication = _room!.localParticipant?.videoTrackPublications.firstOrNull;
      setState(() {
        _isFrontCamera = newFront;
        if (publication?.track != null) {
          _localVideoTrack = publication!.track as VideoTrack;
        }
      });
    } catch (_) {}
  }

  Future<void> _stopStreaming() async {
    await _listener?.dispose();
    await _room?.disconnect();
    setState(() {
      _room = null;
      _listener = null;
      _localVideoTrack = null;
      _isMasterAudio = false;
      _videoEnabled = true;
      _state = CameraState.idle;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Camera'),
        backgroundColor: Colors.transparent,
      ),
      body: switch (_state) {
        CameraState.idle => _buildForm(),
        CameraState.connecting => _buildConnecting(),
        CameraState.live => _buildLive(),
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
            'Set up your camera',
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
          const SizedBox(height: 16),
          TextField(
            controller: _cameraNameController,
            decoration: const InputDecoration(
              labelText: 'Camera Name',
              hintText: 'e.g. Stage Left Cam',
              border: OutlineInputBorder(),
            ),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
          ],
          const SizedBox(height: 32),
          FilledButton.icon(
            onPressed: _goLive,
            icon: const Icon(Icons.videocam),
            label: const Text('Go Live'),
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
          Text('Connecting...'),
        ],
      ),
    );
  }

  Widget _buildLive() {
    return Stack(
      children: [
        // ── Video preview or dark screen when video is off ──────────────
        if (_videoEnabled && _localVideoTrack != null)
          VideoTrackRenderer(
            _localVideoTrack!,
            mirrorMode: _isFrontCamera
                ? VideoViewMirrorMode.mirror
                : VideoViewMirrorMode.off,
          )
        else
          Container(
            color: Colors.black,
            child: const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.videocam_off, size: 64, color: Colors.white24),
                  SizedBox(height: 12),
                  Text('Video Off', style: TextStyle(color: Colors.white38)),
                ],
              ),
            ),
          ),

        // ── LIVE badge — top left ───────────────────────────────────────
        Positioned(
          top: 16,
          left: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.red,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, size: 8, color: Colors.white),
                SizedBox(width: 6),
                Text(
                  'LIVE',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ),

        // ── Master audio status — top right ────────────────────────────
        Positioned(
          top: 16,
          right: 16,
          child: _isMasterAudio
              ? _streamAudioActive
                  // This camera is designated master audio but Stream Audio has overridden it
                  ? Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.orange[800],
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.album, size: 14, color: Colors.white),
                          SizedBox(width: 6),
                          Text(
                            'STREAM AUDIO ACTIVE',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    )
                  // This camera is the active master audio source
                  : Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.album, size: 14, color: Colors.white),
                          SizedBox(width: 6),
                          Text(
                            'MASTER AUDIO',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    )
              : ElevatedButton.icon(
                  onPressed: _claimMasterAudio,
                  icon: const Icon(Icons.album, size: 16),
                  label: const Text('Set as Master Audio', style: TextStyle(fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black54,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
        ),

        // ── Bottom controls ─────────────────────────────────────────────
        Positioned(
          bottom: 32,
          left: 32,
          right: 32,
          child: Row(
            children: [
              // Flip camera — mobile only, video must be on
              if (!kIsWeb && _videoEnabled) ...[
                IconButton(
                  onPressed: _switchCamera,
                  icon: const Icon(Icons.flip_camera_ios),
                  color: Colors.white,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black54,
                    padding: const EdgeInsets.all(12),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              // Video toggle — only shown when this camera is master audio
              if (_isMasterAudio) ...[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _toggleVideo,
                    icon: Icon(_videoEnabled ? Icons.videocam_off : Icons.videocam),
                    label: Text(_videoEnabled ? 'Video Off' : 'Video On'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white54),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: FilledButton.icon(
                  onPressed: _stopStreaming,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop Streaming'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: const TextStyle(fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
