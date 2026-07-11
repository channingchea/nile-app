import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import '../services/livekit_service.dart';
import '../theme.dart';
import 'audio_meter.dart';

/// Host Sound Check "View as Viewer" overlay.
///
/// Opens a *second* LiveKit connection using the viewer token so the host hears
/// and sees exactly what a viewer receives — the whole point is verifying the
/// Master/Stream Audio path (mixer → operator device → encode → LiveKit →
/// decode) before going live, which a local mic meter can't confirm.
///
/// Audio-forward: subscribes to the broadcast audio source and surfaces its
/// level on a prominent [AudioMeter] with the decoded audio playing for
/// headphone monitoring; video renders secondary. It deliberately subscribes to
/// audio while the event is still `soundcheck` — the public viewer screen parks
/// real viewers in a Lobby until `live`, but this private host preview bypasses
/// that so audio can be checked pre-live.
///
/// The host's own publishing mic is muted by the caller for the overlay's
/// lifetime (feedback guard); this widget only owns the viewer connection.
class ViewerPreviewOverlay extends StatefulWidget {
  /// LiveKit slug for the event (events.livekit_room) — same value the camera
  /// screen connects with.
  final String eventId;

  /// Dismiss the overlay and return to the host view.
  final VoidCallback onClose;

  const ViewerPreviewOverlay({
    super.key,
    required this.eventId,
    required this.onClose,
  });

  @override
  State<ViewerPreviewOverlay> createState() => _ViewerPreviewOverlayState();
}

enum _PreviewState { connecting, ready, error }

class _ViewerPreviewOverlayState extends State<ViewerPreviewOverlay> {
  Room? _room;
  EventsListener<RoomEvent>? _listener;
  _PreviewState _state = _PreviewState.connecting;
  String? _errorMessage;

