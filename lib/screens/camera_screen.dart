import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' hide ChatMessage;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;
import '../services/supabase_client.dart';
import '../services/block_service.dart';
import '../services/chat_service.dart';
import '../services/crew_service.dart';
import '../services/event_service.dart';
import '../services/livekit_service.dart';
import '../services/report_service.dart';
import '../services/screen_capture_permission.dart';
import '../services/shake_detector.dart';
import '../widgets/audio_meter.dart';
import '../widgets/nile_studio.dart';
import '../widgets/screen_share_picker.dart';
import '../widgets/viewer_preview_overlay.dart';
import '../theme.dart';
import 'widgets/moderation_menu.dart';

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
    // A phone acting as a camera gets knocked constantly — never let a shake
    // throw the report form over a live shot.
    ShakeDetector.instance.pause();
    if (widget.initialEventId != null) {
      _eventIdController.text = widget.initialEventId!;
    }
    if (widget.initialCameraName != null) {
      _cameraNameController.text = widget.initialCameraName!;
    }
    _refreshMicDetection();
    _refreshVideoInputs();
    _deviceChangeSub = Hardware.instance.onDeviceChange.stream.listen((_) {
      _refreshMicDetection();
      _refreshVideoInputs();
    });
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

  /// Refresh the list of attachable cameras (webcams, USB cams, capture
  /// cards). If the currently selected device was unplugged mid-session,
  /// fall back to the default camera so the feed doesn't freeze.
  Future<void> _refreshVideoInputs() async {
    try {
      final devices = await Hardware.instance.enumerateDevices(
        type: 'videoinput',
      );
      if (!mounted) return;
      setState(() => _videoInputs = devices);
      if (_selectedCameraId != null &&
          !devices.any((d) => d.deviceId == _selectedCameraId)) {
        final lost = _selectedCameraId;
        _selectedCameraId = null;
        // Only republish if we're actively capturing.
        if (_room != null && _videoEnabled) {
          await _republishCamera();
          if (mounted && lost != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'External camera disconnected — switched to the default camera.',
                ),
              ),
            );
          }
        }
      }
    } catch (_) {
      // Enumeration unsupported on this platform — silently skip.
    }
  }

  /// The capture options every (re)publish path uses: an explicitly picked
  /// device wins; otherwise fall back to front/back position (mobile).
  CameraCaptureOptions get _cameraCaptureOptions => _selectedCameraId != null
      ? CameraCaptureOptions(deviceId: _selectedCameraId)
      : CameraCaptureOptions(
          cameraPosition: _isFrontCamera
              ? CameraPosition.front
              : CameraPosition.back,
        );

  /// The local CAMERA publication specifically — never the screen share,
  /// which also lives in videoTrackPublications once sharing starts.
  LocalTrackPublication? _cameraPub(LocalParticipant? p) => p
      ?.videoTrackPublications
      .where((pub) => pub.source == TrackSource.camera)
      .firstOrNull;

  /// Restart the local camera with the current [_cameraCaptureOptions] and
  /// refresh the preview track reference.
  Future<void> _republishCamera() async {
    final participant = _room?.localParticipant;
    if (participant == null) return;
    await participant.setCameraEnabled(false);
    await participant.setCameraEnabled(
      true,
      cameraCaptureOptions: _cameraCaptureOptions,
    );
    if (!mounted) return;
    final publication = _cameraPub(participant);
    setState(() {
      if (publication?.track != null) {
        _localVideoTrack = publication!.track as VideoTrack;
      }
    });
  }

  /// User picked a camera from the device menu. Null re-selects the default.
  Future<void> _selectCamera(String? deviceId) async {
    if (deviceId == _selectedCameraId) return;
    setState(() => _selectedCameraId = deviceId);
    if (_room != null && _videoEnabled) {
      try {
        await _republishCamera();
      } catch (_) {
        // Device refused to open (in use / permission) — revert to default.
        if (mounted) {
          setState(() => _selectedCameraId = null);
          await _republishCamera();
        }
      }
    }
  }

  bool get _isSharingScreen => _screenShareTrack != null;

  /// Start/stop sharing this device's screen as an additional video track.
  /// The camera keeps publishing — viewers get both tiles.
  /// macOS: source-picker dialog, then a plain screen-share track (first
  /// share triggers the system Screen Recording prompt).
  /// iPad: hands off to the Broadcast Upload Extension via the system
  /// broadcast picker (whole-device capture).
  Future<void> _toggleScreenShare() async {
    final participant = _room?.localParticipant;
    if (participant == null || _togglingShare) return;
    setState(() => _togglingShare = true);
    try {
      if (_isSharingScreen) {
        await _stopScreenShare(participant);
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        final pub = await participant.setScreenShareEnabled(
          true,
          screenShareCaptureOptions: const ScreenShareCaptureOptions(
            useiOSBroadcastExtension: true,
            maxFrameRate: 15.0,
          ),
        );
        if (mounted) {
          setState(
            () => _screenShareTrack = pub?.track as LocalVideoTrack?,
          );
        }
      } else {
        // macOS grants Screen Recording per-launch: ask before opening a picker
        // that would otherwise come back empty and read as a broken feature.
        if (!await ScreenCapturePermission.ensure(context)) return;
        if (!mounted) return;
        final source = await ScreenSharePicker.show(context);
        if (source == null) return; // cancelled
        final track = await LocalVideoTrack.createScreenShareTrack(
          ScreenShareCaptureOptions(sourceId: source.id, maxFrameRate: 15.0),
        );
        await participant.publishVideoTrack(track);
        if (mounted) setState(() => _screenShareTrack = track);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              defaultTargetPlatform == TargetPlatform.iOS
                  ? 'Could not start the screen broadcast. Try again from '
                        'the broadcast picker.'
                  : 'Could not share the screen. Check Screen Recording '
                        'permission in System Settings → Privacy & Security, '
                        'then relaunch.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _togglingShare = false);
    }
  }

  Future<void> _stopScreenShare(LocalParticipant participant) async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await participant.setScreenShareEnabled(false);
    } else {
      final track = _screenShareTrack;
      if (track != null) {
        final pub = participant.videoTrackPublications
            .where((p) => p.track == track)
            .firstOrNull;
        if (pub != null) await participant.removePublishedTrack(pub.sid);
        await track.stop();
      }
    }
    if (mounted) setState(() => _screenShareTrack = null);
  }

  /// The device picker only appears where external cameras are a real thing:
  /// macOS, or iOS on a tablet-sized screen (iPad — iPadOS 17+ supports USB
  /// cameras). Phones keep the compact front/back flip button.
  bool _showCameraPicker(BuildContext context) {
    if (kIsWeb) return false;
    if (defaultTargetPlatform == TargetPlatform.macOS) return true;
    return defaultTargetPlatform == TargetPlatform.iOS &&
        MediaQuery.sizeOf(context).shortestSide >= 600;
  }

  // ── Studio (desktop) ────────────────────────────────────────────────────────
  // A desk-sized window gets the Studio instead of the phone's full-bleed
  // preview. It is the same state machine either way — only `build` differs —
  // so nothing below is allowed to change what the phone does.
  //
  // Monitoring crew feeds needs a subscribe grant, and the livekit function
  // gives one only to the host's camera token. An operator therefore sees the
  // Studio chrome with their own feed in it and an empty roster, which is
  // correct: they run one camera, not the show.

  /// Crew feeds and their screen shares, rebuilt on participant/track events
  /// rather than in `build` — a live room can hold hundreds of viewers and
  /// walking that list every frame would be pointless work.
  List<NileStudioSource> _remoteSources = const [];

  /// Which source the monitor is showing. Null falls back to the first.
  String? _selectedSourceId;

  /// True once the window is wide enough for the Studio. Read in
  /// `didChangeDependencies` (the safe place for MediaQuery) so the
  /// subscribe/unsubscribe pass can run off it without touching `build`.
  bool _studioMode = false;

  int _viewerCount = 0;
  NileStudioQuality _quality = NileStudioQuality.unknown;

  /// Senders muted for this session, and senders blocked outright. Kept apart
  /// so "Show all" undoes only the reversible one.
  final Set<String> _hiddenSenders = {};
  final Set<String> _blockedSenders = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final studio = !NileBreakpoints.of(context).isCompact;
    if (studio == _studioMode) return;
    _studioMode = studio;
    _syncSubscriptions();
  }

  /// Subscribe to crew video while the Studio is on screen, and drop it when it
  /// isn't. Without this a host on a phone would pull every crew feed for a UI
  /// that never shows them — the room is joined with `autoSubscribe: false`
  /// precisely so this decision is ours to make.
  void _syncSubscriptions() {
    final room = _room;
    if (room == null || !widget.isHost) return;
    for (final p in room.remoteParticipants.values) {
      if (!_isPublisher(p)) continue;
      for (final pub in p.videoTrackPublications) {
        if (_studioMode && !pub.subscribed) {
          pub.subscribe();
        } else if (!_studioMode && pub.subscribed) {
          pub.unsubscribe();
        }
      }
    }
  }

  /// Cameras and the Stream Audio device publish; viewers just watch. Filtering
  /// on the role in token metadata is what keeps a thousand-viewer room from
  /// turning into a thousand-row source list.
  bool _isPublisher(Participant p) {
    final role = _metaOf(p)['role'];
    return role == 'camera' || role == 'master-audio';
  }

  Map<String, dynamic> _metaOf(Participant p) {
    try {
      final decoded = jsonDecode(p.metadata ?? '{}');
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  /// Rebuild the crew half of the source list. Assigned crew who haven't
  /// connected are listed too — "camera 3 isn't here yet" is exactly what a
  /// host wants the roster to tell them.
  void _rebuildRemoteSources() {
    final room = _room;
    if (room == null) {
      if (_remoteSources.isNotEmpty) {
        setState(() => _remoteSources = const []);
      }
      return;
    }

    final sources = <NileStudioSource>[];
    final connectedUserIds = <String>{};

    for (final p in room.remoteParticipants.values) {
      if (!_isPublisher(p)) continue;
      final meta = _metaOf(p);
      final userId = meta['userId'] as String?;
      if (userId != null) connectedUserIds.add(userId);
      final isAudioOnly = meta['role'] == 'master-audio';
      final ready = meta['ready'] == true;
      final name = p.name.isNotEmpty ? p.name : p.identity;

      final videoPubs = p.videoTrackPublications;
      if (videoPubs.isEmpty) {
        sources.add(
          NileStudioSource(
            identity: p.identity,
            label: name,
            sublabel: isAudioOnly ? 'Stream Audio · no video' : 'No video',
            isMasterAudio: isAudioOnly || meta['isMasterAudio'] == true,
            isReady: ready,
          ),
        );
        continue;
      }
      for (final pub in videoPubs) {
        final isShare = pub.source == TrackSource.screenShareVideo;
        sources.add(
          NileStudioSource(
            identity: isShare ? '${p.identity}#share' : p.identity,
            label: isShare ? '$name — screen' : name,
            sublabel: isShare
                ? 'Screen share'
                : (ready ? 'Ready' : 'Standing by'),
            track: pub.subscribed ? pub.track as VideoTrack? : null,
            isScreenShare: isShare,
            isMasterAudio: !isShare && meta['isMasterAudio'] == true,
            isReady: !isShare && ready,
          ),
        );
      }
    }

    for (final op in _crew) {
      if (connectedUserIds.contains(op.profile.id)) continue;
      sources.add(
        NileStudioSource(
          identity: 'crew:${op.profile.id}',
          label: '@${op.profile.username}',
          sublabel: op.isAudioOperator
              ? 'Stream Audio · not connected'
              : op.slotIndex != null
              ? 'Camera ${op.slotIndex} · not connected'
              : 'Not connected',
        ),
      );
    }

    if (!mounted) return;
    setState(() => _remoteSources = sources);
  }

  /// Your own camera and screen share, prepended to the roster. Derived in
  /// `build` because every field it reads already lives in `setState`.
  List<NileStudioSource> get _localSources {
    final local = _room?.localParticipant;
    if (local == null) return const [];
    final name = _cameraNameController.text.trim();
    final out = <NileStudioSource>[
      NileStudioSource(
        identity: local.identity,
        label: name.isEmpty ? 'Your camera' : 'You · $name',
        sublabel: _isMainAudioSource ? 'Broadcast audio' : 'Mic muted',
        track: _videoEnabled ? _localVideoTrack : null,
        isLocal: true,
        isMasterAudio: _isMasterAudio,
        mirror: _selectedCameraId == null && _isFrontCamera,
      ),
    ];
    final share = _screenShareTrack;
    if (share != null) {
      out.add(
        NileStudioSource(
          identity: '${local.identity}#share',
          label: 'Your screen',
          sublabel: 'Screen share',
          track: share,
          isLocal: true,
          isScreenShare: true,
        ),
      );
    }
    return out;
  }

  NileStudioQuality _mapQuality(ConnectionQuality q) => switch (q) {
    ConnectionQuality.excellent => NileStudioQuality.excellent,
    ConnectionQuality.good => NileStudioQuality.good,
    ConnectionQuality.poor => NileStudioQuality.poor,
    ConnectionQuality.lost => NileStudioQuality.lost,
    ConnectionQuality.unknown => NileStudioQuality.unknown,
  };

  /// Who viewers are hearing right now — a live Stream Audio feed always wins,
  /// otherwise it is whichever camera holds master audio.
  String? get _audioSourceLabel {
    if (_streamAudioActive) return 'Stream Audio';
    if (_isMainAudioSource) return 'Your mic';
    for (final s in _remoteSources) {
      if (s.isMasterAudio && !s.isScreenShare) return s.label;
    }
    return null;
  }

  // ── Chat moderation (Studio) ────────────────────────────────────────────────
  // Chat is an ephemeral broadcast, so there is no server-side message to
  // delete. Hiding is local and reversible; blocking is the real, persisted
  // action and applies app-wide; reporting goes to the same review queue as
  // every other report.

  void _hideSender(ChatMessage m) {
    if (m.senderId.isEmpty) return;
    setState(() => _hiddenSenders.add(m.senderId));
  }

  void _showAllSenders() => setState(_hiddenSenders.clear);

  Future<void> _blockSender(ChatMessage m) async {
    if (m.senderId.isEmpty) return;
    final blocked = await Moderation.confirmBlock(
      context,
      userId: m.senderId,
      username: m.username,
    );
    if (blocked && mounted) {
      setState(() => _blockedSenders.add(m.senderId));
    }
  }

  Future<void> _reportSender(ChatMessage m) async {
    if (m.senderId.isEmpty) return;
    await Moderation.showReportSheet(
      context,
      targetType: ReportTargetType.user,
      targetId: m.senderId,
    );
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

  // External camera selection (iPad/macOS). Null = system default camera,
  // driven by _isFrontCamera. Non-null = an explicitly picked device.
  List<MediaDevice> _videoInputs = const [];
  String? _selectedCameraId;

  // Screen share (macOS for now; iPad in Phase 3). Published as a second
  // video track alongside the camera — viewers see it as its own tile.
  LocalVideoTrack? _screenShareTrack;
  bool _togglingShare = false;

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

  // ── Show clock ──────────────────────────────────────────────────────────────
  // Every show gets its purchased duration measured from the ACTUAL start
  // (same rule as the server's auto-end, migration 0056). Crew see a countdown
  // for the last 10 minutes; at zero the HOST's device ends the show and the
  // server cron stays as the backstop. Viewers never see any of this.
  static const Duration _countdownWindow = Duration(minutes: 10);
  Timer? _countdownTimer;
  Duration? _plannedDuration; // end_at − scheduled_at
  DateTime? _plannedEndAt; // end_at, used when there's no start anchor
  DateTime? _startedAt;
  Duration? _remaining; // non-null only inside the countdown window
  bool _autoEnding = false;

  DateTime? get _effectiveEndAt {
    final started = _startedAt;
    final planned = _plannedDuration;
    if (started != null && planned != null) return started.add(planned);
    return _plannedEndAt;
  }

  /// Pull the timing anchors for this room. Best-effort: with no anchors the
  /// countdown simply never appears and the server cron still ends the show.
  Future<void> _loadTimingAnchors(String eventId) async {
    try {
      final state = await EventService.fetchEventState(eventId);
      if (!mounted || state == null) return;
      final sched = state['scheduled_at'] as String?;
      final end = state['end_at'] as String?;
      setState(() {
        _plannedEndAt = end == null ? null : DateTime.parse(end);
        _plannedDuration = (sched != null && end != null)
            ? DateTime.parse(end).difference(DateTime.parse(sched))
            : null;
        _captureStartedAt(state['started_at']);
        _viewerCount = (state['viewer_count'] as num?)?.toInt() ?? _viewerCount;
      });
    } catch (_) {
      /* best-effort */
    }
  }

  /// Record the show's start anchor from a row/realtime record. Call inside
  /// setState (or before one).
  void _captureStartedAt(dynamic raw) {
    if (raw is String) _startedAt = DateTime.tryParse(raw);
  }

  /// Mirror the row's viewer count into the Studio stats row. The count is
  /// server-authoritative — viewers reconcile it against LiveKit participants —
  /// so this screen only ever reads it.
  void _captureViewerCount(Map<String, dynamic> record) {
    final n = (record['viewer_count'] as num?)?.toInt();
    if (n == null || n == _viewerCount) return;
    setState(() => _viewerCount = n);
  }

  void _startCountdownTicker() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickCountdown(),
    );
  }

  void _tickCountdown() {
    if (!mounted || _autoEnding) return;
    // The Studio's "time on air" is derived from _startedAt at build time, so
    // it only advances if something rebuilds. This ticker is already running
    // every second for the countdown — piggyback rather than add a second one.
    if (_studioMode && _state == CameraState.live && _startedAt != null) {
      setState(() {});
    }
    final end = _effectiveEndAt;
    if (_state != CameraState.live || end == null) {
      if (_remaining != null) setState(() => _remaining = null);
      return;
    }
    final left = end.difference(DateTime.now());
    final next = left > _countdownWindow
        ? null
        : (left.isNegative ? Duration.zero : left);
    if (next != _remaining) setState(() => _remaining = next);
    if (!left.isNegative) return;

    // Time's up. Only the host ends the show — operator devices just watch the
    // room close when the status flips.
    if (!widget.isHost) return;
    setState(() => _autoEnding = true);
    _countdownTimer?.cancel();
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) _endStream();
    });
  }

  // Host Sound Check: "View as Viewer" overlay is open. The host's publishing
  // mic is force-muted for its lifetime (feedback guard) and restored on close.
  bool _viewerPreviewOpen = false;

  // Live chat (read-only overlay). Same ephemeral broadcast channel the
  // viewers use; capped buffer, newest first (list renders reversed).
  static const int _maxChatMessages = 200;
  RealtimeChannel? _chatChannel;
  final List<ChatMessage> _chatMessages = [];
  bool _chatVisible = true;

  void _onChatMessage(ChatMessage m) {
    if (!mounted) return;
    setState(() {
      _chatMessages.insert(0, m);
      if (_chatMessages.length > _maxChatMessages) {
        _chatMessages.removeLast();
      }
    });
  }

  @override
  void dispose() {
    ShakeDetector.instance.resume();
    // A drop or back-swipe never ends a live show anymore — the show stays
    // 'live' and viewers' resilience logic treats it as reconnect-and-wait.
    // Ending only ever happens via the explicit End Stream confirm path.
    // The HOST leaving during Sound Check (show never started) still reverts
    // the event to scheduled; an operator leaving must not.
    if (_eventId != null && widget.isHost && _state == CameraState.soundCheck) {
      EventService.revertToScheduled(_eventId!).catchError((_) {});
    }
    _countdownTimer?.cancel();
    _statusChannel?.unsubscribe();
    _chatChannel?.unsubscribe();
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
        // Ask for the Studio's monitor grant. Safe to ask unconditionally: we
        // connect with autoSubscribe off and subscribe only while the Studio
        // is on screen, and the server ignores the request from non-hosts.
        monitor: widget.isHost,
      );
      final token = conn.token;
      final wsUrl = conn.wsUrl;
      final isMasterAudio = conn.isMasterAudio;

      // Tear down any prior room first — a lingering connection holds the
      // camera/mic and makes the next connect hang.
      await _room?.disconnect();
      _room = null;

      // adaptiveStream is subscriber-side only: it lets the Studio's thumbnail
      // grid pull low layers while the monitor pulls full resolution. Nothing
      // about publishing changes, on any platform.
      room = Room(roomOptions: const RoomOptions(adaptiveStream: true));
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
        // Ready ticks and the master-audio badge live on the source tiles.
        _rebuildRemoteSources();
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
        _syncSubscriptions();
        _rebuildRemoteSources();
      });

      // The screen share can end outside our button — iPad's system broadcast
      // stop, or the shared window closing on macOS. Keep the UI honest.
      listener.on<LocalTrackUnpublishedEvent>((event) {
        if (event.publication.source == TrackSource.screenShareVideo &&
            mounted) {
          setState(() => _screenShareTrack = null);
        }
      });

      // ── Studio roster ──────────────────────────────────────────────────
      // Everything that can change what the source list shows. A crew camera
      // publishing is also the moment to subscribe to it, if the Studio is up.
      listener
        ..on<TrackPublishedEvent>((_) {
          _syncSubscriptions();
          _rebuildRemoteSources();
        })
        ..on<TrackUnpublishedEvent>((_) => _rebuildRemoteSources())
        ..on<TrackSubscribedEvent>((_) => _rebuildRemoteSources())
        ..on<TrackUnsubscribedEvent>((_) => _rebuildRemoteSources())
        ..on<TrackMutedEvent>((_) => _rebuildRemoteSources())
        ..on<TrackUnmutedEvent>((_) => _rebuildRemoteSources())
        ..on<ParticipantConnectionQualityUpdatedEvent>((event) {
          if (!mounted) return;
          if (event.participant.identity !=
              _room?.localParticipant?.identity) {
            return;
          }
          setState(() => _quality = _mapQuality(event.connectionQuality));
        })
        ..on<RoomReconnectingEvent>((_) {
          if (mounted) setState(() => _quality = NileStudioQuality.lost);
        })
        ..on<RoomReconnectedEvent>((_) {
          if (mounted) setState(() => _quality = NileStudioQuality.unknown);
          _syncSubscriptions();
          _rebuildRemoteSources();
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
        _rebuildRemoteSources();
      });

      // Fail loudly instead of hanging on "Connecting…" forever if the WebRTC
      // connection or camera/mic acquisition stalls.
      await room
          .connect(
            wsUrl,
            token,
            // Never auto-subscribe. Only the host's token carries a subscribe
            // grant at all, and even then the feeds are wanted only while the
            // Studio is on screen — `_syncSubscriptions` decides, not the SDK.
            connectOptions: const ConnectOptions(autoSubscribe: false),
          )
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () =>
                throw Exception('Connection timed out. Try again.'),
          );
      await room.localParticipant
          ?.setCameraEnabled(true, cameraCaptureOptions: _cameraCaptureOptions)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () =>
                throw Exception('Camera timed out. Check camera permissions.'),
          );
      await _applyMicProcessing(room.localParticipant);

      final publication = _cameraPub(room.localParticipant);
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

      // Studio: pick up whoever was already in the room, and fold in the
      // people this host has already blocked so their chat never appears.
      _syncSubscriptions();
      _rebuildRemoteSources();
      BlockService.blockedIds()
          .then((ids) {
            if (mounted) setState(() => _blockedSenders.addAll(ids));
          })
          .catchError((_) {});

      // Enter Sound Check in Supabase. The show only goes live when Start Show
      // is pressed (_startShow). Migration 0089 rejects this when the event's
      // window has already closed — a host arriving hours late used to flip the
      // row to 'soundcheck' while every viewer surface still said ENDED, so the
      // Studio said SOUND CHECK and nobody could get in. Say so out loud rather
      // than swallowing it.
      EventService.enterSoundCheck(eventId).catchError((Object _) {
        _toast(
          'This event’s scheduled window has already closed, so viewers can’t '
          'join. Edit the date on the event page to run it now.',
        );
      });

      // Join the live-chat broadcast so the host/operator can watch the room.
      _chatChannel = ChatService.subscribe(eventId, _onChatMessage);

      // Show clock: fetch the timing anchors and start the 1s ticker that
      // drives the crew-only countdown (and the host's auto-end at zero).
      _loadTimingAnchors(eventId);
      _startCountdownTicker();

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
                // Assigned-but-absent crew show as placeholder rows.
                _rebuildRemoteSources();
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
            _captureStartedAt(record['started_at']);
            _captureViewerCount(record);
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
            _captureStartedAt(record['started_at']);
            _captureViewerCount(record);
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

  /// Runs [op], retrying a couple of times with a short backoff. Returns false
  /// if every attempt failed.
  ///
  /// Start Show and End Stream used to be fire-and-forget `.catchError((_) {})`
  /// with teardown proceeding regardless — a failed Start Show meant the host
  /// streamed while every paying viewer sat in the Lobby for the whole show, and
  /// a failed End Stream left the row `live` with a dead room until the cron
  /// caught it. Both now retry, and both tell the host when they can't.
  static Future<bool> _retry(Future<void> Function() op) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await op();
        return true;
      } catch (_) {
        if (attempt < 2) {
          await Future.delayed(Duration(milliseconds: 400 * (attempt + 1)));
        }
      }
    }
    return false;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
    );
  }

  Future<void> _startShow() async {
    if (_eventId == null) return;
    setState(() {
      _state = CameraState.live;
      // Anchor the show clock locally — the DB write below stamps the same
      // instant, and the countdown shouldn't wait on a round-trip.
      _startedAt = DateTime.now();
    });

    final wentLive = await _retry(() => EventService.goLive(_eventId!));
    if (!wentLive) {
      // Nobody can see the show. Put the button back rather than leaving the
      // host performing to an empty Lobby.
      if (mounted) {
        setState(() {
          _state = CameraState.soundCheck;
          _startedAt = null;
        });
      }
      _toast(
        'Couldn’t start the show — your viewers are still in the Lobby. '
        'Check your connection and press Start Show again.',
      );
      return;
    }

    // Stamp the camera-sync anchor (showStartedAt) into the room metadata.
    // Non-fatal: the show is live either way, but angles lose their alignment,
    // and this is also what kicks off the replay recording.
    final anchored = await _retry(
      () => LivekitService.startShow(eventId: _eventId!),
    );
    if (!anchored) {
      _toast(
        'You’re live, but the recording didn’t start. There may be no replay '
        'for this show.',
      );
    }
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
      cameraCaptureOptions: newEnabled ? _cameraCaptureOptions : null,
    );

    VideoTrack? newTrack;
    if (newEnabled) {
      final publication = _cameraPub(_room?.localParticipant);
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
      final track = _cameraPub(_room?.localParticipant)?.track;
      if (track is LocalVideoTrack) {
        var nowFront = newFront;
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
          // Android can't reopen the other lens while this one is still
          // releasing: getUserMedia falls back to the first device, so the old
          // camera came back and only the preview mirror flipped. The native
          // capturer switch has no such race and reports the resulting lens.
          nowFront = await rtc.Helper.switchCamera(track.mediaStreamTrack);
          // Keep the SDK's own options honest so a later mute/unmute or
          // republish doesn't snap back to the previous position.
          track.currentOptions = CameraCaptureOptions(
            cameraPosition:
                nowFront ? CameraPosition.front : CameraPosition.back,
            maxFrameRate: track.currentOptions.maxFrameRate,
            params: track.currentOptions.params,
          );
        } else {
          await track.setCameraPosition(
            newFront ? CameraPosition.front : CameraPosition.back,
          );
        }
        if (!mounted) return;
        setState(() {
          _isFrontCamera = nowFront;
          _selectedCameraId = null; // flipping means the built-in cameras
          _localVideoTrack = track;
        });
      } else {
        // No live track yet (video off) — fall back to a full republish.
        setState(() {
          _isFrontCamera = newFront;
          _selectedCameraId = null;
        });
        await _republishCamera();
      }
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
      // Stop the replay egress FIRST so the recording finalizes while the room
      // is still up. Best-effort; the egress_ended webhook and the hourly sweep
      // both cover a failure here.
      await _retry(() => LivekitService.stopEgress(eventId: _eventId!));

      final ended = await _retry(() => EventService.end(_eventId!));
      if (!ended) {
        // The row is still 'live' with a room nobody is publishing into. The
        // auto-end sweep will close it, but the host should know the show is
        // still showing as on-air until then.
        _toast(
          'Couldn’t mark the show as ended. It may still appear live for a few '
          'minutes — we’ll close it automatically.',
        );
      }
    }
    await _teardownRoom();
  }

  Future<void> _teardownRoom() async {
    _statusChannel?.unsubscribe();
    _statusChannel = null;
    _chatChannel?.unsubscribe();
    _chatChannel = null;
    _chatMessages.clear();
    // Stop screen capture explicitly — disconnect unpublishes the track but
    // doesn't always halt the native capturer promptly.
    try {
      await _screenShareTrack?.stop();
    } catch (_) {}
    _screenShareTrack = null;
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
      _remoteSources = const [];
      _selectedSourceId = null;
      _viewerCount = 0;
      _quality = NileStudioQuality.unknown;
      _hiddenSenders.clear();
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
    // The Studio replaces the full-bleed preview once there is desk-sized room
    // for it, and only while a session is up — the entry form and the
    // connecting spinner are the same at every width.
    final connected =
        _state == CameraState.soundCheck || _state == CameraState.live;
    final studio = _studioMode && connected;

    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: studio
          ? null
          : AppBar(
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
          if (studio)
            _buildStudio(context)
          else
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
          // The phone layout floats chat over the video; the Studio gives it a
          // column of its own, except when the window is too narrow for three,
          // where it falls back to the same overlay.
          if (studio && !_hasChatColumn(context) && _chatVisible)
            _buildChatOverlay(),
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
  Widget _buildCameraMeter({double height = 140}) {
    final source = _isMainAudioSource;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AudioMeter(
          participant: _room!.localParticipant!,
          height: height,
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

  /// Device menu for iPad/macOS: lists every attached camera plus a "Default"
  /// entry. The active source carries a check mark.
  Widget _buildCameraPickerButton() {
    return PopupMenuButton<String>(
      tooltip: 'Choose camera',
      // PopupMenuButton swallows null selections, so '' stands in for default.
      onSelected: (id) => _selectCamera(id.isEmpty ? null : id),
      color: NileColors.bgSurface,
      itemBuilder: (context) => [
        CheckedPopupMenuItem<String>(
          value: '',
          checked: _selectedCameraId == null,
          child: Text('Default camera', style: NileTextStyles.bodyMd()),
        ),
        for (final d in _videoInputs)
          CheckedPopupMenuItem<String>(
            value: d.deviceId,
            checked: _selectedCameraId == d.deviceId,
            child: Text(
              d.label.isNotEmpty ? d.label : 'Camera',
              style: NileTextStyles.bodyMd(),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      icon: const Icon(Icons.cameraswitch_outlined),
      iconColor: NileColors.txtPrimary,
      style: IconButton.styleFrom(
        backgroundColor: NileColors.bgSurface.withValues(alpha: 0.8),
        padding: const EdgeInsets.all(NileSpacing.s12),
      ),
    );
  }

  /// Read-only chat overlay — top-left under the status badge, newest at the
  /// bottom. Toggled by the chat button in the bottom controls.
  Widget _buildChatOverlay() {
    final size = MediaQuery.of(context).size;
    return Positioned(
      top: 56,
      left: 16,
      child: Container(
        width: (size.width * 0.6).clamp(180.0, 300.0),
        constraints: BoxConstraints(maxHeight: size.height * 0.35),
        padding: const EdgeInsets.symmetric(
          horizontal: NileSpacing.s8,
          vertical: NileSpacing.s6,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(NileRadius.sm),
        ),
        child: _chatMessages.isEmpty
            ? Text(
                'Chat is quiet — messages will appear here.',
                style: NileTextStyles.bodySm().copyWith(color: Colors.white54),
              )
            : ListView.builder(
                reverse: true,
                shrinkWrap: true,
                itemCount: _chatMessages.length,
                itemBuilder: (context, i) {
                  final m = _chatMessages[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: NileSpacing.s2,
                    ),
                    child: m.isSystem
                        ? Text(
                            m.content,
                            style: NileTextStyles.bodySm().copyWith(
                              color: NileColors.volt,
                              fontStyle: FontStyle.italic,
                            ),
                          )
                        : Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '@${m.username}  ',
                                  style: NileTextStyles.bodySm().copyWith(
                                    color: NileColors.volt,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                TextSpan(
                                  text: m.content,
                                  style: NileTextStyles.bodySm().copyWith(
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                  );
                },
              ),
      ),
    );
  }

  /// mm:ss countdown chip. Turns coral inside the last 2 minutes, and swaps to
  /// an "Ending stream…" beat once the host's device takes over at zero.
  Widget _buildCountdownPill() {
    final left = _remaining ?? Duration.zero;
    final urgent = left <= const Duration(minutes: 2);
    final label = _autoEnding
        ? 'Ending stream…'
        : '${left.inMinutes.toString().padLeft(2, '0')}:'
              '${(left.inSeconds % 60).toString().padLeft(2, '0')} left';
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: NileSpacing.s12,
        vertical: NileSpacing.s6,
      ),
      decoration: BoxDecoration(
        color: urgent ? NileColors.coral : Colors.black54,
        borderRadius: BorderRadius.circular(NileRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.timer_outlined, size: 14, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            label,
            style: NileTextStyles.labelSm().copyWith(
              color: Colors.white,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLive() {
    return Stack(
      children: [
        // ── Video preview or dark screen when video is off ─────────────
        if (_videoEnabled && _localVideoTrack != null)
          VideoTrackRenderer(
            _localVideoTrack!,
            // Mirror only the built-in selfie camera — an explicitly picked
            // external device is never mirrored.
            mirrorMode: _selectedCameraId == null && _isFrontCamera
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

        // ── Show countdown — top centre, crew only ─────────────────────
        // Appears for the last 10 minutes of the purchased duration so the
        // host and operators can wrap up. Viewers never see this screen.
        if (_remaining != null)
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: Center(child: _buildCountdownPill()),
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

        // ── Live chat overlay — toggleable, read-only ──────────────────
        if (_chatVisible) _buildChatOverlay(),

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
                  // Chat visibility toggle.
                  IconButton(
                    onPressed: () =>
                        setState(() => _chatVisible = !_chatVisible),
                    tooltip: _chatVisible ? 'Hide chat' : 'Show chat',
                    icon: Icon(
                      _chatVisible
                          ? Icons.chat_bubble
                          : Icons.chat_bubble_outline,
                    ),
                    color: _chatVisible
                        ? NileColors.volt
                        : NileColors.txtPrimary,
                    style: IconButton.styleFrom(
                      backgroundColor: NileColors.bgSurface.withValues(
                        alpha: 0.8,
                      ),
                      padding: const EdgeInsets.all(NileSpacing.s12),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Camera source — iPad/macOS get a device picker (external
                  // cameras); phones keep the front/back flip button.
                  if (!kIsWeb && _videoEnabled) ...[
                    if (_showCameraPicker(context))
                      _buildCameraPickerButton()
                    else
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
                  // Screen share — macOS + iPad (same gate as the camera
                  // picker: platforms where sharing is supported).
                  if (_showCameraPicker(context)) ...[
                    IconButton(
                      onPressed: _togglingShare ? null : _toggleScreenShare,
                      tooltip: _isSharingScreen
                          ? 'Stop sharing screen'
                          : 'Share screen',
                      icon: Icon(
                        _isSharingScreen
                            ? Icons.stop_screen_share
                            : Icons.screen_share,
                      ),
                      color: _isSharingScreen
                          ? Colors.white
                          : NileColors.txtPrimary,
                      style: IconButton.styleFrom(
                        backgroundColor: _isSharingScreen
                            ? NileColors.coral
                            : NileColors.bgSurface.withValues(alpha: 0.8),
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

  // ── Studio (desktop) ────────────────────────────────────────────────────────

  /// Three columns or two. Same rule as the app shell's context rail: below
  /// 1180 pt a third column costs the monitor more than the chat gains.
  bool _hasChatColumn(BuildContext context) =>
      NileBreakpoints.of(context).hasContextRail;

  Widget _buildStudio(BuildContext context) {
    final sources = [..._localSources, ..._remoteSources];
    final hasChat = _hasChatColumn(context);
    final live = _state == CameraState.live;
    final started = _startedAt;

    return NileStudio(
      sources: sources,
      selectedIdentity: _selectedSourceId,
      onSelectSource: (id) => setState(() => _selectedSourceId = id),
      selfIdentity: _room?.localParticipant?.identity,
      stats: NileStudioStats(
        isLive: live,
        elapsed: live && started != null
            ? DateTime.now().difference(started)
            : null,
        remaining: _remaining,
        autoEnding: _autoEnding,
        viewerCount: _viewerCount,
        readyCount: _readyCount,
        crewCount: _crew.length,
        // Placeholder rows for absent crew are roster entries, not feeds.
        cameraCount: sources
            .where((s) => !s.isScreenShare && !s.identity.startsWith('crew:'))
            .length,
        quality: _quality,
        audioSourceLabel: _audioSourceLabel,
      ),
      leading: IconButton(
        onPressed: _leaveStream,
        icon: const Icon(Icons.arrow_back),
        color: NileColors.txtPrimary,
        tooltip: 'Leave',
      ),
      trailing: IconButton(
        onPressed: _openAudioSettings,
        icon: const Icon(Icons.settings),
        color: NileColors.txtPrimary,
        tooltip: 'Audio settings',
      ),
      meter: _room?.localParticipant == null
          ? null
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [_buildCameraMeter(height: 120)],
            ),
      controls: _buildStudioControls(context, hasChat),
      showChatColumn: hasChat,
      chat: hasChat
          ? NileStudioChat(
              messages: _chatMessages,
              hiddenSenders: _hiddenSenders,
              blockedSenders: _blockedSenders,
              selfId: supabase.auth.currentUser?.id,
              onHide: _hideSender,
              onShowAll: _showAllSenders,
              onBlock: _blockSender,
              onReport: _reportSender,
            )
          : null,
      banner:
          _externalMicConnected && !_disableAgc && !_externalMicPromptDismissed
          ? _buildExternalMicBanner()
          : null,
    );
  }

  /// The Studio's control bar. Same actions, same handlers, same confirms as
  /// the phone layout — laid out as one bar instead of stacked pills, and in a
  /// `Wrap` so a narrow window folds to two rows rather than overflowing.
  Widget _buildStudioControls(BuildContext context, bool hasChatColumn) {
    final soundCheck = _state == CameraState.soundCheck;
    final live = _state == CameraState.live;

    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: NileSpacing.s12,
      runSpacing: NileSpacing.s8,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!hasChatColumn) ...[
              _studioIcon(
                onPressed: () => setState(() => _chatVisible = !_chatVisible),
                tooltip: _chatVisible ? 'Hide chat' : 'Show chat',
                icon: _chatVisible
                    ? Icons.chat_bubble
                    : Icons.chat_bubble_outline,
                active: _chatVisible,
              ),
              const SizedBox(width: NileSpacing.s8),
            ],
            if (!kIsWeb && _videoEnabled) ...[
              if (_showCameraPicker(context))
                _buildCameraPickerButton()
              else
                _studioIcon(
                  onPressed: _switchCamera,
                  tooltip: 'Switch camera',
                  icon: Icons.flip_camera_ios,
                ),
              const SizedBox(width: NileSpacing.s8),
            ],
            if (_showCameraPicker(context)) ...[
              _studioIcon(
                onPressed: _togglingShare ? null : _toggleScreenShare,
                tooltip: _isSharingScreen
                    ? 'Stop sharing screen'
                    : 'Share screen',
                icon: _isSharingScreen
                    ? Icons.stop_screen_share
                    : Icons.screen_share,
                active: _isSharingScreen,
              ),
              const SizedBox(width: NileSpacing.s8),
            ],
            // Video off is master-audio only: a camera that isn't carrying the
            // sound has nothing left to contribute with its lens covered.
            if (_isMasterAudio)
              OutlinedButton.icon(
                onPressed: _toggleVideo,
                icon: Icon(_videoEnabled ? Icons.videocam_off : Icons.videocam),
                label: Text(_videoEnabled ? 'Video Off' : 'Video On'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: NileColors.txtPrimary,
                  side: BorderSide(color: NileColors.borderStrong),
                  shape: const StadiumBorder(),
                ),
              ),
            if (!_isMasterAudio && soundCheck)
              OutlinedButton.icon(
                onPressed: _claimMasterAudio,
                icon: const Icon(Icons.album, size: 16),
                label: const Text('Set as Master Audio'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: NileColors.txtPrimary,
                  side: BorderSide(color: NileColors.borderStrong),
                  shape: const StadiumBorder(),
                ),
              ),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (soundCheck && widget.isHost) ...[
              OutlinedButton.icon(
                onPressed: _openViewerPreview,
                icon: const Icon(Icons.headphones),
                label: const Text('View as Viewer'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: NileColors.volt,
                  side: BorderSide(color: NileColors.volt),
                  shape: const StadiumBorder(),
                ),
              ),
              const SizedBox(width: NileSpacing.s12),
              FilledButton.icon(
                onPressed: _confirmStartShow,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start Show'),
                style: FilledButton.styleFrom(
                  backgroundColor: NileColors.coral,
                  foregroundColor: Colors.white,
                  shape: const StadiumBorder(),
                ),
              ),
              const SizedBox(width: NileSpacing.s12),
            ],
            if (soundCheck && !widget.isHost) ...[
              if (_ready)
                FilledButton.icon(
                  onPressed: _toggleReady,
                  icon: const Icon(Icons.check_circle),
                  label: const Text('Ready'),
                  style: FilledButton.styleFrom(
                    backgroundColor: NileColors.volt,
                    foregroundColor: NileColors.onVolt,
                    shape: const StadiumBorder(),
                  ),
                )
              else
                OutlinedButton.icon(
                  onPressed: _toggleReady,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Ready to Stream'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: NileColors.volt,
                    side: BorderSide(color: NileColors.volt),
                    shape: const StadiumBorder(),
                  ),
                ),
              const SizedBox(width: NileSpacing.s12),
            ],
            if (live && widget.isHost) ...[
              OutlinedButton.icon(
                onPressed: _confirmEndStream,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('End Stream'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: NileColors.error,
                  side: const BorderSide(color: NileColors.error),
                  shape: const StadiumBorder(),
                ),
              ),
              const SizedBox(width: NileSpacing.s12),
            ],
            OutlinedButton.icon(
              onPressed: _leaveStream,
              icon: const Icon(Icons.logout),
              label: const Text('Leave'),
              style: OutlinedButton.styleFrom(
                foregroundColor: NileColors.txtPrimary,
                side: BorderSide(color: NileColors.border),
                shape: const StadiumBorder(),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _studioIcon({
    required VoidCallback? onPressed,
    required String tooltip,
    required IconData icon,
    bool active = false,
  }) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon),
      color: active ? Colors.white : NileColors.txtPrimary,
      style: IconButton.styleFrom(
        backgroundColor: active ? NileColors.coral : NileColors.bgRaised,
      ),
    );
  }
}
