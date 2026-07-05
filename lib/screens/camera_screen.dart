import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;
import '../services/supabase_client.dart';
import '../services/crew_service.dart';
import '../services/event_service.dart';
import '../services/livekit_service.dart';
import '../widgets/audio_meter.dart';
import '../widgets/viewer_preview_overlay.dart';
import '../theme.dart';

class CameraScreen extends StatefulWidget {
  final String? initialEventId;

  /// Pre-fills the camera name — used when an assigned operator enters an event
  /// so they auto-land on their designated camera slot.
  final String? initialCameraName;

  /// True when the signed-in user owns this event. The single gate for Start
  /// Show, End Stream, and the Sound Check crew status panel; non-hosts get a
  /// "Ready to Stream" toggle instead.
  final bool isHost;

  const CameraScreen({
    super.key,
    this.initialEventId,
    this.initialCameraName,
    this.isHost = false,
  });

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

enum CameraState { idle, connecting, soundCheck, live }

class _CameraScreenState extends State<CameraScreen> {
  final _eventIdController = TextEditingController();
  final _cameraNameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.initialEventId != null) {
      _eventIdController.text = widget.initialEventId!;
    }
    if (widget.initialCameraName != null) {
      _cameraNameController.text = widget.initialCameraName!;
    }
    _refreshMicDetection();
    _deviceChangeSub = Hardware.instance.onDeviceChange.stream.listen(
      (_) => _refreshMicDetection(),
    );
    // Launched from an event with a known camera slot: skip the manual Event
    // ID / Camera Name form and connect straight into sound check. The form
    // stays as a fallback only if a field is missing or the connect fails.
    if ((widget.initialEventId?.isNotEmpty ?? false) &&
        (widget.initialCameraName?.isNotEmpty ?? false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _state == CameraState.idle) _enterSoundCheck();
      });
    }
  }

  /// Inspect audio inputs; flag when a non-builtin mic is present so we can
  /// suggest external-mic mode. Detection is best-effort and varies by platform,
  /// so it only ever drives a suggestion — never forces the setting.
  Future<void> _refreshMicDetection() async {
    try {
      final devices = await Hardware.instance.enumerateDevices(
        type: 'audioinput',
      );
      final hasExternal = devices.any((d) {
        final label = d.label.toLowerCase();
        // Built-in mics report as "built-in"/"default"/"iphone"/"android" etc.
        // Anything else is almost certainly an attached USB-C or wireless mic.
        return label.isNotEmpty &&
            !label.contains('built-in') &&
            !label.contains('builtin') &&
            !label.contains('default') &&
            !label.contains('internal') &&
            !label.contains('iphone') &&
            !label.contains('ipad') &&
            !label.contains('android') &&
            !label.contains('phone');
      });
      if (!mounted) return;
      if (hasExternal != _externalMicConnected) {
        setState(() {
          _externalMicConnected = hasExternal;
          if (!hasExternal) _externalMicPromptDismissed = false;
        });
      }
    } catch (_) {
      // Enumeration unsupported/empty on this platform — silently skip.
    }
  }

  /// This camera is the broadcast audio source only when it holds the
  /// master-audio flag AND no dedicated Stream Audio operator is publishing.
  /// A live Stream Audio feed always wins, so every camera mutes in its favour.
  bool get _isMainAudioSource => _isMasterAudio && !_streamAudioActive;

  /// (Re)publish the local mic to match [_disableAgc]. When off, uses the default
  /// mic path (WebRTC AGC/denoise/echo-cancel on). When on, publishes a track
  /// with that processing disabled so an external mic's own tuning passes
  /// through. Called at connect and whenever the setting changes mid-session;
  /// the unpublish→publish swap causes a brief (sub-second) audio gap.
  ///
  /// After (re)publishing we immediately reconcile the mute state so a camera
  /// that isn't the main audio source never broadcasts — this is what stops the
  /// feedback from multiple open mics in the room.
  Future<void> _applyMicProcessing(LocalParticipant? participant) async {
    if (participant == null) return;

    // Drop any current mic publication first.
    final existing = participant.audioTrackPublications.firstOrNull;
    if (existing != null) {
      await participant.removePublishedTrack(existing.sid);
    }

    if (_disableAgc) {
      final audioTrack = await LocalAudioTrack.create(
        const AudioCaptureOptions(
          autoGainControl: false,
          noiseSuppression: false,
          echoCancellation: false,
        ),
      );
      await participant.publishAudioTrack(audioTrack);
    } else {
      await participant.setMicrophoneEnabled(true);
    }
    await _syncMicEnabled();
  }

  /// Mute every camera that isn't the active broadcast audio source; unmute the
  /// one that is. The capture track keeps running either way (so the local meter
  /// still moves), but a muted track sends silence — only the main source's
  /// audio reaches viewers, which kills the multi-mic feedback. Called on
  /// connect and whenever the source reassigns (metadata / participant changes).
  Future<void> _syncMicEnabled() async {
    final pub = _room?.localParticipant?.audioTrackPublications.firstOrNull;
    final track = pub?.track;
    if (track == null) return;
    try {
      // While the host monitors the viewer preview, their own mic stays muted
      // regardless of the broadcast rule — otherwise a host who IS the audio
      // source would feed their decoded monitor back into the stream.
      if (_isMainAudioSource && !_viewerPreviewOpen) {
        await track.unmute();
      } else {
        await track.mute();
      }
    } catch (_) {
      // Mute/unmute can race a republish; the next sync call will settle it.
    }
  }

  /// Host taps "View as Viewer": mute the host's own publishing mic (feedback
  /// guard, covers the host-is-source case too) then open the viewer preview
  /// overlay over the camera screen, which keeps publishing underneath.
  Future<void> _openViewerPreview() async {
    setState(() => _viewerPreviewOpen = true);
    await _syncMicEnabled();
  }

  /// Dismiss the viewer preview and restore the mic to the state the broadcast
  /// rule dictates (active-source → unmuted, otherwise muted).
  Future<void> _closeViewerPreview() async {
    setState(() => _viewerPreviewOpen = false);
    await _syncMicEnabled();
  }

  /// Update the external-mic setting. If a session is live, republish the mic
  /// immediately so the change takes effect now; otherwise it applies at the
  /// next connect. [onDone] lets a modal refresh its own local state.
  Future<void> _setExternalMicMode(bool enabled, {VoidCallback? onDone}) async {
    if (_switchingMic) return;
    setState(() {
      _disableAgc = enabled;
      _externalMicPromptDismissed = true;
    });
    onDone?.call();

    if (_state == CameraState.idle || _room?.localParticipant == null) return;
    setState(() => _switchingMic = true);
    try {
      await _applyMicProcessing(_room!.localParticipant);
    } catch (_) {
      // Swap failed — leave the (now-unpublished) mic; operator can retry.
    } finally {
      if (mounted) setState(() => _switchingMic = false);
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
  bool _streamAudioActive = false;

  // Camera position (mobile only)
  bool _isFrontCamera = false;

  // Disable WebRTC AGC/denoise/echo-cancel for this camera's mic. Default off —
  // matches prior behavior. Turning it on lets a third-party mic's own
  // processing pass through untouched (see settings modal).
  bool _disableAgc = false;

  // External-mic detection. We watch the input devices and, when a non-builtin
  // mic appears, suggest (not force) external-mic mode.
  StreamSubscription? _deviceChangeSub;
  bool _externalMicConnected = false;
  bool _externalMicPromptDismissed = false;
  bool _switchingMic = false;

  // Stored for API calls
  String? _eventId;
  String? _cameraIdentity;

  // Sound Check readiness. Non-host: my own "Ready to Stream" toggle.
  // Host: assigned crew roster + per-user ready flags (keyed by the userId
  // stamped into each publisher's token metadata).
  bool _ready = false;
  List<AssignedOperator> _crew = const [];
  final Map<String, bool> _crewReady = {};

  // Non-host: true when this operator (re)joined while the show was already
  // live (e.g. after a drop). The auto soundcheck→live flip is suppressed and
  // they rejoin the show by pressing "Ready to Stream" instead.
  bool _joinedLiveShow = false;

  // Non-host: the host starts/ends the show, so this screen follows the DB
  // status (the single source of truth) via realtime.
  RealtimeChannel? _statusChannel;

  // Host Sound Check: "View as Viewer" overlay is open. The host's publishing
  // mic is force-muted for its lifetime (feedback guard) and restored on close.
  bool _viewerPreviewOpen = false;

  @override
  void dispose() {
    // A drop or back-swipe never ends a live show anymore — the show stays
    // 'live' and viewers' resilience logic treats it as reconnect-and-wait.
    // Ending only ever happens via the explicit End Stream confirm path.
    // The HOST leaving during Sound Check (show never started) still reverts
    // the event to scheduled; an operator leaving must not.
    if (_eventId != null && widget.isHost && _state == CameraState.soundCheck) {
      EventService.revertToScheduled(_eventId!).catchError((_) {});
    }
    _statusChannel?.unsubscribe();
    _deviceChangeSub?.cancel();
    _eventIdController.dispose();
    _cameraNameController.dispose();
    _listener?.dispose();
    _room?.disconnect();
    super.dispose();
  }

  /// Connect the camera/mic and enter Sound Check — the host/operator can now
  /// test devices, but viewers stay in the Lobby until [_startShow] is pressed.
  Future<void> _enterSoundCheck() async {
    final eventId = _eventIdController.text.trim();
    final cameraName = _cameraNameController.text.trim();

    if (eventId.isEmpty || cameraName.isEmpty) {
      setState(() => _errorMessage = 'Please fill in all fields.');
      return;
    }

    // Sound check opens 15 minutes before the scheduled start. Only gate an
    // event that hasn't begun (still 'scheduled'); a host re-entering one that's
    // already soundcheck/live isn't blocked. Unknown scheduled_at → allow.
    try {
      final state = await EventService.fetchEventState(eventId);
      final schedRaw = state?['scheduled_at'] as String?;
      if (state?['status'] == 'scheduled' && schedRaw != null) {
        final opensAt = DateTime.parse(
          schedRaw,
        ).subtract(const Duration(minutes: 15));
        if (DateTime.now().isBefore(opensAt)) {
          final mins = opensAt.difference(DateTime.now()).inMinutes + 1;
          setState(
            () => _errorMessage =
                'Sound check opens 15 minutes before showtime. Try again in '
                '$mins min.',
          );
          return;
        }
      }
    } catch (_) {
      // Best-effort gate — a lookup failure shouldn't block the host.
    }

    setState(() {
      _state = CameraState.connecting;
      _errorMessage = null;
    });

    Room? room;
    try {
      final conn = await LivekitService.cameraToken(
        eventId: eventId,
        cameraId: DateTime.now().millisecondsSinceEpoch.toString(),
        cameraName: cameraName,
      );
      final token = conn.token;
      final wsUrl = conn.wsUrl;
      final isMasterAudio = conn.isMasterAudio;

      // Tear down any prior room first — a lingering connection holds the
      // camera/mic and makes the next connect hang.
      await _room?.disconnect();
      _room = null;

      room = Room();
      final listener = room.createListener();

      listener.on<ParticipantMetadataUpdatedEvent>((event) {
        try {
          final meta = jsonDecode(event.participant.metadata ?? '{}');
          setState(() {
            if (event.participant.identity ==
                _room?.localParticipant?.identity) {
              _isMasterAudio = meta['isMasterAudio'] == true;
            }
            _applyReadyMeta(meta);
          });
          // The master-audio flag may have moved to/from this camera.
          _syncMicEnabled();
        } catch (_) {}
      });

      listener.on<ParticipantConnectedEvent>((event) {
        try {
          final meta = jsonDecode(event.participant.metadata ?? '{}');
          setState(() {
            if (meta['role'] == 'master-audio') _streamAudioActive = true;
            _applyReadyMeta(meta);
          });
          // A Stream Audio device joining makes it the source — mute cameras.
          if (meta['role'] == 'master-audio') _syncMicEnabled();
        } catch (_) {}
      });

      listener.on<ParticipantDisconnectedEvent>((event) {
        try {
          final meta = jsonDecode(event.participant.metadata ?? '{}');
          setState(() {
            if (meta['role'] == 'master-audio') _streamAudioActive = false;
            // A dropped crew member is no longer ready — a fresh token on
            // rejoin re-stamps ready: false server-side anyway.
            final userId = meta['userId'] as String?;
            if (userId != null) _crewReady[userId] = false;
          });
          // Stream Audio left — a master-audio camera may now be the source.
          if (meta['role'] == 'master-audio') _syncMicEnabled();
        } catch (_) {}
      });

      // Fail loudly instead of hanging on "Connecting…" forever if the WebRTC
      // connection or camera/mic acquisition stalls.
      await room
          .connect(wsUrl, token)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () =>
                throw Exception('Connection timed out. Try again.'),
          );
      await room.localParticipant
          ?.setCameraEnabled(
            true,
            cameraCaptureOptions: CameraCaptureOptions(
              cameraPosition: _isFrontCamera
                  ? CameraPosition.front
                  : CameraPosition.back,
            ),
          )
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () =>
                throw Exception('Camera timed out. Check camera permissions.'),
          );
      await _applyMicProcessing(room.localParticipant);

      final publication =
          room.localParticipant?.videoTrackPublications.firstOrNull;
      final track = publication?.track;

      var streamAudioActive = false;
      _crewReady.clear();
      for (final p in room.remoteParticipants.values) {
        try {
          final meta = jsonDecode(p.metadata ?? '{}');
          if (meta['role'] == 'master-audio') streamAudioActive = true;
          _applyReadyMeta(meta);
        } catch (_) {}
      }

      setState(() {
        _room = room;
        _listener = listener;
        _localVideoTrack = track as VideoTrack?;
        _isMasterAudio = isMasterAudio;
        _videoEnabled = true;
        _streamAudioActive = streamAudioActive;
        _eventId = eventId;
        _cameraIdentity = room?.localParticipant?.identity;
        _ready = false; // metadata always starts ready: false at token-issue
        _state = CameraState.soundCheck;
      });

      // Reconcile mute now that the real master-audio/Stream-Audio state is set
      // (the sync inside _applyMicProcessing ran before this setState).
      await _syncMicEnabled();

      // Enter Sound Check in Supabase — best-effort, no-op if not in DB.
      // The show only goes live when Start Show is pressed (_startShow).
      EventService.enterSoundCheck(eventId).catchError((_) {});

      // Host: load the assigned-crew roster for the readiness panel.
      // Non-host: follow the DB status so the UI flips to LIVE when the host
      // presses Start Show, and tears down when the show ends.
      if (widget.isHost) {
        // The host may have their own operator row (to carry a camera slot)
        // but has Start Show instead of a Ready toggle — exclude them from
        // their own readiness panel so they don't count as forever-pending.
        final uid = supabase.auth.currentUser?.id;
        CrewService.fetchOperatorsByRoom(eventId)
            .then((ops) {
              if (mounted) {
                setState(
                  () => _crew = ops
                      .where((o) => o.profile.id != uid)
                      .toList(growable: false),
                );
              }
            })
            .catchError((_) {});
        // Host rejoin after a drop: if the show is already live, land straight
        // in LIVE — never show Start Show, which would re-stamp the sync anchor
        // and kick off a duplicate replay egress. Also follow the DB status so
        // an end elsewhere tears this screen down. When the show ISN'T already
        // live, ping assigned crew that sound check is open (server dedupes).
        EventService.fetchEventState(eventId)
            .then((state) {
              if (!mounted) return;
              final status = state?['status'];
              if (status == 'live' && _state == CameraState.soundCheck) {
                setState(() => _state = CameraState.live);
              } else if (status != 'live' && status != 'ended') {
                EventService.notifySoundcheckOpen(eventId).catchError((_) {});
              }
            })
            .catchError((_) {});
        _statusChannel?.unsubscribe();
        _statusChannel = EventService.subscribeToEvent(
          liveKitEventId: eventId,
          onUpdate: (record) {
            if (!mounted) return;
            if (record['status'] == 'live' &&
                _state == CameraState.soundCheck) {
              setState(() => _state = CameraState.live);
            } else if (record['status'] == 'ended') {
              _teardownRoom();
            }
          },
        );
      } else {
        // If the show is already live (operator rejoining after a drop),
        // suppress the auto-flip: they re-enter the show via "Ready to
        // Stream" instead (_toggleReady).
        _joinedLiveShow = false;
        EventService.fetchEventState(eventId)
            .then((state) {
              if (mounted) _joinedLiveShow = state?['status'] == 'live';
            })
            .catchError((_) {});
        _statusChannel?.unsubscribe();
        _statusChannel = EventService.subscribeToEvent(
          liveKitEventId: eventId,
          onUpdate: (record) {
            if (!mounted) return;
            final status = record['status'];
            if (status == 'live' &&
                _state == CameraState.soundCheck &&
                !_joinedLiveShow) {
              setState(() => _state = CameraState.live);
            } else if (status == 'ended') {
              _teardownRoom();
            }
          },
        );
      }
    } catch (e) {
      // Tear down the half-connected room so it doesn't keep holding the
      // camera/mic and hang the next attempt.
      await room?.disconnect();
      if (!mounted) return;
      setState(() {
        _state = CameraState.idle;
        _errorMessage = 'Failed to connect: ${e.toString()}';
      });
    }
  }

  /// Record a remote publisher's readiness from its metadata. Call inside
  /// setState. No-op for metadata without a userId (e.g. viewers).
  void _applyReadyMeta(dynamic meta) {
    if (meta is! Map) return;
    final userId = meta['userId'] as String?;
    if (userId != null) _crewReady[userId] = meta['ready'] == true;
  }

  /// Crew (non-host): toggle my "Ready to Stream" flag. The Edge Function
  /// stamps it into this publisher's metadata so the host's panel updates.
  /// When the show is already live (rejoin after a drop), going ready also
  /// re-enters the show.
  Future<void> _toggleReady() async {
    if (_eventId == null) return;
    final next = !_ready;
    setState(() => _ready = next);
    try {
      await LivekitService.setReady(eventId: _eventId!, ready: next);
      if (next &&
          _joinedLiveShow &&
          mounted &&
          _state == CameraState.soundCheck) {
        setState(() => _state = CameraState.live);
      }
    } catch (_) {
      if (mounted) setState(() => _ready = !next); // revert on failure
    }
  }

  /// Number of assigned crew currently flagged ready.
  int get _readyCount =>
      _crew.where((o) => _crewReady[o.profile.id] == true).length;

  /// Host presses "Start Show". If any assigned crew haven't confirmed ready,
  /// ask once before going live; otherwise flip straight to live, which lets
  /// the waiting Lobby viewers into the stream (auto-transition via realtime).
  Future<void> _confirmStartShow() async {
    final total = _crew.length;
    final ready = _readyCount;
    if (ready < total) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: NileColors.bgSurface,
          title: Text('Start show?', style: NileTextStyles.headingMd()),
          content: Text(
            '${total - ready} of $total crew haven\'t confirmed ready. '
            'Start anyway?',
            style: NileTextStyles.bodyMd().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(
                'Cancel',
                style: NileTextStyles.labelMd().copyWith(
                  color: NileColors.txtSecondary,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(
                'Start Anyway',
                style: NileTextStyles.labelMd().copyWith(
                  color: NileColors.coral,
                ),
              ),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await _startShow();
  }

  Future<void> _startShow() async {
    if (_eventId == null) return;
    setState(() => _state = CameraState.live);
    EventService.goLive(_eventId!).catchError((_) {});
    // Stamp the camera-sync anchor (showStartedAt) into the room metadata.
    LivekitService.startShow(eventId: _eventId!).catchError((_) {});
  }

  Future<void> _claimMasterAudio() async {
    if (_eventId == null || _cameraIdentity == null) return;
    try {
      await LivekitService.setMasterAudio(
        eventId: _eventId!,
        cameraIdentity: _cameraIdentity!,
      );
    } catch (_) {}
  }

  Future<void> _toggleVideo() async {
    final newEnabled = !_videoEnabled;
    await _room?.localParticipant?.setCameraEnabled(
      newEnabled,
      cameraCaptureOptions: newEnabled
          ? CameraCaptureOptions(
              cameraPosition: _isFrontCamera
                  ? CameraPosition.front
                  : CameraPosition.back,
            )
          : null,
    );

    VideoTrack? newTrack;
    if (newEnabled) {
      final publication =
          _room?.localParticipant?.videoTrackPublications.firstOrNull;
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
      await _room!.localParticipant?.setCameraEnabled(false);
      await _room!.localParticipant?.setCameraEnabled(
        true,
        cameraCaptureOptions: CameraCaptureOptions(
          cameraPosition: newFront ? CameraPosition.front : CameraPosition.back,
        ),
      );
      final publication =
          _room!.localParticipant?.videoTrackPublications.firstOrNull;
      setState(() {
        _isFrontCamera = newFront;
        if (publication?.track != null) {
          _localVideoTrack = publication!.track as VideoTrack;
        }
      });
    } catch (_) {}
  }

  /// Leave the stream WITHOUT ending it. During a live show this just drops
  /// this camera — the show stays open (status stays 'live') so the host/other
  /// cameras and viewers can stay or rejoin. Ending the show is now an explicit,
  /// separate action ([_endStream]) tucked in Settings. The HOST leaving during
  /// Sound Check reverts the event to 'scheduled' (no one was watching yet);
  /// an operator leaving must not touch the event status.
  Future<void> _leaveStream() async {
    if (_eventId != null && widget.isHost && _state == CameraState.soundCheck) {
      EventService.revertToScheduled(_eventId!).catchError((_) {});
    }
    await _teardownRoom();
  }

  /// Explicitly end the live show: flip the DB status to 'ended' (the single
  /// source of truth viewers watch) then disconnect. This is the only path that
  /// ends a show; it lives at the bottom of the Settings sheet behind a confirm.
  Future<void> _endStream() async {
    if (_eventId != null) {
      EventService.end(_eventId!).catchError((_) {});
      // Stop the replay egress so the recording finalizes. Best-effort.
      LivekitService.stopEgress(eventId: _eventId!).catchError((_) {});
    }
    await _teardownRoom();
  }

  Future<void> _teardownRoom() async {
    _statusChannel?.unsubscribe();
    _statusChannel = null;
    await _listener?.dispose();
    await _room?.disconnect();
    if (!mounted) return;
    setState(() {
      _room = null;
      _listener = null;
      _localVideoTrack = null;
      _isMasterAudio = false;
      _videoEnabled = true;
      _ready = false;
      _crewReady.clear();
      _joinedLiveShow = false;
      _viewerPreviewOpen = false;
      _state = CameraState.idle;
    });
  }

  void _openAudioSettings() {
    final connected = _state != CameraState.idle;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: NileColors.bgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(NileRadius.lg),
        ),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(sheetCtx).size.height * 0.85,
              ),
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  24,
                  24,
                  24,
                  32 + MediaQuery.of(sheetCtx).viewInsets.bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Settings', style: NileTextStyles.headingMd()),
                    const SizedBox(height: 24),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            'Use external mic processing',
                            style: NileTextStyles.bodyLg(),
                          ),
                        ),
                        Switch(
                          value: _disableAgc,
                          activeThumbColor: NileColors.volt,
                          onChanged: _switchingMic
                              ? null
                              : (v) => _setExternalMicMode(
                                  v,
                                  onDone: () => setSheetState(() {}),
                                ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Off by default, this leaves automatic gain control, noise '
                      'reduction, and echo cancellation on — best for your phone\'s '
                      'built-in mic. Turn it on when a compatible USB-C or wireless '
                      'mic is connected: the phone\'s processing steps aside so the '
                      'mic\'s own tuning comes through cleanly, usually improving '
                      'audio quality.',
                      style: NileTextStyles.bodyMd().copyWith(
                        color: NileColors.txtSecondary,
                      ),
                    ),
                    if (_externalMicConnected && !_disableAgc) ...[
                      const SizedBox(height: 12),
                      Text(
                        'External mic detected — turning this on is recommended.',
                        style: NileTextStyles.bodySm().copyWith(
                          color: NileColors.volt,
                        ),
                      ),
                    ],
                    if (connected) ...[
                      const SizedBox(height: 12),
                      Text(
                        _switchingMic
                            ? 'Switching mic…'
                            : 'Changes apply immediately (brief audio gap while switching).',
                        style: NileTextStyles.bodySm().copyWith(
                          color: NileColors.amber,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Confirm before ending, then end. Reached from the visible End Stream
  /// button on the host's live layout.
  Future<void> _confirmEndStream() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text('End stream?', style: NileTextStyles.headingMd()),
        content: Text(
          'This ends the show for everyone watching. It can\'t be undone.',
          style: NileTextStyles.bodyMd().copyWith(
            color: NileColors.txtSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: NileTextStyles.labelMd().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'End Stream',
              style: NileTextStyles.labelMd().copyWith(color: NileColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) await _endStream();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        title: Text('Camera', style: NileTextStyles.headingMd()),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            color: NileColors.txtPrimary,
            tooltip: 'Audio settings',
            onPressed: _openAudioSettings,
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              if (_externalMicConnected &&
                  !_disableAgc &&
                  !_externalMicPromptDismissed)
                _buildExternalMicBanner(),
              Expanded(
                child: switch (_state) {
                  CameraState.idle => _buildForm(),
                  CameraState.connecting => _buildConnecting(),
                  CameraState.soundCheck || CameraState.live => _buildLive(),
                },
              ),
            ],
          ),
          // Viewer-preview overlay — host camera keeps publishing underneath so
          // toggling back is instant. Only reachable in host Sound Check.
          if (_viewerPreviewOpen && _eventId != null)
            Positioned.fill(
              child: ViewerPreviewOverlay(
                eventId: _eventId!,
                onClose: _closeViewerPreview,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildExternalMicBanner() {
    return Material(
      color: NileColors.bgRaised,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s8, NileSpacing.s8, NileSpacing.s8),
        child: Row(
          children: [
            Icon(Icons.mic_external_on, color: NileColors.volt, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'External mic detected. Use its processing for better audio?',
                style: NileTextStyles.bodySm().copyWith(
                  color: NileColors.txtPrimary,
                ),
              ),
            ),
            TextButton(
              onPressed: _switchingMic ? null : () => _setExternalMicMode(true),
              child: Text(
                'Use it',
                style: NileTextStyles.labelMd().copyWith(
                  color: NileColors.volt,
                ),
              ),
            ),
            IconButton(
              icon: Icon(
                Icons.close,
                size: 18,
                color: NileColors.txtSecondary,
              ),
              tooltip: 'Dismiss',
              onPressed: () =>
                  setState(() => _externalMicPromptDismissed = true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(NileSpacing.s32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Sound Check', style: NileTextStyles.headingLg()),
          const SizedBox(height: 8),
          Text(
            'Set up and test your camera and mic. Viewers wait in the Lobby '
            'until you press Start Show.',
            style: NileTextStyles.bodyMd().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
          const SizedBox(height: 32),
          TextField(
            controller: _eventIdController,
            style: NileTextStyles.bodyLg(),
            decoration: const InputDecoration(
              labelText: 'Event ID',
              hintText: 'e.g. my-live-show',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _cameraNameController,
            style: NileTextStyles.bodyLg(),
            decoration: const InputDecoration(
              labelText: 'Camera Name',
              hintText: 'e.g. Stage Left Cam',
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
          // Enter Sound Check — connects devices without going live yet
          FilledButton.icon(
            onPressed: _enterSoundCheck,
            icon: const Icon(Icons.videocam),
            label: const Text('Enter Sound Check'),
            style: FilledButton.styleFrom(
              backgroundColor: NileColors.coral,
              foregroundColor: Colors.white,
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
          Text('Connecting...', style: NileTextStyles.bodyMd()),
        ],
      ),
    );
  }

  /// Host-only Sound Check panel: each assigned crew member with a pending/✓
  /// readiness indicator, driven by the ready flag in publisher metadata.
  Widget _buildCrewPanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(NileSpacing.s12),
      decoration: BoxDecoration(
        color: NileColors.bgSurface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'CREW · $_readyCount/${_crew.length} READY',
            style: NileTextStyles.labelSm().copyWith(
              color: NileColors.txtSecondary,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          for (final op in _crew) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: NileSpacing.s2),
              child: Row(
                children: [
                  Icon(
                    _crewReady[op.profile.id] == true
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: _crewReady[op.profile.id] == true
                        ? NileColors.volt
                        : NileColors.txtTertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '@${op.profile.username}'
                      '${op.isAudioOperator
                          ? ' · Stream Audio'
                          : op.slotIndex != null
                          ? ' · Camera ${op.slotIndex}'
                          : ''}',
                      style: NileTextStyles.bodySm().copyWith(
                        color: NileColors.txtPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    _crewReady[op.profile.id] == true ? 'Ready' : 'Pending',
                    style: NileTextStyles.labelSm().copyWith(
                      color: _crewReady[op.profile.id] == true
                          ? NileColors.volt
                          : NileColors.txtTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Compact audio meter shown on the live camera view. Fed by this camera's own
  /// mic; greyed and labelled "MUTED" when this feed isn't the broadcast source.
  Widget _buildCameraMeter() {
    final source = _isMainAudioSource;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AudioMeter(
          participant: _room!.localParticipant!,
          height: 140,
          active: source,
        ),
        const SizedBox(height: 8),
        Text(
          source ? 'STREAM AUDIO' : 'MUTED',
          style: NileTextStyles.labelSm().copyWith(
            color: source ? NileColors.volt : NileColors.txtTertiary,
            letterSpacing: 1.2,
          ),
        ),
      ],
    );
  }

  Widget _buildLive() {
    return Stack(
      children: [
        // ── Video preview or dark screen when video is off ─────────────
        if (_videoEnabled && _localVideoTrack != null)
          VideoTrackRenderer(
            _localVideoTrack!,
            mirrorMode: _isFrontCamera
                ? VideoViewMirrorMode.mirror
                : VideoViewMirrorMode.off,
          )
        else
          Container(
            color: NileColors.bgPage,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.videocam_off,
                    size: 64,
                    color: NileColors.border,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Video Off',
                    style: NileTextStyles.bodyMd().copyWith(
                      color: NileColors.txtTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),

        // ── Audio meter — right edge, vertically centred ───────────────
        // Every camera shows the same meter the Stream Audio screen uses, fed
        // by this device's own mic so the operator can confirm it's picking up
        // sound. Greyed/frozen unless this camera is the broadcast audio source
        // (i.e. it holds Master Audio and no dedicated Stream Audio is live) —
        // a muted feed reads as visibly off.
        if (_room?.localParticipant != null)
          Positioned(
            top: 0,
            bottom: 0,
            right: 16,
            child: Center(child: _buildCameraMeter()),
          ),

        // ── Status badge — top left ─────────────────────────────────────
        // SOUND CHECK (volt) before the show starts, LIVE (coral) after.
        Positioned(
          top: 16,
          left: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s8, vertical: NileSpacing.s4),
            decoration: BoxDecoration(
              color: _state == CameraState.live
                  ? NileColors.coral
                  : NileColors.volt,
              borderRadius: BorderRadius.circular(NileRadius.pill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _state == CameraState.live ? Icons.circle : Icons.tune,
                  size: 8,
                  color: _state == CameraState.live
                      ? Colors.white
                      : NileColors.onVolt,
                ),
                const SizedBox(width: 6),
                Text(
                  _state == CameraState.live ? 'LIVE' : 'SOUND CHECK',
                  style: NileTextStyles.labelSm().copyWith(
                    color: _state == CameraState.live
                        ? Colors.white
                        : NileColors.onVolt,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── Master audio status — top right ───────────────────────────
        Positioned(
          top: 16,
          right: 16,
          child: _isMasterAudio
              ? _streamAudioActive
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: NileSpacing.s12,
                          vertical: NileSpacing.s6,
                        ),
                        decoration: BoxDecoration(
                          color: NileColors.amber.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(NileRadius.pill),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.album,
                              size: 14,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'STREAM AUDIO ACTIVE',
                              style: NileTextStyles.labelSm().copyWith(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      )
                    : Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: NileSpacing.s12,
                          vertical: NileSpacing.s6,
                        ),
                        decoration: BoxDecoration(
                          color: NileColors.volt,
                          borderRadius: BorderRadius.circular(NileRadius.pill),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.album,
                              size: 14,
                              color: NileColors.onVolt,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'MASTER AUDIO',
                              style: NileTextStyles.labelSm().copyWith(
                                color: NileColors.onVolt,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      )
              : ElevatedButton.icon(
                  onPressed: _claimMasterAudio,
                  icon: const Icon(Icons.album, size: 16),
                  label: Text(
                    'Set as Master Audio',
                    style: NileTextStyles.bodySm().copyWith(
                      color: NileColors.txtPrimary,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: NileColors.bgSurface.withValues(
                      alpha: 0.85,
                    ),
                    foregroundColor: NileColors.txtPrimary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: NileSpacing.s12,
                      vertical: NileSpacing.s8,
                    ),
                    shape: const StadiumBorder(),
                  ),
                ),
        ),

        // ── Bottom controls ────────────────────────────────────────────
        Positioned(
          bottom: 32,
          left: 32,
          right: 32,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Sound Check, host: crew readiness panel + Start Show (flips the
              // event live and lets waiting Lobby viewers in). Start Show is
              // host-only — operators see a "Ready to Stream" toggle instead.
              if (_state == CameraState.soundCheck && widget.isHost) ...[
                if (_crew.isNotEmpty) ...[
                  _buildCrewPanel(),
                  const SizedBox(height: 12),
                ],
                // Open a real viewer connection to check the broadcast audio
                // path (and video) exactly as a viewer hears it before going
                // live. Host-only, Sound Check only.
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _openViewerPreview,
                    icon: const Icon(Icons.headphones),
                    label: const Text('View as Viewer'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: NileColors.volt,
                      side: BorderSide(color: NileColors.volt),
                      padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                      textStyle: NileTextStyles.labelLg(),
                      shape: const StadiumBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _confirmStartShow,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start Show'),
                    style: FilledButton.styleFrom(
                      backgroundColor: NileColors.coral,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                      textStyle: NileTextStyles.labelLg(),
                      shape: const StadiumBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              // Sound Check, crew: toggleable "Ready to Stream" — tells the
              // host this feed is good to go. Tap again to un-ready.
              if (_state == CameraState.soundCheck && !widget.isHost) ...[
                SizedBox(
                  width: double.infinity,
                  child: _ready
                      ? FilledButton.icon(
                          onPressed: _toggleReady,
                          icon: const Icon(Icons.check_circle),
                          label: const Text('Ready'),
                          style: FilledButton.styleFrom(
                            backgroundColor: NileColors.volt,
                            foregroundColor: NileColors.onVolt,
                            padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                            textStyle: NileTextStyles.labelLg(),
                            shape: const StadiumBorder(),
                          ),
                        )
                      : OutlinedButton.icon(
                          onPressed: _toggleReady,
                          icon: const Icon(Icons.check_circle_outline),
                          label: const Text('Ready to Stream'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: NileColors.volt,
                            side: BorderSide(color: NileColors.volt),
                            padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                            textStyle: NileTextStyles.labelLg(),
                            shape: const StadiumBorder(),
                          ),
                        ),
                ),
                const SizedBox(height: 12),
              ],
              // Live, host: visible End Stream — destructive, confirm-gated. The
              // sole path that ends a show. Operators never see it (host-only).
              if (_state == CameraState.live && widget.isHost) ...[
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _confirmEndStream,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('End Stream'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: NileColors.error,
                      side: const BorderSide(color: NileColors.error),
                      padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                      textStyle: NileTextStyles.labelLg(),
                      shape: const StadiumBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Row(
                children: [
                  // Flip camera — mobile only, video must be on
                  if (!kIsWeb && _videoEnabled) ...[
                    IconButton(
                      onPressed: _switchCamera,
                      icon: const Icon(Icons.flip_camera_ios),
                      color: NileColors.txtPrimary,
                      style: IconButton.styleFrom(
                        backgroundColor: NileColors.bgSurface.withValues(
                          alpha: 0.8,
                        ),
                        padding: const EdgeInsets.all(NileSpacing.s12),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  // Video toggle — only shown when this camera is master audio
                  if (_isMasterAudio) ...[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _toggleVideo,
                        icon: Icon(
                          _videoEnabled ? Icons.videocam_off : Icons.videocam,
                        ),
                        label: Text(_videoEnabled ? 'Video Off' : 'Video On'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: NileColors.txtPrimary,
                          side: BorderSide(
                            color: NileColors.borderStrong,
                          ),
                          padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                          shape: const StadiumBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  // Leave — neutral, NOT destructive. Leaving a live show no longer
                  // ends it (the show stays open); ending is an explicit action in
                  // Settings. During Sound Check this reverts to scheduled.
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _leaveStream,
                      icon: const Icon(Icons.logout),
                      label: const Text('Leave'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: NileColors.txtPrimary,
                        side: BorderSide(color: NileColors.border),
                        padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                        textStyle: NileTextStyles.labelMd(),
                        shape: const StadiumBorder(),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