  // The broadcast audio source we monitor (Stream Audio operator, else the
  // master-audio camera). Its `audioLevel` drives the meter; its video, if any,
  // is the secondary preview.
  RemoteParticipant? _audioParticipant;
  VideoTrack? _videoTrack;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _listener?.dispose();
    _room?.disconnect();
    super.dispose();
  }

  Future<void> _connect() async {
    Room? room;
    try {
      final conn = await LivekitService.viewerToken(eventId: widget.eventId);
      if (conn.mode != 'webrtc') {
        throw Exception('Unsupported stream mode: ${conn.mode}');
      }

      room = Room();
      final listener = room.createListener();
      listener
        ..on<TrackSubscribedEvent>((_) => _resync())
        ..on<TrackUnsubscribedEvent>((_) => _resync())
        ..on<TrackMutedEvent>((_) => _resync())
        ..on<TrackUnmutedEvent>((_) => _resync())
        ..on<ParticipantConnectedEvent>((_) => _resync())
        ..on<ParticipantDisconnectedEvent>((_) => _resync())
        ..on<ParticipantMetadataUpdatedEvent>((_) => _resync());

      await room
          .connect(conn.wsUrl, conn.token)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () =>
                throw Exception('Connection timed out. Try again.'),
          );

      // Subscribe to every remote audio/video track regardless of event status
      // (this is the deliberate soundcheck Lobby bypass for the host preview).
      for (final p in room.remoteParticipants.values) {
        for (final pub in p.audioTrackPublications) {
          pub.subscribe();
        }
        for (final pub in p.videoTrackPublications) {
          pub.subscribe();
        }
      }

      if (!mounted) {
        await room.disconnect();
        return;
      }
      setState(() {
        _room = room;
        _listener = listener;
        _state = _PreviewState.ready;
      });
      _resync();
    } catch (e) {
      await room?.disconnect();
      if (!mounted) return;
      setState(() {
        _state = _PreviewState.error;
        _errorMessage = e.toString();
      });
    }
  }

  /// Pick the broadcast audio source (Stream Audio operator wins; else the
  /// master-audio camera) and the video track to show, then repaint.
  void _resync() {
    final room = _room;
    if (room == null || !mounted) return;

    RemoteParticipant? audioP = _findByRole(room, 'master-audio');
    audioP ??= _findMasterAudioCamera(room);

    // Secondary video: prefer the audio source's own video if it has one,
    // otherwise any available camera feed.
    VideoTrack? video = _firstVideo(audioP);
    if (video == null) {
      for (final p in room.remoteParticipants.values) {
        video = _firstVideo(p);
        if (video != null) break;
      }
    }

    setState(() {
      _audioParticipant = audioP;
      _videoTrack = video;
    });
  }

  RemoteParticipant? _findByRole(Room room, String role) {
    for (final p in room.remoteParticipants.values) {
      if (_metaRole(p) == role) return p;
    }
    return null;
  }

  RemoteParticipant? _findMasterAudioCamera(Room room) {
    for (final p in room.remoteParticipants.values) {
      try {
        final meta = jsonDecode(p.metadata ?? '{}');
        if (meta['role'] == 'camera' && meta['isMasterAudio'] == true) return p;
      } catch (_) {}
    }
    return null;
  }

  String? _metaRole(Participant p) {
    try {
      return jsonDecode(p.metadata ?? '{}')['role'] as String?;
    } catch (_) {
      return null;
    }
  }

  VideoTrack? _firstVideo(RemoteParticipant? p) {
    if (p == null) return null;
    for (final pub in p.videoTrackPublications) {
      // A muted publication is still "subscribed" but delivers black frames —
      // skip it so _resync falls through to a camera that's actually sending.
      // Also skip screen shares: this preview shows "the camera", and a
      // participant may be publishing both.
      if (pub.subscribed &&
          !pub.muted &&
          pub.source != TrackSource.screenShareVideo &&
          pub.track is VideoTrack) {
        return pub.track as VideoTrack;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: NileColors.bgPage,
      child: SafeArea(
        child: NileMaxWidth(
          child: Padding(
            padding: const EdgeInsets.all(NileSpacing.s24),
            child: switch (_state) {
              _PreviewState.connecting => _buildConnecting(),
              _PreviewState.error => _buildError(),
              _PreviewState.ready => _buildReady(),
            },
          ),
        ),
      ),
    );
  }

  Widget _buildConnecting() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        CircularProgressIndicator(color: NileColors.volt),
        const SizedBox(height: NileSpacing.s16),
        Text('Connecting as viewer…', style: NileTextStyles.bodyMd()),
      ],
    );
  }

  Widget _buildError() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.error_outline, color: NileColors.error, size: 48),
        const SizedBox(height: NileSpacing.s16),
        Text(
          'Couldn\'t open viewer preview',
          style: NileTextStyles.headingMd(),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: NileSpacing.s8),
        Text(
          _errorMessage ?? 'Unknown error.',
          style: NileTextStyles.bodySm().copyWith(
            color: NileColors.txtSecondary,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: NileSpacing.s24),
        _backButton(),
      ],
    );
  }

  Widget _buildReady() {
    final hasAudio = _audioParticipant != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: NileSpacing.s8,
                vertical: NileSpacing.s4,
              ),
              decoration: BoxDecoration(
                color: NileColors.volt,
                borderRadius: BorderRadius.circular(NileRadius.pill),
              ),
              child: Text(
                'VIEWER PREVIEW',
                style: NileTextStyles.labelSm().copyWith(
                  color: NileColors.onVolt,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: NileSpacing.s8),
        Text(
          'Hearing the stream as a viewer',
          style: NileTextStyles.headingLg(),
        ),
        const SizedBox(height: NileSpacing.s4),
        Text(
          'Your mic is muted while you monitor. Use headphones to avoid feedback.',
          style: NileTextStyles.bodySm().copyWith(
            color: NileColors.txtSecondary,
          ),
        ),
        const SizedBox(height: NileSpacing.s24),
        // ── Audio-forward: the meter is the hero element ─────────────────
        // FittedBox scales the fixed-height meter down instead of overflowing
        // when the window is short (macOS resize / small screens).
        Expanded(
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: hasAudio
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AudioMeter(
                          participant: _audioParticipant!,
                          height: 220,
                          active: true,
                        ),
                        const SizedBox(height: NileSpacing.s12),
                        Text(
                          'STREAM AUDIO',
                          style: NileTextStyles.labelSm().copyWith(
                            color: NileColors.volt,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.graphic_eq,
                          size: 48,
                          color: NileColors.txtTertiary,
                        ),
                        const SizedBox(height: NileSpacing.s12),
                        Text(
                          'No stream audio yet',
                          style: NileTextStyles.bodyMd().copyWith(
                            color: NileColors.txtSecondary,
                          ),
                        ),
                        const SizedBox(height: NileSpacing.s4),
                        Text(
                          'Waiting for the Stream Audio operator to start.',
                          style: NileTextStyles.bodySm().copyWith(
                            color: NileColors.txtTertiary,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
            ),
          ),
        ),
        // ── Secondary video preview ──────────────────────────────────────
        if (_videoTrack != null) ...[
          const SizedBox(height: NileSpacing.s16),
          ClipRRect(
            borderRadius: BorderRadius.circular(NileRadius.md),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              // Keyed by track sid so Flutter tears down and re-attaches the
              // platform view when the track changes (a reused renderer can
              // keep painting black after a swap).
              child: VideoTrackRenderer(
                key: ValueKey(_videoTrack!.sid),
                _videoTrack!,
              ),
            ),
          ),
        ],
        const SizedBox(height: NileSpacing.s24),
        _backButton(),
      ],
    );
  }

  Widget _backButton() {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: widget.onClose,
        icon: const Icon(Icons.arrow_back),
        label: const Text('Back to Host View'),
        style: FilledButton.styleFrom(
          backgroundColor: NileColors.volt,
          foregroundColor: NileColors.onVolt,
          padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
          textStyle: NileTextStyles.labelLg(),
          shape: const StadiumBorder(),
        ),
      ),
    );
  }
}
