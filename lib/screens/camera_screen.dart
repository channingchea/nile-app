import 'dart:async';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' hide ChatMessage;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;
import '../services/supabase_client.dart';
import '../services/block_service.dart';
import '../services/camera_status.dart';
import '../services/chat_service.dart';
import '../services/chat_tools_service.dart';
import '../services/crew_service.dart';
import '../services/event_service.dart';
import '../services/ad_service.dart';
import '../services/brand_kit.dart';
import '../services/graphics_service.dart';
import '../services/profile_service.dart';
import '../services/share_urls.dart';
import '../services/install_id.dart';
import '../services/livekit_service.dart';
import '../services/live_elements.dart';
import '../services/overlay_layout.dart';
import '../services/server_clock.dart';
import '../services/studio_elements_controller.dart';
import '../services/layout_templates.dart';
import '../services/studio_layouts.dart';
import '../services/studio_layouts_controller.dart';
import '../services/realsync.dart';
import '../services/report_service.dart';
import '../services/screen_capture_permission.dart';
import '../services/shake_detector.dart';
import '../services/show_control.dart';
import '../services/studio_prefs.dart';
import '../services/studio_graphics.dart';
import '../services/studio_roles.dart';
import '../widgets/audio_meter.dart';
import '../widgets/elements/element_kinds.dart' show ElementInteraction;
import '../widgets/nile_studio.dart';
import '../widgets/screen_share_picker.dart';
import '../widgets/camera_slot_sheet.dart';
import '../widgets/nile_graphics_layer.dart';
import '../widgets/nile_link_text.dart';
import '../widgets/studio_chat_tools.dart';
import '../widgets/studio_element_hud.dart';
import '../widgets/studio_elements_panel.dart';
import '../widgets/studio_graphics_panel.dart';
import '../widgets/studio_layers_sheet.dart';
import '../widgets/studio_layouts_panel.dart';
import '../widgets/studio_settings_sheet.dart';
import '../widgets/viewer_preview_overlay.dart';
import '../router.dart';
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
    // The cue bar, monitor preview and Enter/Esc follow the cue.
    _cue.addListener(() {
      // One cue at a time: cueing a graphic clears a cued layout.
      if (_cue.value.isNotEmpty) _layouts.cue(null);
      if (mounted) setState(() {});
    });
    if (widget.initialEventId != null) {
      _eventIdController.text = widget.initialEventId!;
    }
    if (widget.initialCameraName != null) {
      _cameraNameController.text = widget.initialCameraName!;
    }
    unawaited(_prefsReady);
    _refreshMicDetection();
    _refreshVideoInputs();
    _deviceChangeSub = Hardware.instance.onDeviceChange.stream.listen((_) {
      _refreshMicDetection();
      _refreshVideoInputs();
    });
    // Launched from an event: skip the manual form. The host's desktop
    // Studio joins as the control room; the host's phone first asks "Which
    // camera is this?"; crew with a known slot connect straight into sound
    // check. The form stays as a fallback if a field is missing or the
    // connect fails. Runs after the first frame so `_studioMode` is known.
    if (widget.initialEventId?.isNotEmpty ?? false) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _state != CameraState.idle) return;
        if (widget.isHost) {
          _studioMode ? _enterSoundCheck() : _chooseSlotAndConnect();
        } else if (widget.initialCameraName?.isNotEmpty ?? false) {
          _enterSoundCheck();
        }
      });
    }
  }

  /// Studio choices saved on this device (Studio Preview writes the same keys).
  StudioPrefs? _prefs;
  late final Future<void> _prefsReady = _loadPrefs();

  /// Saved choices apply in the Studio only — the phone layout keeps the
  /// defaults it shipped with. Runs after `didChangeDependencies` has set
  /// [_studioMode], since the prefs read is never synchronous.
  Future<void> _loadPrefs() async {
    try {
      final prefs = await StudioPrefs.load();
      _prefs = prefs;
      if (!mounted || !_studioMode) return;
      setState(() {
        _disableAgc = prefs.externalMicProcessing;
        _chatVisible = prefs.chatVisible;
        _selectedCameraId = prefs.cameraDeviceId;
      });
      // Falls back to the default camera if the saved one isn't plugged in.
      await _refreshVideoInputs();
    } catch (_) {
      // No saved settings is the same as defaults.
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
      _audioInputs = devices;
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
    if (_studioMode) _prefs?.cameraDeviceId = deviceId;
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
          setState(() => _screenShareTrack = pub?.track as LocalVideoTrack?);
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

  /// The host's chat controls (#16 phase 5), read from the event row on
  /// connect. Held here only to draw the UI in the state the host left it —
  /// the `live-chat` function is what actually enforces all three.
  bool _chatCrewModeration = false;
  int _chatSlowModeSeconds = 0;
  String _chatAccess = 'everyone';
  bool _eventIsPaid = false;

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
  bool _isPublisher(Participant p) => NileRole.isPublisher(_metaOf(p)['role']);

  Map<String, dynamic> _metaOf(Participant p) =>
      parseParticipantMeta(p.metadata);

  /// Rebuild the crew half of the source list, in slot order: "Camera 1 —
  /// @user · iPhone · Ready", "Camera 3 — Open". Assigned crew who haven't
  /// connected are listed too — "camera 3 isn't here yet" is exactly what a
  /// host wants the roster to tell them. Feeds with no slot (older builds, an
  /// event without slots) follow the slots.
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
    final bySlot = <String, RemoteParticipant>{};
    final unslotted = <RemoteParticipant>[];
    final slotIds = {for (final s in _slots) s.id};

    for (final p in room.remoteParticipants.values) {
      if (!_isPublisher(p)) continue;
      final meta = _metaOf(p);
      final userId = meta['userId'] as String?;
      if (userId != null) connectedUserIds.add(userId);
      final slotId = meta['slotId'] as String?;
      if (slotId != null && slotIds.contains(slotId)) {
        bySlot[slotId] = p;
      } else {
        unslotted.add(p);
      }
    }

    final placedCrew = <String>{};
    // Cameras and element angles together, in the host's order.
    final angles = {
      for (final e in _isStudio ? _elementsCtl.angles : const <LiveElement>[])
        elementAngleId(e.id): e,
    };
    final slotsById = {for (final s in _slots) s.id: s};
    for (final id in _show.ordered([
      ...slotsById.keys,
      ...angles.keys,
    ], (id) => id)) {
      final angle = angles[id];
      if (angle != null) {
        sources.add(
          NileStudioSource(
            identity: id,
            label: angle.name,
            sublabel: 'Element angle',
            slotId: id,
            element: angle,
            isOffAir: _show.offAir.contains(id),
            isDefaultAngle: _show.defaultSlot == id,
            viewers: _viewersOn(id),
          ),
        );
        continue;
      }
      final slot = slotsById[id]!;
      if (slot.id == _slotId) continue; // this device — listed first, as yours
      final p = bySlot[slot.id];
      if (p != null) {
        sources.addAll(_feedSources(p, slotId: slot.id));
        continue;
      }
      final waiting = _crew
          .where(
            (op) =>
                !op.isAudioOperator &&
                op.slotIndex == slot.slotIndex &&
                !connectedUserIds.contains(op.profile.id),
          )
          .firstOrNull;
      if (waiting != null) placedCrew.add(waiting.profile.id);
      sources.add(
        NileStudioSource(
          identity: 'slot:${slot.id}',
          label: slot.label,
          sublabel: waiting == null
              ? 'Open'
              : '@${waiting.profile.username} · not connected',
          slotId: slot.id,
          isRenamable: true,
          isOffAir: _show.offAir.contains(slot.id),
          isDefaultAngle: _show.defaultSlot == slot.id,
        ),
      );
    }
    for (final p in unslotted) {
      sources.addAll(_feedSources(p));
    }

    for (final op in _crew) {
      if (connectedUserIds.contains(op.profile.id) ||
          placedCrew.contains(op.profile.id)) {
        continue;
      }
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

  /// One remote publisher's rows: its camera (or a "no video" row) and its
  /// screen share, if any.
  List<NileStudioSource> _feedSources(RemoteParticipant p, {String? slotId}) {
    final meta = _metaOf(p);
    final role = meta['role'];
    final isAudioOnly = role == NileRole.streamAudio;
    final ready = meta['ready'] == true;
    final name = isAudioOnly
        ? 'Stream Audio'
        : (meta['cameraName'] as String?) ??
              (p.name.isNotEmpty ? p.name : p.identity);
    final who = [
      if (meta['username'] != null) '@${meta['username']}',
      if (meta['device'] != null) meta['device'] as String,
    ];
    final isMaster = p.identity == _masterIdentity;
    final renamable = role == NileRole.camera || role == NileRole.studio;

    // Studio: what this phone last reported over the status link.
    final now = DateTime.now();
    final st = _isStudio && role == NileRole.camera
        ? _status.putIfAbsent(p.identity, () {
            _ensureStatusTicker();
            return _CamStatus(now);
          })
        : null;
    final health = st?.health;
    final level =
        st?.levelAt != null &&
            now.difference(st!.levelAt!) < StudioLink.levelStale
        ? st.level
        : null;
    final unsupported =
        st != null &&
        health == null &&
        now.difference(st.firstSeen) >= _statusGrace;
    final acked = st?.ackAt != null && now.difference(st!.ackAt!) < _ackShown;
    final quality = _remoteQuality[p.identity] ?? NileStudioQuality.unknown;
    final onAir = slotId == null || !_show.offAir.contains(slotId);
    final isDefault = slotId != null && _show.defaultSlot == slotId;

    final videoPubs = p.videoTrackPublications;
    final cameraPubs = videoPubs
        .where((pub) => pub.source != TrackSource.screenShareVideo)
        .toList();
    final out = <NileStudioSource>[];
    if (cameraPubs.isEmpty) {
      out.add(
        NileStudioSource(
          identity: p.identity,
          label: name,
          sublabel: [
            ...who,
            if (role == NileRole.studio) 'Control room' else 'No video',
          ].join(' · '),
          isMasterAudio: isMaster,
          isReady: ready,
          isRemovable: role != NileRole.studio,
          slotId: slotId,
          isRenamable: renamable && !isAudioOnly,
          isOffAir: !onAir,
          isDefaultAngle: isDefault,
          viewers: _viewersOn(slotId),
          level: level,
          health: health,
          statusUnsupported: unsupported,
          nudgeAcked: acked,
          connectionQuality: quality,
        ),
      );
    }
    for (final pub in videoPubs) {
      final isShare = pub.source == TrackSource.screenShareVideo;
      out.add(
        NileStudioSource(
          identity: isShare ? '${p.identity}#share' : p.identity,
          label: isShare ? '$name — screen' : name,
          sublabel: isShare
              ? 'Screen share'
              : [...who, ready ? 'Ready' : 'Standing by'].join(' · '),
          track: pub.subscribed ? pub.track as VideoTrack? : null,
          isScreenShare: isShare,
          isMasterAudio: !isShare && isMaster,
          isReady: !isShare && ready,
          // A share is a second feed from a participant, not a participant —
          // removing their camera row disconnects them and takes the share
          // with it, so offering it on both rows would only confuse.
          isRemovable: !isShare && role != NileRole.studio,
          slotId: isShare ? null : slotId,
          isRenamable: !isShare && renamable,
          // Only worth showing with more than one camera to compare.
          lagMs: isShare || _lagMs.length < 2 ? null : _lagMs[p.identity],
          isOffAir: !isShare && !onAir,
          isDefaultAngle: !isShare && isDefault,
          viewers: isShare ? null : _viewersOn(slotId),
          level: isShare ? null : level,
          health: isShare ? null : health,
          statusUnsupported: !isShare && unsupported,
          nudgeAcked: !isShare && acked,
          connectionQuality: quality,
        ),
      );
    }
    return out;
  }

  /// Your own camera and screen share, prepended to the roster. Derived in
  /// `build` because every field it reads already lives in `setState`.
  List<NileStudioSource> get _localSources {
    final local = _room?.localParticipant;
    if (local == null) return const [];
    final name = _cameraNameController.text.trim();
    final audio = _isMainAudioSource ? 'Broadcast audio' : 'Mic muted';
    final out = <NileStudioSource>[
      NileStudioSource(
        identity: local.identity,
        label: _isStudio
            ? (_videoEnabled ? 'Studio · $name' : 'Studio')
            : (name.isEmpty ? 'Your camera' : 'You · $name'),
        sublabel: _isStudio && !_videoEnabled ? 'Control room · $audio' : audio,
        track: _videoEnabled ? _localVideoTrack : null,
        isLocal: true,
        isMasterAudio: _isMainAudioSource,
        mirror: _selectedCameraId == null && _isFrontCamera,
        slotId: _slotId,
        isRenamable: _slotId != null,
        isOffAir: _isOffAir,
        isDefaultAngle: _slotId != null && _show.defaultSlot == _slotId,
        viewers: _viewersOn(_slotId),
        connectionQuality: _quality,
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
          connectionQuality: _quality,
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

  /// Who viewers are hearing right now — whichever publisher holds master
  /// audio (see [resolveMasterAudio]).
  String? get _audioSourceLabel {
    final id = _masterIdentity;
    if (id == null) return null;
    if (id == _room?.localParticipant?.identity) {
      return _isStudio ? 'Studio mic' : 'Your mic';
    }
    final p = _room?.remoteParticipants[id];
    if (p == null) return null;
    final meta = _metaOf(p);
    if (meta['role'] == NileRole.streamAudio) return 'Stream Audio';
    return (meta['cameraName'] as String?) ?? p.name;
  }

  // ── Chat moderation ─────────────────────────────────────────────────────────
  // Two tiers, and the menu labels say which is which.
  //
  // Hide and block change only what THIS host sees — block is persisted and
  // app-wide, but it is still one person's view. Before #16 they were the only
  // levers, which meant a host could believe they had dealt with a troll the
  // rest of the room was still watching.
  //
  // Remove and ban change the room. Both go through the `live-chat` function
  // against the message record from migration 0107, and every client drops the
  // line when the broadcast lands.

  /// True when this device may moderate the room, not just its own view. The
  /// host always; assigned crew only when the host turned crew moderation on
  /// for this show. The server re-checks — this only decides what to draw.
  bool get _canModerateChat => widget.isHost || _chatCrewModeration;

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

  /// Report the message itself when it has an id, so the review queue carries
  /// the actual text as evidence instead of "someone reported @x". Lines from
  /// clients that predate #16 carry no id — those still report the account,
  /// which is what every build did before this.
  Future<void> _reportSender(ChatMessage m) async {
    final id = m.id;
    if (id != null) {
      await Moderation.showReportSheet(
        context,
        targetType: ReportTargetType.liveChatMessage,
        targetId: id,
      );
      return;
    }
    if (m.senderId.isEmpty) return;
    await Moderation.showReportSheet(
      context,
      targetType: ReportTargetType.user,
      targetId: m.senderId,
    );
  }

  /// Remove one message for everyone.
  ///
  /// No confirm dialog, deliberately: it is a single line, an admin can restore
  /// it from the review queue, and a modal between seeing something and taking
  /// it down is a modal the audience reads over the host's shoulder. Ban is the
  /// one that asks.
  Future<void> _removeMessage(ChatMessage m) async {
    final eventId = _eventId;
    final id = m.id;
    if (eventId == null || id == null) return;
    try {
      await ChatService.removeMessage(eventId: eventId, messageId: id);
    } on ChatSendException catch (e) {
      _toast(e.message);
    }
  }

  /// Ban the sender from this show — confirmed, in the pattern of
  /// [_removeSource]. It is the one chat action with no undo in the app.
  Future<void> _banSender(ChatMessage m) async {
    final eventId = _eventId;
    if (eventId == null || m.senderId.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text('Ban @${m.username}?', style: NileTextStyles.headingMd()),
        content: Text(
          'Everything they have said is removed for everyone, they are '
          'disconnected from the show, and they cannot rejoin it. This applies '
          'to this show only, and cannot be undone here.',
          style: NileTextStyles.bodyMd(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Ban', style: TextStyle(color: NileColors.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ChatService.banSender(eventId: eventId, targetId: m.senderId);
      _toast('@${m.username} was banned from this show.');
    } catch (e) {
      _toast(
        e is ChatSendException ? e.message : 'Couldn’t ban them. Try again.',
      );
    }
  }

  /// The Studio's composer. Returns the error to show under the field.
  Future<String?> _sendChat(String text) async {
    final eventId = _eventId;
    if (eventId == null) return 'You’re not connected to the show.';
    try {
      // Non-null only when blocked words held it back: the sender still
      // sees their own copy.
      final own = await ChatService.send(eventId: eventId, content: text);
      if (own != null) _onChatMessage(own);
      return null;
    } on ChatSendException catch (e) {
      return e.message;
    }
  }

  /// Runs a moderation call, toasting its failure.
  Future<void> _moderate(Future<void> Function(String eventId) call) async {
    final eventId = _eventId;
    if (eventId == null) return;
    try {
      await call(eventId);
    } on ChatSendException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('That didn’t go through. Try again.');
    }
  }

  Future<void> _pinMessage(ChatMessage m) =>
      _moderate((id) => ChatService.pin(eventId: id, message: m));

  Future<void> _unpinMessage() =>
      _moderate((id) => ChatService.unpin(eventId: id));

  /// "Show anyway" on a line the blocked words held back. The release comes
  /// back over the broadcast with the same id and replaces the greyed line.
  Future<void> _releaseMessage(ChatMessage m) async {
    final messageId = m.id;
    if (messageId == null) return;
    await _moderate(
      (id) => ChatService.release(eventId: id, messageId: messageId),
    );
  }

  /// Moderators also hear what the blocked words held back.
  void _syncModChannel() {
    final eventId = _eventId;
    if (eventId == null || _modChannel != null || !_canModerateChat) return;
    // Poll totals waiting for their reveal come here, not to viewers.
    _modChannel = ChatService.subscribeModeration(
      eventId,
      _onChatMessage,
      onTally: _elementsCtl.setTally,
    );
  }

  Future<void> _loadQuickMessages() async {
    try {
      final list = await ChatToolsService.quickMessages();
      if (mounted) setState(() => _quickMessages = list);
    } catch (_) {
      // The ⚡ menu just stays empty.
    }
  }

  Future<void> _editQuickMessages() async {
    await showQuickMessagesEditor(context);
    await _loadQuickMessages();
  }

  /// One line describing how the host has narrowed the room, or null when they
  /// haven't. Drawn in the chat header: a throttled room looks exactly like a
  /// quiet one, and a host who forgot the setting reads the silence as a bug.
  String? get _chatRestrictionLabel {
    final parts = <String>[
      if (_chatSlowModeSeconds > 0) 'Slow mode · ${_chatSlowModeSeconds}s',
      if (_chatAccess == 'followers') 'Followers only',
      if (_chatAccess == 'ticket_holders') 'Ticket holders only',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// Read the host's chat controls off the event row. Once, on connect.
  ///
  /// A failed read leaves the UI showing "unrestricted", which is only a
  /// cosmetic lie — the server is the sole enforcer, so nothing gets past a
  /// gate because this didn't load.
  Future<void> _loadChatSettings(String slug) async {
    try {
      final row = await supabase
          .from('events')
          .select(
            'price, chat_crew_moderation, chat_slow_mode_seconds, chat_access',
          )
          .eq('livekit_room', slug)
          .maybeSingle();
      if (row == null || !mounted) return;
      setState(() {
        _eventIsPaid = ((row['price'] as num?) ?? 0) > 0;
        _chatCrewModeration = row['chat_crew_moderation'] as bool? ?? false;
        _chatSlowModeSeconds =
            (row['chat_slow_mode_seconds'] as num?)?.toInt() ?? 0;
        _chatAccess = row['chat_access'] as String? ?? 'everyone';
      });
      // Crew learn here whether they moderate this show.
      _syncModChannel();
    } catch (_) {}
  }

  /// Host: the three chat controls (#16 phase 5).
  ///
  /// Written through the `live-chat` function rather than straight to the row,
  /// so the validation sits next to the code that enforces it at send time —
  /// and so "this show is free, so there are no ticket holders" comes back as a
  /// sentence rather than a CHECK-constraint name.
  Future<void> _showChatSettings() async {
    final eventId = _eventId;
    if (eventId == null) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: NileColors.bgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(NileRadius.lg),
        ),
      ),
      builder: (_) => StatefulBuilder(
        builder: (sheetCtx, setSheet) {
          Future<void> apply(Map<String, dynamic> patch) async {
            final before = (
              _chatCrewModeration,
              _chatSlowModeSeconds,
              _chatAccess,
            );
            void write(Map<String, dynamic> p) {
              if (p.containsKey('crewModeration')) {
                _chatCrewModeration = p['crewModeration'] as bool;
              }
              if (p.containsKey('slowModeSeconds')) {
                _chatSlowModeSeconds = p['slowModeSeconds'] as int;
              }
              if (p.containsKey('access')) {
                _chatAccess = p['access'] as String;
              }
            }

            // Optimistic: a control that lags a network round trip feels
            // broken, and every one of these is trivially reversible.
            write(patch);
            setSheet(() {});
            if (mounted) setState(() {});
            try {
              await ChatService.updateSettings(eventId: eventId, patch: patch);
            } catch (e) {
              _chatCrewModeration = before.$1;
              _chatSlowModeSeconds = before.$2;
              _chatAccess = before.$3;
              setSheet(() {});
              if (mounted) setState(() {});
              _toast(
                e is ChatSendException ? e.message : 'Couldn’t save that.',
              );
            }
          }

          Widget chip(String label, bool selected, VoidCallback onTap) =>
              ChoiceChip(
                label: Text(label, style: NileTextStyles.bodySm()),
                selected: selected,
                onSelected: (_) => onTap(),
                backgroundColor: NileColors.bgRaised,
                selectedColor: NileColors.volt,
                showCheckmark: false,
              );

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(NileSpacing.s16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Chat settings', style: NileTextStyles.headingSm()),
                  const SizedBox(height: NileSpacing.s16),

                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _chatCrewModeration,
                    activeThumbColor: NileColors.volt,
                    title: Text(
                      'Crew can moderate',
                      style: NileTextStyles.bodyMd(),
                    ),
                    subtitle: Text(
                      'Your camera operators can remove messages and ban '
                      'viewers from this show. Off by default.',
                      style: NileTextStyles.caption().copyWith(
                        color: NileColors.txtTertiary,
                      ),
                    ),
                    onChanged: (v) => apply({'crewModeration': v}),
                  ),
                  const SizedBox(height: NileSpacing.s12),

                  Text('Slow mode', style: NileTextStyles.bodyMd()),
                  Text(
                    'How long each viewer waits between messages.',
                    style: NileTextStyles.caption().copyWith(
                      color: NileColors.txtTertiary,
                    ),
                  ),
                  const SizedBox(height: NileSpacing.s8),
                  Wrap(
                    spacing: NileSpacing.s8,
                    children: [
                      for (final s in const [0, 5, 10, 30])
                        chip(
                          s == 0 ? 'Off' : '${s}s',
                          _chatSlowModeSeconds == s,
                          () => apply({'slowModeSeconds': s}),
                        ),
                    ],
                  ),
                  const SizedBox(height: NileSpacing.s16),

                  Text('Who can chat', style: NileTextStyles.bodyMd()),
                  Text(
                    'Everyone can still read along — this only limits who can '
                    'send.',
                    style: NileTextStyles.caption().copyWith(
                      color: NileColors.txtTertiary,
                    ),
                  ),
                  const SizedBox(height: NileSpacing.s8),
                  Wrap(
                    spacing: NileSpacing.s8,
                    children: [
                      chip(
                        'Everyone',
                        _chatAccess == 'everyone',
                        () => apply({'access': 'everyone'}),
                      ),
                      chip(
                        'Followers',
                        _chatAccess == 'followers',
                        () => apply({'access': 'followers'}),
                      ),
                      // A free show sells no tickets, so this would mute the
                      // whole room. The server refuses it too; not offering it
                      // is the version the host doesn't have to discover.
                      if (_eventIsPaid)
                        chip(
                          'Ticket holders',
                          _chatAccess == 'ticket_holders',
                          () => apply({'access': 'ticket_holders'}),
                        ),
                    ],
                  ),
                  const SizedBox(height: NileSpacing.s8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.block, color: NileColors.txtPrimary),
                    title: Text(
                      'Blocked words…',
                      style: NileTextStyles.bodyMd(),
                    ),
                    subtitle: Text(
                      'Messages containing them are hidden from everyone but '
                      'the sender.',
                      style: NileTextStyles.caption().copyWith(
                        color: NileColors.txtTertiary,
                      ),
                    ),
                    onTap: () => showBlockedWordsEditor(context),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// This device is the broadcast audio source only when the one master-audio
  /// rule ([resolveMasterAudio]) picks it — the same rule viewers route by.
  /// The server keeps the flag on exactly one publisher (camera, Studio or
  /// Stream Audio), so every other mic mutes in its favour.
  bool get _isMainAudioSource =>
      _masterIdentity != null &&
      _masterIdentity == _room?.localParticipant?.identity;

  /// Re-read who is in the room: the master-audio holder, whether Stream Audio
  /// is up, and whether a Studio is running the show. Called on connect and on
  /// every participant join/leave/metadata change; cheap enough for that, too
  /// much to do per frame in a room with hundreds of viewers.
  void _refreshRoomState() {
    final room = _room;
    if (room == null) return;
    final publishers = <PublisherInfo>[];
    var studio = false;
    String? studioIdentity;
    var otherHostDevice = false;
    final uid = supabase.auth.currentUser?.id;
    for (final p in room.remoteParticipants.values) {
      final meta = _metaOf(p);
      final role = meta['role'];
      if (!NileRole.isPublisher(role)) continue;
      publishers.add(PublisherInfo.fromMeta(p.identity, meta));
      if (role == NileRole.studio) {
        studio = true;
        studioIdentity = p.identity;
      }
      if (uid != null && meta['userId'] == uid) otherHostDevice = true;
    }
    final local = room.localParticipant;
    if (local != null) {
      publishers.add(PublisherInfo.fromMeta(local.identity, _metaOf(local)));
    }
    final master = resolveMasterAudio(publishers);
    if (mounted) {
      setState(() {
        _masterIdentity = master;
        _otherHostDevice = otherHostDevice;
      });
    }
    _studioIdentity = studioIdentity;
    _syncStatusLink();
    // A Studio never hands itself over; only the host's phones step aside.
    if (widget.isHost && !_isStudio) {
      _handover.update(studioPresent: studio);
    }
  }

  /// The handover flipped: a Studio arrived (this phone becomes an operator)
  /// or has been gone for the grace period (this phone runs the show again).
  void _onHandoverChange() {
    if (!mounted || _room == null) return;
    setState(() {});
    _toast(
      _handover.studioInCharge
          ? 'Your Studio is running this show. This phone is now a camera.'
          : 'Your Studio disconnected. This phone can run the show again.',
    );
  }

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
        AudioCaptureOptions(
          deviceId: _selectedMicId,
          autoGainControl: false,
          noiseSuppression: false,
          echoCancellation: false,
        ),
      );
      await participant.publishAudioTrack(audioTrack);
    } else {
      await participant.setMicrophoneEnabled(
        true,
        audioCaptureOptions: AudioCaptureOptions(deviceId: _selectedMicId),
      );
    }
    await _syncMicEnabled();
  }

  /// Mute every camera that isn't the active broadcast audio source; unmute the
  /// one that is. The capture track keeps running either way (so the local meter
  /// still moves), but a muted track sends silence — only the main source's
  /// audio reaches viewers, which kills the multi-mic feedback. Called on
  /// connect and whenever the source reassigns (metadata / participant changes).
  Future<void> _syncMicEnabled() async {
    // A muted phone meters through its own track for the Studio.
    unawaited(_syncMeterTrack());
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
    if (_studioMode) _prefs?.externalMicProcessing = enabled;
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

  // Master audio: the resolved holder for the whole room (see
  // [resolveMasterAudio]); this device carries the sound when it is us.
  String? _masterIdentity;
  bool _videoEnabled = true;

  // ── Studio master host ──────────────────────────────────────────────────
  // The host's desktop Studio joins as the show's control room (studio-token),
  // not as a camera. While it is in the room the host's phones are camera
  // operators; `_handover` gives them the controls back 30s after it leaves.

  /// This device joined as the Studio.
  bool _isStudio = false;

  /// Another of the host's own devices is publishing (a phone running a
  /// camera). The Studio leaving Sound Check doesn't cancel the show then.
  bool _otherHostDevice = false;

  late final StudioHandover _handover = StudioHandover(
    onChange: _onHandoverChange,
  );

  /// True when this device holds the show's controls: Start/End Show, the
  /// crew panel, auto-end at the time limit. The Studio when there is one;
  /// otherwise the host's phone, as it always was.
  bool get _runsShow =>
      widget.isHost && (_isStudio || !_handover.studioInCharge);

  /// The camera slot this device holds (event_cameras.id), if any.
  String? _slotId;

  /// The event's camera slots, in order — the Studio lists sources by them.
  List<CameraSlot> _slots = const [];

  /// Graphics on air (room metadata `graphics`). The Studio monitor and this
  /// device's own preview draw what a viewer of that camera sees.
  GraphicsState _graphics = GraphicsState.empty;

  /// Studio: where each library graphic last went (its hotkey reuses it), the
  /// library itself (keys 1–9), and the auto-hide timer for [_graphics].
  final Map<String, GraphicTargets> _lastTargets = {};
  List<StudioGraphic> _graphicsLibrary = const [];

  /// Studio: the graphic waiting for Apply (cue before air), the host's brand
  /// kit (attached to every push), the show's sponsor as a built-in graphic,
  /// and the host's username for "Your profile" QR codes.
  final _cue = ValueNotifier<CueSet>(CueSet.empty);
  bool _taking = false;
  BrandKit? _brandKit;
  StudioGraphic? _sponsorItem;
  String? _hostUsername;
  Timer? _hideTimer;
  int? _hideArmedFor;

  /// Live elements on air (room metadata `elements`) and where everything
  /// sits on each camera (`layout`) — studio live elements.
  ElementsState _elements = ElementsState.empty;
  OverlayLayout _layout = OverlayLayout.empty;

  /// Studio: every element in this show, applied at once and pushed in order.
  late final StudioElementsController _elementsCtl = StudioElementsController(
    push: (e, ops) => LivekitService.setElement(
      eventId: _eventId!,
      element: e,
      clockOps: ops,
      srcAgeMs: _monitorAgeMs,
    ),
    load: () => LivekitService.listElements(eventId: _eventId!),
    removeRemote: (id) =>
        LivekitService.removeElement(eventId: _eventId!, id: id),
    onError: (msg) => _toast(msg),
  )..addListener(_onElementsChanged);

  /// Studio: saved layouts — the cued one and the one on air.
  late final StudioLayoutsController _layouts = StudioLayoutsController(
    current: _showNow,
    build: _layoutGraphic,
    send: _sendLayout,
    kit: () => _brandKit?.style,
    onCue: () => _cue.value = CueSet.empty,
  )..addListener(_onLayoutsChanged);

  /// Studio, RealSync measuring: how old each camera's picture is here. The
  /// monitor's one goes with every push so viewers further behind hold the
  /// change back to match.
  Map<String, double> _sourceAgesMs = const {};

  /// Show control from room metadata: off air, default angle, camera order.
  ShowControl _show = ShowControl.empty;

  /// Studio: signed-in viewers per slot, polled. Null until the first poll.
  Map<String, int>? _angleCounts;
  Timer? _angleTimer;

  /// The event's scheduled start — countdowns can run to it.
  DateTime? _scheduledAt;

  // ── Status link (studio-edits phases 6-7) ─────────────────────────────────
  // Studio side: what each phone last reported, its LiveKit connection
  // quality, and the alerts they raise. Rebuilt by a short ticker while
  // anything on a tile is time-sensitive, never per packet.
  static const _statusTick = Duration(milliseconds: 250);
  static const _statusGrace = Duration(seconds: 12);
  static const _ackShown = Duration(seconds: 10);
  final Map<String, _CamStatus> _status = {};
  final Map<String, NileStudioQuality> _remoteQuality = {};
  CameraAlerts _alerts = CameraAlerts();
  Timer? _statusTicker;

  // Phone side: the Studio to report to, the send timers, a private meter for
  // a muted mic, the camera state the Studio can change, and its nudge.
  String? _studioIdentity;
  Timer? _levelTimer;
  Timer? _healthTimer;
  LocalAudioTrack? _meterTrack;
  AudioVisualizer? _meterViz;
  double? _meterLevel;
  bool _meterOpening = false;
  bool _meterFailed = false;
  bool _torchOn = false;
  double _zoom = 1;
  bool _focusLocked = false;
  bool _exposureLocked = false;
  ({String id, String text})? _nudge;

  /// Resync stamp this device joined with; a new one makes the Studio
  /// monitor re-pick up the feed it is showing.
  int? _seenResyncAt;

  /// Publishers seen this session, so a camera coming BACK mid-show can be
  /// told apart from one joining for the first time.
  final Set<String> _seenPublishers = {};

  /// RealSync 7b: this device's clock offset, reported into its metadata.
  ClockReporter? _clock;

  /// RealSync 7e (Studio): each camera's lag behind the most current one.
  Map<String, int> _lagMs = const {};
  Timer? _lagTimer;
  final ContentAgeReader _lagAges = ContentAgeReader();

  /// "Camera 2 reconnected · Resync?" — the Studio's nudge after a drop.
  String? _reconnectHint;
  Timer? _hintTimer;

  /// The mic this device publishes. Null = system default. The Studio offers a
  /// picker for a USB mixer or audio interface when it carries the show audio.
  String? _selectedMicId;
  List<MediaDevice> _audioInputs = const [];

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

  /// Start Show reported that the replay egress never came up. Sticky for the
  /// rest of the session: there is no recovery mid-show, and the host needs to
  /// know now rather than discovering it when they go to sell the replay.
  bool _notRecording = false;

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
        _scheduledAt = sched == null ? null : DateTime.tryParse(sched);
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
    // A poor connection only alerts once it has lasted 10 s; quality events
    // fire on change, so re-check here rather than run another timer.
    if (_isStudio) _recheckSignal();
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

    // Time's up. Only the device running the show ends it — operator devices
    // (and the host's phones while the Studio is in charge) just watch the
    // room close when the status flips.
    if (!_runsShow) return;
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

  /// Read-only topic for server-authored announcements (migration 0099).
  RealtimeChannel? _systemChannel;

  /// Moderators: lines the host's blocked words held back.
  RealtimeChannel? _modChannel;
  final List<ChatMessage> _chatMessages = [];
  bool _chatVisible = true;
  PinnedMessage? _pinned;
  List<QuickMessage> _quickMessages = const [];

  /// Inserts [m], or replaces the line with the same id — a released or
  /// re-delivered message must not appear twice.
  void _onChatMessage(ChatMessage m) {
    if (!mounted) return;
    setState(() {
      final i = m.id == null
          ? -1
          : _chatMessages.indexWhere((x) => x.id == m.id);
      if (i >= 0) {
        _chatMessages[i] = m;
        return;
      }
      _chatMessages.insert(0, m);
      if (_chatMessages.length > _maxChatMessages) {
        _chatMessages.removeLast();
      }
    });
  }

  /// A message was removed for everyone (#16 phase 1). Silent here too — the
  /// host who just removed it does not need a receipt in the transcript.
  void _onChatRemove(String messageId) {
    if (!mounted) return;
    setState(() => _chatMessages.removeWhere((m) => m.id == messageId));
  }

  /// Somebody was banned: everything they said goes, not just the one line.
  void _onChatRemoveSender(String senderId) {
    if (senderId.isEmpty || !mounted) return;
    setState(() => _chatMessages.removeWhere((m) => m.senderId == senderId));
  }

  /// What this host should see, after their own hides and blocks. Derived here
  /// so the phone overlay and the Studio column cannot disagree about it.
  List<ChatMessage> get _visibleChatMessages => [
    for (final m in _chatMessages)
      if (m.isSystem ||
          !(_hiddenSenders.contains(m.senderId) ||
              _blockedSenders.contains(m.senderId)))
        m,
  ];

  @override
  void dispose() {
    _cue.dispose();
    _elementsCtl.dispose();
    _layouts.dispose();
    ShakeDetector.instance.resume();
    // A drop or back-swipe never ends a live show anymore — the show stays
    // 'live' and viewers' resilience logic treats it as reconnect-and-wait.
    // Ending only ever happens via the explicit End Stream confirm path.
    // The HOST leaving during Sound Check (show never started) still reverts
    // the event to scheduled; an operator leaving must not.
    if (_eventId != null && _revertsOnLeave) {
      EventService.revertToScheduled(_eventId!).catchError((_) {});
    }
    _handover.dispose();
    _hintTimer?.cancel();
    _lagTimer?.cancel();
    _lagAges.dispose();
    _clock?.stop();
    _countdownTimer?.cancel();
    _hideTimer?.cancel();
    _angleTimer?.cancel();
    _statusTicker?.cancel();
    _stopStatusLink();
    _statusChannel?.unsubscribe();
    _chatChannel?.unsubscribe();
    _systemChannel?.unsubscribe();
    _modChannel?.unsubscribe();
    _deviceChangeSub?.cancel();
    _eventIdController.dispose();
    _cameraNameController.dispose();
    _listener?.dispose();
    _room?.disconnect();
    super.dispose();
  }

  /// Connect the camera/mic and enter Sound Check — the host/operator can now
  /// test devices, but viewers stay in the Lobby until [_startShow] is pressed.
  ///
  /// The host on a desk-sized window joins as the Studio — the control room,
  /// webcam off — rather than as a camera. [slot] is the host phone's answer
  /// to "Which camera is this?".
  Future<void> _enterSoundCheck({CameraSlot? slot}) async {
    final eventId = _eventIdController.text.trim();
    if (slot != null) _cameraNameController.text = slot.label;
    final cameraName = _cameraNameController.text.trim();
    final asStudio = widget.isHost && _studioMode;
    final device = nileDeviceLabel(context);
    // The saved camera and mic mode must be in place before the first publish.
    await _prefsReady;

    if (eventId.isEmpty || (cameraName.isEmpty && !asStudio)) {
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
      final conn = asStudio
          ? await LivekitService.studioToken(eventId: eventId, device: device)
          : await LivekitService.cameraToken(
              eventId: eventId,
              // Stable per install, not per launch. A crashed or force-quit
              // app relaunches under the same LiveKit identity, so it evicts
              // its own ghost rather than being counted as an additional
              // camera and turned away by the camera-limit check, and it
              // keeps its slot. See InstallId.
              cameraId: await InstallId.get(),
              cameraName: cameraName,
              // Ask for the Studio's monitor grant. Safe to ask
              // unconditionally: we connect with autoSubscribe off and
              // subscribe only while the Studio is on screen, and the server
              // ignores the request from non-hosts.
              monitor: widget.isHost,
              // An event without slots offers a placeholder with no id.
              slotId: (slot?.id.isEmpty ?? true) ? null : slot!.id,
              device: device,
            );
      final token = conn.token;
      final wsUrl = conn.wsUrl;

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
        final meta = _metaOf(event.participant);
        if (event.participant.identity == _room?.localParticipant?.identity) {
          // The Studio renamed this camera, or moved master audio to/from it.
          final name = meta['cameraName'] as String?;
          if (name != null && name != _cameraNameController.text) {
            _cameraNameController.text = name;
            if (!_isStudio) _toast('This camera is now “$name”.');
          }
          _slotId = meta['slotId'] as String?;
        }
        setState(() => _applyReadyMeta(meta));
        _refreshRoomState();
        // The master-audio flag may have moved to/from this device.
        _syncMicEnabled();
        // Ready ticks, names and the master-audio badge live on the tiles.
        _rebuildRemoteSources();
      });

      listener.on<ParticipantConnectedEvent>((event) {
        _noteReconnect(event.participant);
        setState(() => _applyReadyMeta(_metaOf(event.participant)));
        _refreshRoomState();
        _syncMicEnabled();
        _syncSubscriptions();
        _rebuildRemoteSources();
      });

      listener.on<RoomMetadataChangedEvent>(
        (e) => _applyRoomMetadata(e.metadata),
      );

      // A second Studio for the same show takes over the control room —
      // LiveKit drops the older session with DUPLICATE_IDENTITY.
      listener.on<RoomDisconnectedEvent>((event) {
        if (event.reason != DisconnectReason.duplicateIdentity) return;
        _teardownRoom().then((_) {
          if (!mounted) return;
          setState(
            () => _errorMessage = asStudio
                ? 'This show’s Studio was opened on another device.'
                : 'This camera connected from another window.',
          );
        });
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
          final q = _mapQuality(event.connectionQuality);
          final p = event.participant;
          if (p.identity == _room?.localParticipant?.identity) {
            setState(() => _quality = q);
            return;
          }
          // Studio: each camera's own signal, for its tile and alerts.
          if (!_isStudio || !_isPublisher(p)) return;
          _remoteQuality[p.identity] = q;
          _checkAlerts(p.identity);
          _rebuildRemoteSources();
        })
        // Studio ↔ phone status link and commands (camera_status.dart).
        ..on<DataReceivedEvent>((event) {
          final from = event.participant;
          if (from == null) return;
          if (event.topic == StudioLink.statusTopic) {
            _onStatus(from, event.data);
          } else if (event.topic == StudioLink.commandTopic) {
            _obeyCommand(from, event.data);
          }
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
        // A dropped crew member is no longer ready — a fresh token on rejoin
        // re-stamps ready: false server-side anyway.
        final userId = _metaOf(event.participant)['userId'] as String?;
        if (userId != null) setState(() => _crewReady[userId] = false);
        final gone = event.participant.identity;
        _alerts.forget(gone);
        _status.remove(gone);
        _remoteQuality.remove(gone);
        // The master-audio holder may have left (the fallback takes over), or
        // the Studio did (its handover grace starts).
        _refreshRoomState();
        _syncMicEnabled();
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
      // The Studio is a control room first: its own webcam stays off until
      // the host turns it on ("Use this Mac's camera").
      if (!asStudio) {
        await room.localParticipant
            ?.setCameraEnabled(
              true,
              cameraCaptureOptions: _cameraCaptureOptions,
            )
            .timeout(
              const Duration(seconds: 15),
              onTimeout: () => throw Exception(
                'Camera timed out. Check camera permissions.',
              ),
            );
      }
      await _applyMicProcessing(room.localParticipant);

      final publication = _cameraPub(room.localParticipant);
      final track = publication?.track;

      _crewReady.clear();
      for (final p in room.remoteParticipants.values) {
        _applyReadyMeta(_metaOf(p));
      }

      setState(() {
        _room = room;
        _listener = listener;
        _localVideoTrack = track as VideoTrack?;
        _isStudio = asStudio;
        _slotId = conn.slotId;
        if (!asStudio && conn.cameraName != null) {
          _cameraNameController.text = conn.cameraName!;
        }
        _videoEnabled = !asStudio;
        _eventId = eventId;
        _cameraIdentity = room?.localParticipant?.identity;
        _ready = false; // metadata always starts ready: false at token-issue
        _state = CameraState.soundCheck;
      });

      // Reconcile mute now that the real master-audio/Stream-Audio state is set
      // (the sync inside _applyMicProcessing ran before this setState).
      _refreshRoomState();
      _applyRoomMetadata(room.metadata, joining: true);
      _clock?.stop();
      _clock = ClockReporter(
        eventId: eventId,
        identity: room.localParticipant!.identity,
        participant: room.localParticipant,
      )..start();
      if (asStudio) _startLagReadout();
      _seenPublishers
        ..clear()
        ..addAll(
          room.remoteParticipants.values
              .where(_isPublisher)
              .map((p) => p.identity),
        );
      await _syncMicEnabled();

      // "Start with camera off", set in the Studio's settings sheet. The
      // Studio itself always starts with its camera off.
      if (_studioMode && !asStudio && (_prefs?.videoStartsOff ?? false)) {
        await _toggleVideo();
      }
      if (asStudio) {
        _loadSlots(eventId);
        // Hotkeys 1–9 work before the Graphics panel is ever opened.
        GraphicsService.list()
            .then((l) => _graphicsLibrary = l)
            .catchError((_) => _graphicsLibrary);
        _loadGraphicsExtras(eventId);
        // Elements pick up exactly where they were if the Studio dropped.
        unawaited(ServerClock.ensure());
        unawaited(_elementsCtl.restore());
        _angleTimer?.cancel();
        _angleTimer = Timer.periodic(AngleWatchers.poll, (_) => _pollAngles());
        _pollAngles();
      }

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
      // The removal callbacks keep the Studio honest: whatever a host removes
      // has to leave their own view too, or they will remove it twice.
      _chatChannel = ChatService.subscribe(
        eventId,
        _onChatMessage,
        onRemove: _onChatRemove,
        onRemoveSender: _onChatRemoveSender,
      );
      // Server-authored announcements (tips) come in on their own read-only
      // topic — the host should see them in the Studio too.
      _systemChannel = ChatService.subscribeSystem(
        eventId,
        _onChatMessage,
        onPin: (p) {
          if (mounted) setState(() => _pinned = p);
        },
        // Live element totals (viewer taps) — the Elements panel shows them.
        onTally: _elementsCtl.setTally,
      );
      ChatService.fetchPinned(eventId).then((p) {
        if (mounted && _pinned == null) setState(() => _pinned = p);
      });
      _syncModChannel();
      if (widget.isHost) _loadQuickMessages();

      // How the host has set this room up — crew moderation, slow mode, who
      // may speak. Only drives what we draw; the server enforces it.
      _loadChatSettings(eventId);

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
                if (_isStudio) _anchorShow();
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
              // Started from elsewhere (a host phone on an older build). Make
              // sure the sync anchor and the replay recording exist.
              if (_isStudio) _anchorShow();
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

  // ── Status link: Studio side ────────────────────────────────────────────────

  /// A phone's level, health or nudge 👍.
  void _onStatus(RemoteParticipant from, List<int> data) {
    if (!_isStudio) return;
    final msg = StatusMessage.decode(data);
    if (msg == null) return;
    final now = DateTime.now();
    final s = _status.putIfAbsent(from.identity, () => _CamStatus(now));
    switch (msg) {
      case LevelMessage(:final level):
        s
          ..level = level
          ..levelAt = now;
      case HealthMessage(:final health):
        s.health = health;
        _checkAlerts(from.identity);
        _rebuildRemoteSources();
      case AckMessage():
        s.ackAt = now;
        _rebuildRemoteSources();
    }
    _ensureStatusTicker();
  }

  /// True while a tile has something time-sensitive: a live meter, a recent
  /// 👍, or a camera still inside its grace period for reporting health.
  bool get _statusLive {
    final now = DateTime.now();
    bool within(DateTime? t, Duration d) =>
        t != null && now.difference(t) < d + _statusTick;
    return _status.values.any(
      (s) =>
          within(s.levelAt, StudioLink.levelStale) ||
          within(s.ackAt, _ackShown) ||
          (s.health == null && within(s.firstSeen, _statusGrace)),
    );
  }

  /// Rebuilds the tiles a few times a second while [_statusLive], then stops.
  void _ensureStatusTicker() {
    if (_statusTicker != null || !_isStudio) return;
    _statusTicker = Timer.periodic(_statusTick, (_) {
      if (!mounted || _room == null || !_statusLive) {
        _statusTicker?.cancel();
        _statusTicker = null;
      }
      _rebuildRemoteSources();
    });
  }

  bool _poorSignal(String identity) => switch (_remoteQuality[identity]) {
    NileStudioQuality.poor || NileStudioQuality.lost => true,
    _ => false,
  };

  void _recheckSignal() {
    for (final id in _remoteQuality.keys.where(_poorSignal).toList()) {
      _checkAlerts(id);
    }
  }

  /// Feeds [CameraAlerts] and toasts each alert that just started.
  void _checkAlerts(String identity) {
    final fired = _alerts.update(
      identity,
      health: _status[identity]?.health,
      poorSignal: _poorSignal(identity),
      now: DateTime.now(),
    );
    for (final kind in fired) {
      _alertToast(identity, kind);
    }
  }

  void _alertToast(String identity, CameraAlertKind kind) {
    if (!mounted) return;
    final p = _room?.remoteParticipants[identity];
    final name = p == null
        ? 'A camera'
        : (_metaOf(p)['cameraName'] as String?) ??
              (p.name.isNotEmpty ? p.name : 'A camera');
    final text = switch (kind) {
      CameraAlertKind.battery =>
        '$name battery is at ${_status[identity]?.health?.battery ?? 0}%',
      CameraAlertKind.heat => '$name is running hot',
      CameraAlertKind.signal => '$name has a poor connection',
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 8),
        showCloseIcon: true,
        action: kind == CameraAlertKind.battery
            ? SnackBarAction(
                label: 'Send ‘${NudgePresets.chargeSoon}’',
                onPressed: () => _sendNudge(identity, NudgePresets.chargeSoon),
              )
            : null,
      ),
    );
  }

  /// Studio → one phone: a nudge or a remote control, reliable.
  Future<void> _sendCommand(String identity, StudioCommand command) async {
    final local = _room?.localParticipant;
    if (local == null) return;
    try {
      await local.publishData(
        command.encode(),
        reliable: true,
        destinationIdentities: [identity],
        topic: StudioLink.commandTopic,
      );
    } catch (_) {
      _toast('Couldn’t reach that camera. Try again.');
    }
  }

  Future<void> _sendNudge(String identity, String text) {
    final clean = cleanNudge(text);
    if (clean.isEmpty) return Future.value();
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    return _sendCommand(identity, NudgeCommand(id, clean));
  }

  // ── Status link: camera side ────────────────────────────────────────────────
  // A camera phone reports to the Studio — and only to it — while one is in
  // the room: mic level ~8×/s and health every 5 s, both lossy.

  bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  /// Zoom and focus/exposure lock need a phone's built-in camera.
  bool get _builtInCamera => _isMobile && _selectedCameraId == null;

  rtc.MediaStreamTrack? get _cameraTrack =>
      _cameraPub(_room?.localParticipant)?.track?.mediaStreamTrack;

  /// Whether viewers hear this mic right now (the published track is live).
  bool get _micLive => _isMainAudioSource && !_viewerPreviewOpen;

  bool get _isOffAir => _slotId != null && _show.offAir.contains(_slotId);

  /// Start or stop reporting as the Studio joins and leaves.
  void _syncStatusLink() {
    if (_isStudio || _room == null || _studioIdentity == null) {
      _stopStatusLink();
      return;
    }
    if (_healthTimer == null) {
      _levelTimer = Timer.periodic(StudioLink.levelEvery, (_) => _sendLevel());
      _healthTimer = Timer.periodic(
        StudioLink.healthEvery,
        (_) => _sendHealth(),
      );
      unawaited(_sendHealth());
    }
    unawaited(_syncMeterTrack());
  }

  void _stopStatusLink() {
    _levelTimer?.cancel();
    _healthTimer?.cancel();
    _levelTimer = null;
    _healthTimer = null;
    unawaited(_closeMeterTrack());
  }

  void _sendStatus(StatusMessage message, {bool reliable = false}) {
    final to = _studioIdentity;
    final local = _room?.localParticipant;
    if (to == null || local == null) return;
    local
        .publishData(
          message.encode(),
          reliable: reliable,
          destinationIdentities: [to],
          topic: StudioLink.statusTopic,
        )
        .catchError((_) {});
  }

  /// The published mic's level when it is live; otherwise the private
  /// meter's. Nothing at all when neither has a reading.
  void _sendLevel() {
    final level = _micLive ? _room?.localParticipant?.audioLevel : _meterLevel;
    if (level != null) _sendStatus(LevelMessage(level));
  }

  Future<void> _sendHealth() async {
    if (_isStudio || _studioIdentity == null) return;
    final device = await DeviceStatus.read();
    final track = _videoEnabled ? _cameraTrack : null;
    int? width, height;
    double? fps;
    var torch = false;
    if (track != null) {
      try {
        final s = track.getSettings();
        width = (s['width'] as num?)?.toInt();
        height = (s['height'] as num?)?.toInt();
        fps = (s['frameRate'] as num?)?.toDouble();
      } catch (_) {}
      try {
        torch = await track.hasTorch();
      } catch (_) {}
    }
    if (!mounted) return;
    final lens = track != null && _builtInCamera;
    _sendStatus(
      HealthMessage(
        CameraHealth(
          battery: device.battery,
          charging: device.charging,
          thermal: device.thermal,
          width: width,
          height: height,
          fps: fps,
          caps: CameraCaps(
            torch: torch,
            zoom: lens,
            focusLock: lens,
            exposureLock: lens,
            flip: _isMobile,
          ),
          torchOn: _torchOn,
          zoom: _zoom,
          focusLocked: _focusLocked,
          exposureLocked: _exposureLocked,
        ),
      ),
    );
  }

  /// Non-master cameras mute their published mic, which stops its capture,
  /// so they meter through a private, never-published track instead (phase
  /// 6a: unverified on hardware). Gives up for the session if it can't open.
  Future<void> _syncMeterTrack() async {
    final want = _levelTimer != null && !_micLive && !_meterFailed;
    if (_meterOpening || want == (_meterTrack != null)) return;
    if (!want) return _closeMeterTrack();
    _meterOpening = true;
    try {
      final track = await LocalAudioTrack.create(
        AudioCaptureOptions(deviceId: _selectedMicId),
      );
      final viz = createVisualizer(
        track,
        options: const AudioVisualizerOptions(
          barCount: 7,
          centeredBands: false,
          smoothTransition: false,
        ),
      );
      viz.events.on<AudioVisualizerEvent>((e) {
        var peak = 0.0;
        for (final v in e.event) {
          if (v is num && v > peak) peak = v.toDouble();
        }
        _meterLevel = peak.clamp(0.0, 1.0);
      });
      await viz.start();
      _meterTrack = track;
      _meterViz = viz;
    } catch (_) {
      _meterFailed = true;
    } finally {
      _meterOpening = false;
    }
    // Settle anything that changed while it opened.
    unawaited(_syncMeterTrack());
  }

  Future<void> _closeMeterTrack() async {
    final viz = _meterViz;
    final track = _meterTrack;
    _meterViz = null;
    _meterTrack = null;
    _meterLevel = null;
    try {
      await viz?.stop();
      await viz?.dispose();
    } catch (_) {}
    try {
      await track?.stop();
      await track?.dispose();
    } catch (_) {}
  }

  /// A command from the Studio. Obeyed only when the sender's server-issued
  /// role is `studio`; anything this device can't do is ignored.
  Future<void> _obeyCommand(RemoteParticipant from, List<int> data) async {
    if (_isStudio || _metaOf(from)['role'] != NileRole.studio) return;
    final command = StudioCommand.decode(data);
    if (command == null || !mounted) return;
    Future<void> Function() undo;
    try {
      switch (command) {
        case NudgeCommand(:final id, :final text):
          HapticFeedback.heavyImpact();
          setState(() => _nudge = (id: id, text: text));
          return;
        case TorchCommand(:final on):
          final was = _torchOn;
          await _setTorch(on);
          undo = () => _setTorch(was);
        case ZoomCommand(:final zoom):
          final was = _zoom;
          await _setZoom(zoom);
          undo = () => _setZoom(was);
        case LockCommand(:final focus, :final exposure):
          final f = _focusLocked;
          final x = _exposureLocked;
          await _setLocks(focus: focus, exposure: exposure);
          undo = () => _setLocks(focus: f, exposure: x);
        case FlipCommand():
          if (!_isMobile) return;
          await _switchCamera();
          undo = _switchCamera;
      }
    } catch (_) {
      return;
    }
    unawaited(_sendHealth());
    final notice = command.operatorNotice;
    if (notice == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(notice),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            try {
              await undo();
            } catch (_) {}
            unawaited(_sendHealth());
          },
        ),
      ),
    );
  }

  Future<void> _setTorch(bool on) async {
    final track = _cameraTrack;
    if (track == null || !await track.hasTorch()) {
      throw UnsupportedError('torch');
    }
    await track.setTorch(on);
    _torchOn = on;
  }

  Future<void> _setZoom(double zoom) async {
    final track = _cameraTrack;
    if (track == null || !_builtInCamera) throw UnsupportedError('zoom');
    await rtc.Helper.setZoom(track, zoom);
    _zoom = zoom;
  }

  Future<void> _setLocks({required bool focus, required bool exposure}) async {
    final track = _cameraTrack;
    if (track == null || !_builtInCamera) throw UnsupportedError('lock');
    await rtc.Helper.setFocusMode(
      track,
      focus ? rtc.CameraFocusMode.locked : rtc.CameraFocusMode.auto,
    );
    _focusLocked = focus;
    await rtc.Helper.setExposureMode(
      track,
      exposure ? rtc.CameraExposureMode.locked : rtc.CameraExposureMode.auto,
    );
    _exposureLocked = exposure;
  }

  /// 👍 on a nudge: tell the Studio, then dismiss.
  void _ackNudge() {
    final nudge = _nudge;
    if (nudge == null) return;
    _sendStatus(AckMessage(nudge.id), reliable: true);
    setState(() => _nudge = null);
  }

  // ── Graphics + resync ───────────────────────────────────────────────────────

  /// Studio: every 2 s, read how old each subscribed camera's picture is and
  /// show how far it trails the most current one (capture stamps; no delay).
  Future<void> _startLagReadout() async {
    _lagTimer?.cancel();
    if (!await RealSyncConfig.measuring() || !mounted) return;
    _lagTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final room = _room;
      if (room == null || !_studioMode) return;
      final ages = <String, double>{};
      final receivers = <String>{};
      for (final p in room.remoteParticipants.values) {
        if (!_isPublisher(p)) continue;
        final track = p.videoTrackPublications
            .where(
              (x) => x.subscribed && x.source != TrackSource.screenShareVideo,
            )
            .firstOrNull
            ?.track;
        if (track?.receiver?.receiverId case final id?) receivers.add(id);
        final age = await _lagAges.ageMs(p, track);
        if (age != null) ages[p.identity] = age;
      }
      _lagAges.retain(receivers);
      if (!mounted) return;
      _sourceAgesMs = ages;
      final lag = relativeLagMs(ages);
      if (!mapEquals(lag, _lagMs)) {
        _lagMs = lag;
        _rebuildRemoteSources();
      }
    });
  }

  void _applyRoomMetadata(String? raw, {bool joining = false}) {
    final graphics = GraphicsState.fromRoomMetadata(raw);
    if (graphics != _graphics && mounted) setState(() => _graphics = graphics);
    _armAutoHide();
    final elements = ElementsState.fromRoomMetadata(raw);
    final layout = OverlayLayout.fromRoomMetadata(raw);
    if ((elements != _elements || layout != _layout) && mounted) {
      setState(() {
        _elements = elements;
        _layout = layout;
      });
      if (elements.hasClocks) unawaited(ServerClock.ensure());
    }
    _layouts.setApplied(layoutAppliedFromRoomMetadata(raw));
    final show = ShowControl.fromRoomMetadata(raw);
    if (show != _show && mounted) {
      final reordered = !listEquals(show.slotOrder, _show.slotOrder);
      setState(() => _show = show);
      // A reorder renumbers default "Camera N" labels — re-read the slots.
      final eventId = _eventId;
      if (reordered && _isStudio && eventId != null) {
        _loadSlots(eventId);
      } else {
        _rebuildRemoteSources();
      }
    }
    final stamp = (parseParticipantMeta(raw)['resyncAt'] as num?)?.toInt();
    if (joining) {
      _seenResyncAt = stamp;
    } else if (stamp != null && stamp != _seenResyncAt) {
      _seenResyncAt = stamp;
      _clock?.remeasure();
      if (ServerClock.offsetMs != null) unawaited(ServerClock.remeasure());
      _resyncMonitor();
    }
  }

  /// The Studio monitor does what every viewer does on a resync: drop and
  /// re-pick up the feed it is showing.
  Future<void> _resyncMonitor() async {
    final id = _selectedSourceId?.split('#').first;
    final p = id == null ? null : _room?.remoteParticipants[id];
    if (p == null || !_studioMode) return;
    final pubs = p.videoTrackPublications.where((x) => x.subscribed).toList();
    for (final pub in pubs) {
      await pub.unsubscribe();
    }
    await Future.delayed(const Duration(milliseconds: 300));
    for (final pub in pubs) {
      await pub.subscribe();
    }
  }

  /// Studio, live: a camera that had been here before just came back — its
  /// feed restarted out of step with the others. Offer a resync.
  void _noteReconnect(Participant p) {
    if (!_isPublisher(p)) return;
    final returning = !_seenPublishers.add(p.identity);
    if (!returning || !_isStudio || _state != CameraState.live) return;
    final meta = _metaOf(p);
    final name = meta['role'] == NileRole.streamAudio
        ? 'Stream Audio'
        : (meta['cameraName'] as String?) ?? p.name;
    setState(() => _reconnectHint = name);
    _hintTimer?.cancel();
    _hintTimer = Timer(const Duration(seconds: 30), () {
      if (mounted) setState(() => _reconnectHint = null);
    });
  }

  /// "Resync all cameras and audio?" — then every viewer re-aligns.
  Future<void> _confirmResync() async {
    final eventId = _eventId;
    if (eventId == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text('Resync all cameras?', style: NileTextStyles.headingMd()),
        content: Text(
          'Resync all cameras and audio? Viewers will see a brief pause.',
          style: NileTextStyles.bodyMd().copyWith(
            color: NileColors.txtSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Resync',
              style: NileTextStyles.labelMd().copyWith(color: NileColors.volt),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _reconnectHint = null);
    try {
      await LivekitService.resync(eventId: eventId, studio: _isStudio);
      _toast('Resyncing every viewer.');
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// Every slot of the event, in display order — what graphics can target.
  List<StudioSlotRef> get _slotRefs => [
    for (final s in _show.ordered(_slots, (s) => s.id))
      (id: s.id, label: s.label),
  ];

  /// Studio: the Graphics panel. Each graphic picks its own cameras.
  Future<void> _openGraphics() => showGraphicsPushPanel(
    context,
    current: _graphics,
    slots: _slotRefs,
    push: _pushGraphics,
    cue: _cue,
    onTargetsUsed: (id, targets) => _lastTargets[id] = targets,
    onLibrary: (library) => _graphicsLibrary = library,
    showStartAt: _scheduledAt,
    isLive: _state == CameraState.live,
    sponsor: _sponsorItem,
    resolveLink: _resolveLink,
    brandKit: _brandKit,
    onBrandKit: _onBrandKit,
    takeElements: _takeElementCues,
  );

  // ── Live elements + layout (studio live elements, phases 1-3) ────────────

  void _onElementsChanged() {
    // Element angles are source tiles too.
    if (mounted) _rebuildRemoteSources();
  }

  /// How old the monitor's picture is, when RealSync is measuring.
  int? get _monitorAgeMs {
    final id = _selectedSourceId?.split('#').first;
    return (id == null ? null : _sourceAgesMs[id])?.round().clamp(0, 5000);
  }

  /// Studio: the Elements panel.
  Future<void> _openElements([String? select]) => showElementsPanel(
    context,
    controller: _elementsCtl,
    slots: _slotRefs,
    cue: _cue,
    onTake: _takeCue,
    kit: _brandKit?.style,
    initialSelected: select,
  );

  /// A HUD card's Apply: just that element; the rest of the cue waits.
  Future<void> _takeOneElement(ElementCue c) async {
    final ok = await _elementsCtl.setTargets(c.id, c.targets);
    if (!mounted) return;
    if (ok) {
      _cue.value = _cue.value.without(c.id);
    } else {
      _toast('Couldn’t put that on air. Try again.');
    }
  }

  String _camerasOf(GraphicTargets t) {
    final refs = _slotRefs;
    return t.summary(
      (id) => refs.where((r) => r.id == id).firstOrNull?.label ?? 'Camera',
      [for (final r in refs) r.id],
    );
  }

  /// Cued elements go on air (Apply).
  Future<bool> _takeElementCues(List<ElementCue> cues) async {
    final results = await Future.wait([
      for (final c in cues) _elementsCtl.setTargets(c.id, c.targets),
    ]);
    return results.every((ok) => ok);
  }

  /// On-air elements for [slotId]: the Studio's own (newest) state, plus any
  /// in the room it hasn't loaded yet.
  List<LiveElement> _elementsFor(String? slotId, {bool preview = false}) {
    final mine = preview
        ? _elementsCtl.preview(_cue.value)
        : _elementsCtl.onAir;
    final known = {for (final e in mine.items) e.id};
    return [
      ...mine.forSlot(slotId),
      for (final e in _elements.forSlot(slotId))
        if (!known.contains(e.id) && _elementsCtl.live(e.id) == null) e,
    ];
  }

  ElementInteraction _staffView(LiveElement e) => ElementInteraction(
    tally: _elementsCtl.tally(e.id),
    audience: ElementAudience.staff,
  );

  NileOverlayExtras _overlayFor(NileStudioSource s, {bool preview = false}) {
    // An element's own angle: no camera overlay, but its totals.
    if (s.element != null) {
      return (elements: const [], layers: const [], interactionFor: _staffView);
    }
    final slot = s.isScreenShare ? null : s.slotId;
    return (
      elements: _elementsFor(slot, preview: preview),
      layers: _layout.layersFor(slot),
      // The Studio sees totals on screen; it never votes.
      interactionFor: _staffView,
    );
  }

  /// A tile's "Layers…": spots and layer order for that camera.
  Future<void> _openLayers(NileStudioSource s) async {
    final eventId = _eventId;
    final slot = s.slotId;
    if (eventId == null || slot == null) return;
    final choice = await showLayersSheet(
      context,
      cameraLabel: s.label,
      graphics: _graphics.withBrand(_brandKit?.style).forSlot(slot),
      elements: _elementsFor(slot),
      layers: _layout.layersFor(slot),
    );
    if (choice == null || !mounted) return;
    final next = choice.copyToAll
        ? _layout.copiedToAll(choice.layers)
        : _layout.withLayers(slot, choice.layers);
    try {
      await LivekitService.setLayout(
        eventId: eventId,
        layout: next,
        srcAgeMs: _monitorAgeMs,
      );
      if (mounted) setState(() => _layout = next);
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  // ── Layouts (docs/plans/studio-layouts.md) ─────────────────────────────────

  void _onLayoutsChanged() {
    if (mounted) setState(() {});
  }

  /// The show as this Studio holds it — what layouts save and apply against.
  /// Elements: this Studio's own (newest), plus any in the room it hasn't
  /// loaded yet.
  StudioShowNow _showNow() {
    final mine = {for (final e in _elementsCtl.all) e.id: e};
    return (
      positions: positionsOf(_slots),
      graphics: _graphics,
      elements: [
        ...mine.values,
        for (final e in _elements.items)
          if (!mine.containsKey(e.id)) e,
      ],
      overlay: _layout,
      show: _show,
    );
  }

  LiveGraphic _layoutGraphic(StudioGraphic g, int? autoHide) =>
      LiveGraphic.snapshot(
        g,
        publicUrl: GraphicsService.publicUrl,
        now: DateTime.now(),
        autoHideSeconds: autoHide,
        showStartAt: _scheduledAt,
        resolveLink: _resolveLink,
      );

  /// One apply-layout request; then this Studio's own state follows.
  Future<void> _sendLayout(StudioLayout l, ResolvedLayout r) async {
    final eventId = _eventId;
    if (eventId == null) throw Exception('Not connected to a show.');
    final graphics = r.graphics.withBrand(_brandKit?.style);
    final List<LiveElement> stored;
    try {
      stored = await LivekitService.applyLayout(
        eventId: eventId,
        layoutId: l.id,
        updatedAt: l.updatedAt,
        graphics: graphics,
        layout: r.overlay,
        show: r.show,
        elements: [
          for (final e in r.elements) e.copyWith(version: e.version + 1),
        ],
        srcAgeMs: _monitorAgeMs,
      );
    } on ElementStale {
      unawaited(_elementsCtl.restore());
      throw Exception('An element changed while applying — try again.');
    }
    _elementsCtl.applied(stored);
    if (!mounted) return;
    setState(() {
      _graphics = graphics;
      _layout = r.overlay;
      _show = r.show;
    });
    _armAutoHide();
    _rebuildRemoteSources();
  }

  Future<void> _openLayouts() => showLayoutsPanel(
    context,
    controller: _layouts,
    slots: _slotRefs,
    templates: layoutTemplates(
      logoPath: _brandKit?.logoPath,
      hostName: _hostUsername ?? 'Your name',
    ),
  );

  /// The cue bar / Enter: apply the cued layout.
  Future<void> _applyLayoutCue() async {
    final l = _layouts.cued;
    if (l == null) return;
    try {
      final r = await _layouts.apply(l);
      if (r != null) _toast(appliedMessage(l, r));
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// Studio: the brand kit, the show's sponsor and the host's username —
  /// each best-effort; graphics work without them.
  void _loadGraphicsExtras(String eventId) {
    BrandKitService.load()
        .then((k) {
          if (mounted) setState(() => _brandKit = k);
        })
        .catchError((_) {});
    AdService.lobbySponsorship(eventId).then((sp) {
      if (!mounted || sp == null) return;
      setState(
        () => _sponsorItem = StudioGraphic.sponsor(
          campaignId: sp.campaignId,
          sponsorName: sp.advertiserName,
          logoUrl: sp.logoUrl,
        ),
      );
    });
    ProfileService.fetchCurrentProfile()
        .then((p) => _hostUsername = p?.username)
        .catchError((_) => null);
  }

  /// QR sources that are resolved when pushed.
  String? _resolveLink(String source) => switch (source) {
    'event' => _eventId == null ? null : ShareUrls.event(_eventId!),
    'profile' =>
      _hostUsername == null ? null : ShareUrls.profile(_hostUsername!),
    _ => null,
  };

  /// The kit was saved or removed: re-push so viewers redraw in it now.
  void _onBrandKit(BrandKit? kit) {
    setState(() => _brandKit = kit);
    if (!_graphics.isEmpty) _pushGraphics(_graphics);
  }

  /// Studio: keys 1–9 cue library items onto their last cameras (or take an
  /// on-air one off at once).
  Future<void> _onGraphicsHotkey(int digit) async {
    final action = graphicsHotkeyAction(
      digit: digit,
      library: _graphicsLibrary,
      current: _graphics,
      lastTargets: _lastTargets,
      showStartAt: _scheduledAt,
      resolveLink: _resolveLink,
    );
    if (action == null) return;
    if (action.cue != null) _cue.value = _cue.value.toggled(action.cue!);
    if (action.off != null && !await _pushGraphics(action.off!)) {
      _toast('Couldn’t update the show’s graphics. Try again.');
    }
  }

  /// Apply: everything cued goes on air together, countdowns and auto-hides
  /// starting now.
  Future<void> _takeCue() async {
    final cues = _cue.value;
    if (cues.isEmpty || _taking) return;
    setState(() => _taking = true);
    final graphicsOk =
        cues.items.isEmpty ||
        await _pushGraphics(cues.take(_graphics, DateTime.now()));
    final elementsOk =
        graphicsOk &&
        (cues.elements.isEmpty || await _takeElementCues(cues.elements));
    if (!mounted) return;
    setState(() => _taking = false);
    // Anything cued while the push was in flight stays cued.
    _cue.value = _cue.value.minus(
      CueSet(
        graphicsOk ? cues.items : const [],
        elementsOk ? cues.elements : const [],
      ),
    );
    if (!graphicsOk || !elementsOk) {
      _toast('Couldn’t put that on air. Try again.');
    }
  }

  /// What the monitor shows for a source: on air, plus the cue.
  List<LiveGraphic> _previewFor(NileStudioSource s) {
    if (s.element != null) return const [];
    final slot = s.isScreenShare ? null : s.slotId;
    final base = _graphics.withBrand(_brandKit?.style);
    return _cue.value.preview(base, DateTime.now()).forSlot(slot);
  }

  bool _isCued(NileStudioSource s) =>
      s.element == null && _cue.value.lands(s.isScreenShare ? null : s.slotId);

  Widget? _buildCueBar() {
    final layout = _layouts.cued;
    if (_isStudio && layout != null) {
      final n = layout.cameras.length;
      return NileStudioCueBar(
        name: 'Layout · ${layout.name}',
        targets: '$n ${n == 1 ? 'camera' : 'cameras'}',
        busy: _layouts.busy,
        onTake: _applyLayoutCue,
        onClear: () => _layouts.cue(null),
      );
    }
    final cues = _cue.value;
    if (!_isStudio || cues.isEmpty) return null;
    final refs = _slotRefs;
    final d = cues.describe(
      (id) => refs.where((r) => r.id == id).firstOrNull?.label ?? 'Camera',
      [for (final r in refs) r.id],
    );
    return NileStudioCueBar(
      name: d.name,
      targets: d.targets,
      count: cues.length,
      busy: _taking,
      onTake: _takeCue,
      onClear: () => _cue.value = CueSet.empty,
    );
  }

  Future<bool> _pushGraphics(GraphicsState next) async {
    final eventId = _eventId;
    if (eventId == null) return false;
    next = next.withBrand(_brandKit?.style);
    try {
      await LivekitService.setGraphics(
        eventId: eventId,
        graphics: next,
        srcAgeMs: _monitorAgeMs,
      );
      if (mounted) setState(() => _graphics = next);
      _armAutoHide();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Studio: take graphics down when their auto-hide comes due. Re-armed
  /// whenever [_graphics] changes; a failed push isn't retried for the same
  /// deadline (viewers already hide expired graphics on their own).
  void _armAutoHide() {
    final at = _isStudio ? _graphics.nextHideAt : null;
    if (at == _hideArmedFor) return;
    _hideTimer?.cancel();
    _hideTimer = null;
    _hideArmedFor = at;
    if (at == null) return;
    final wait = at - DateTime.now().millisecondsSinceEpoch;
    _hideTimer = Timer(Duration(milliseconds: wait < 0 ? 0 : wait), () {
      final next = _graphics.withoutExpired(
        DateTime.now().millisecondsSinceEpoch,
      );
      if (next != _graphics) _pushGraphics(next);
    });
  }

  /// A chat line as an on-screen card.
  LiveGraphic _chatGraphic(ChatMessage m, int seconds) =>
      LiveGraphic.chatMessage(
        messageId: m.id ?? '${m.senderId}-${m.sentAt.millisecondsSinceEpoch}',
        username: m.username,
        message: m.content,
        avatarUrl: m.avatarUrl,
        now: DateTime.now(),
        seconds: seconds,
      );

  /// A chat line, cued for Apply; its timer starts when it goes on air.
  GraphicCue _chatCue(ChatMessage m, GraphicTargets targets, int seconds) =>
      GraphicCue(
        id: _chatGraphic(m, seconds).id,
        name: 'Chat · @${m.username}',
        targets: targets,
        build: (_) => _chatGraphic(m, seconds),
      );

  /// "Show on screen": cued for every camera, 10 s.
  Future<void> _showChatOnScreen(ChatMessage m) async {
    _cue.value = _cue.value.adding(_chatCue(m, const GraphicTargets.all(), 10));
  }

  /// "Show on screen" with a choice of cameras and timer.
  Future<void> _showChatOnScreenOptions(ChatMessage m) async {
    final choice = await showGraphicTargetsDialog(
      context,
      title: 'Show on screen',
      slots: _slotRefs,
      initial: const GraphicTargets.all(),
      autoHideSeconds: 10,
    );
    if (choice == null || !mounted) return;
    final cue = _chatCue(m, choice.targets, choice.autoHideSeconds);
    if (!choice.targets.isNone) {
      _cue.value = _cue.value.adding(cue);
      return;
    }
    _cue.value = _cue.value.without(cue.id);
    if (!await _pushGraphics(_graphics.withoutEverywhere(cue.id))) {
      _toast('Couldn’t take that off screen. Try again.');
    }
  }

  /// A tile's graphic menu: off this camera, or off every camera.
  Future<void> _removeGraphic(
    NileStudioSource source,
    LiveGraphic g, {
    required bool everywhere,
  }) async {
    final slot = source.slotId;
    final next = everywhere || slot == null
        ? _graphics.withoutEverywhere(g.id)
        : _graphics.withoutOnSlot(g.id, slot);
    if (!await _pushGraphics(next)) {
      _toast('Couldn’t remove that graphic. Try again.');
    }
  }

  // ── Show control (Studio) ───────────────────────────────────────────────

  /// Studio: tile actions. Host-only, so nothing for anyone else.
  NileStudioSourceActions get _sourceActions => !_isStudio
      ? const NileStudioSourceActions()
      : NileStudioSourceActions(
          onToggleOffAir: _toggleOffAir,
          onSetDefault: _toggleDefault,
          onSendEveryone: _sendEveryone,
          onMakeMasterAudio: (s) => _setMasterAudio(s.identity),
          onRemoveGraphic: _removeGraphic,
          onNudge: (s, text) => _sendNudge(s.identity, text),
          onCommand: (s, c) => _sendCommand(s.identity, c),
          onReorder: _reorderSources,
          onLayers: _openLayers,
        );

  Future<void> _setShow({
    List<String>? offAir,
    String? defaultSlot,
    bool clearDefault = false,
    String? sendAll,
  }) async {
    final eventId = _eventId;
    if (eventId == null) return;
    try {
      await LivekitService.setShow(
        eventId: eventId,
        offAir: offAir,
        defaultSlot: defaultSlot,
        clearDefault: clearDefault,
        sendAll: sendAll,
      );
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _toggleOffAir(NileStudioSource s) async {
    final slot = s.slotId;
    if (slot == null) return;
    final off = {..._show.offAir};
    if (!off.remove(slot)) off.add(slot);
    await _setShow(offAir: off.toList());
  }

  Future<void> _toggleDefault(NileStudioSource s) async {
    final slot = s.slotId;
    if (slot == null) return;
    await (_show.defaultSlot == slot
        ? _setShow(clearDefault: true)
        : _setShow(defaultSlot: slot));
  }

  /// "Send everyone here" — every viewer moves once. Asks first when live.
  Future<void> _sendEveryone(NileStudioSource s) async {
    final slot = s.slotId;
    if (slot == null) return;
    if (_state == CameraState.live) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: NileColors.bgSurface,
          title: Text(
            'Send everyone to ${s.label}?',
            style: NileTextStyles.headingMd(),
          ),
          content: Text(
            'Every viewer switches to this camera now. They can still pick '
            'another angle afterwards.',
            style: NileTextStyles.bodyMd().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                'Send everyone',
                style: NileTextStyles.labelMd().copyWith(
                  color: NileColors.volt,
                ),
              ),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _setShow(sendAll: slot);
  }

  /// Tiles dragged into a new order. The server wants every slot once.
  Future<void> _reorderSources(List<String> slotIds) async {
    final eventId = _eventId;
    if (eventId == null) return;
    final order = [
      ...slotIds,
      for (final s in _slotRefs)
        if (!slotIds.contains(s.id)) s.id,
    ];
    try {
      await LivekitService.reorderCameras(eventId: eventId, order: order);
      await _loadSlots(eventId);
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// Studio: viewers per angle, for the tiles.
  Future<void> _pollAngles() async {
    final eventId = _eventId;
    if (eventId == null || !_isStudio) return;
    final counts = await AngleWatchers.counts(eventId);
    if (counts == null ||
        !mounted ||
        _room == null ||
        mapEquals(counts, _angleCounts)) {
      return;
    }
    _angleCounts = counts;
    _rebuildRemoteSources();
  }

  /// Viewers on [slotId] for a tile — Studio only, once counts have loaded.
  int? _viewersOn(String? slotId) {
    final counts = _angleCounts;
    if (!_isStudio || slotId == null || counts == null) return null;
    return counts[slotId] ?? 0;
  }

  /// Studio: the show went live from somewhere else (a host phone on a build
  /// that predates the Studio — the server refused its start-show while we
  /// were here). start-show is idempotent, so stamp the sync anchor and start
  /// the replay recording now rather than run a show with neither.
  Future<void> _anchorShow() async {
    final eventId = _eventId;
    if (eventId == null) return;
    final started = await _retryValue(
      () => LivekitService.startShow(eventId: eventId, studio: true),
    );
    if (started != true && mounted) setState(() => _notRecording = true);
  }

  /// Studio: the event's camera slots, for the slot-ordered source list.
  Future<void> _loadSlots(String eventId) async {
    try {
      final slots = await LivekitService.listSlots(eventId: eventId);
      if (!mounted) return;
      setState(() => _slots = slots.slots);
      _rebuildRemoteSources();
    } catch (_) {
      // Without slots the list falls back to one row per connected feed.
    }
  }

  /// Host phone: "Which camera is this?" — pick a slot (or Stream Audio)
  /// before connecting. Slots another device is on are shown but disabled.
  Future<void> _chooseSlotAndConnect() async {
    final eventId = _eventIdController.text.trim();
    if (eventId.isEmpty) {
      setState(() => _errorMessage = 'Enter the Event ID first.');
      return;
    }
    final me = 'camera-${await InstallId.get()}';
    if (!mounted) return;
    final choice = await showCameraSlotSheet(
      context,
      load: () => LivekitService.listSlots(eventId: eventId),
      myIdentity: me,
    );
    if (!mounted || choice == null) return;
    if (choice.streamAudio) {
      context.pushReplacement(
        NileRoutes.stream(eventId, audio: true, host: widget.isHost),
      );
      return;
    }
    await _enterSoundCheck(slot: choice.slot);
  }

  /// Studio: rename a camera on the fly. A slot keeps the name for the rest
  /// of the event; the device on it — and every viewer's angle picker —
  /// updates live.
  Future<void> _renameSource(NileStudioSource source) async {
    final eventId = _eventId;
    if (eventId == null) return;
    final current = source.label.replaceFirst(RegExp(r'^Studio · '), '');
    final name = await showRenameCameraDialog(context, current: current);
    if (name == null || name == current) return;
    try {
      await LivekitService.renameCamera(
        eventId: eventId,
        name: name,
        slotId: source.slotId,
        identity: source.slotId == null ? source.identity : null,
      );
      if (source.isLocal) _cameraNameController.text = name;
      await _loadSlots(eventId);
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// Studio: switch the mic it publishes — a USB mixer or audio interface
  /// when the Studio carries the show audio. Republishes the mic.
  Future<void> _selectMic(String? deviceId) async {
    if (deviceId == _selectedMicId || _switchingMic) return;
    setState(() {
      _selectedMicId = deviceId;
      _switchingMic = true;
    });
    try {
      await _applyMicProcessing(_room?.localParticipant);
    } catch (_) {
      _toast('Couldn’t open that input. Back to the default mic.');
      if (mounted) setState(() => _selectedMicId = null);
      await _applyMicProcessing(_room?.localParticipant).catchError((_) {});
    } finally {
      if (mounted) setState(() => _switchingMic = false);
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

  /// [_retry] for a call whose answer matters. Returns null when every attempt
  /// failed, which is distinct from a call that succeeded and returned false.
  static Future<T?> _retryValue<T>(Future<T> Function() op) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await op();
      } catch (_) {
        if (attempt < 2) {
          await Future.delayed(Duration(milliseconds: 400 * (attempt + 1)));
        }
      }
    }
    return null;
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
    //
    // null → the call never got through. false → it did, and the server told us
    // the recording did not start (replay storage misconfigured, or LiveKit
    // refused the egress). Both mean "assume there is no replay": the server
    // used to swallow the second case entirely and answer success, so a host
    // only discovered it after the show, with nothing to sell.
    final egressStarted = await _retryValue(
      () => LivekitService.startShow(eventId: _eventId!, studio: _isStudio),
    );
    if (egressStarted != true) {
      if (mounted) setState(() => _notRecording = true);
      _toast(
        'You’re live, but the recording didn’t start. There will be no replay '
        'for this show.',
      );
    }
  }

  /// Host: disconnect a crew feed from the room.
  ///
  /// The only lever before this was ending the whole show. An operator taken
  /// off the crew list kept publishing until they closed the app, because the
  /// authorization check runs when their token is minted and never again.
  Future<void> _removeSource(NileStudioSource source) async {
    final eventId = _eventId;
    if (eventId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text(
          'Remove ${source.label}?',
          style: NileTextStyles.headingMd(),
        ),
        content: Text(
          'Their feed is dropped from the show immediately. They can rejoin '
          'only if they are still on the crew list.',
          style: NileTextStyles.bodyMd(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Remove', style: TextStyle(color: NileColors.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await LivekitService.removeParticipant(
        eventId: eventId,
        identity: source.identity,
      );
      _toast('${source.label} was removed from the stream.');
    } catch (_) {
      _toast('Couldn’t remove ${source.label}. Try again.');
    }
  }

  Future<void> _claimMasterAudio() async {
    final me = _cameraIdentity;
    if (me != null) await _setMasterAudio(me, confirmLive: false);
  }

  /// Move the show's audio to [identity] — a camera, this Studio, or Stream
  /// Audio. Free during Sound Check; live, it asks first, because viewers
  /// hear the switch (and the sync reference resets with it).
  Future<void> _setMasterAudio(
    String identity, {
    bool confirmLive = true,
  }) async {
    final eventId = _eventId;
    if (eventId == null || identity == _masterIdentity) return;
    if (confirmLive && _state == CameraState.live) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: NileColors.bgSurface,
          title: Text('Switch show audio?', style: NileTextStyles.headingMd()),
          content: Text(
            'Viewers will hear ${_sourceName(identity)} from now on. There may '
            'be a brief jump in the sound while it switches.',
            style: NileTextStyles.bodyMd().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                'Switch',
                style: NileTextStyles.labelMd().copyWith(
                  color: NileColors.volt,
                ),
              ),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await LivekitService.setMasterAudio(eventId: eventId, identity: identity);
    } catch (_) {
      _toast('Couldn’t switch the show audio. Try again.');
    }
  }

  /// Display name for a publisher identity — "Studio", "Stream Audio", or the
  /// camera's name.
  String _sourceName(String identity) {
    final room = _room;
    if (identity == room?.localParticipant?.identity) {
      return _isStudio ? 'the Studio mic' : 'this camera';
    }
    final p = room?.remoteParticipants[identity];
    if (p == null) return 'that source';
    final meta = _metaOf(p);
    return switch (meta['role']) {
      NileRole.streamAudio => 'Stream Audio',
      NileRole.studio => 'the Studio mic',
      _ => (meta['cameraName'] as String?) ?? p.name,
    };
  }

  Future<void> _toggleVideo() async {
    final newEnabled = !_videoEnabled;
    // The Studio's webcam is a camera like any other: the server checks the
    // event's camera limit and gives it a slot BEFORE it publishes, and frees
    // both when it turns off.
    if (_isStudio && _eventId != null) {
      try {
        final name = await LivekitService.studioCamera(
          eventId: _eventId!,
          enabled: newEnabled,
        );
        _cameraNameController.text = name;
      } catch (e) {
        _toast(e.toString().replaceFirst('Exception: ', ''));
        return;
      }
    }
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
            cameraPosition: nowFront
                ? CameraPosition.front
                : CameraPosition.back,
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
          // A new lens starts with no torch, no zoom and nothing locked.
          _torchOn = false;
          _zoom = 1;
          _focusLocked = false;
          _exposureLocked = false;
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
    if (_eventId != null && _revertsOnLeave) {
      EventService.revertToScheduled(_eventId!).catchError((_) {});
    }
    await _teardownRoom();
  }

  /// Leaving Sound Check cancels it (back to 'scheduled') only from the device
  /// running the show — and not from a Studio whose host still has a phone on
  /// a camera, which takes the controls back after the handover grace.
  bool get _revertsOnLeave =>
      _state == CameraState.soundCheck &&
      _runsShow &&
      !(_isStudio && _otherHostDevice);

  /// Explicitly end the live show: flip the DB status to 'ended' (the single
  /// source of truth viewers watch) then disconnect. This is the only path that
  /// ends a show; it lives at the bottom of the Settings sheet behind a confirm.
  Future<void> _endStream() async {
    if (_eventId != null) {
      // Stop the replay egress FIRST so the recording finalizes while the room
      // is still up. Best-effort; the egress_ended webhook and the hourly sweep
      // both cover a failure here.
      await _retry(
        () => LivekitService.stopEgress(eventId: _eventId!, studio: _isStudio),
      );

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
    _systemChannel?.unsubscribe();
    _systemChannel = null;
    _modChannel?.unsubscribe();
    _modChannel = null;
    _chatMessages.clear();
    _hideTimer?.cancel();
    _hideTimer = null;
    _hideArmedFor = null;
    _angleTimer?.cancel();
    _angleTimer = null;
    _statusTicker?.cancel();
    _statusTicker = null;
    _stopStatusLink();
    _status.clear();
    _remoteQuality.clear();
    _alerts = CameraAlerts();
    _lastTargets.clear();
    _graphicsLibrary = const [];
    _cue.value = CueSet.empty;
    _layouts.cue(null);
    _layouts.setApplied(null);
    _sponsorItem = null;
    // Stop screen capture explicitly — disconnect unpublishes the track but
    // doesn't always halt the native capturer promptly.
    try {
      await _screenShareTrack?.stop();
    } catch (_) {}
    _screenShareTrack = null;
    _handover.reset();
    _clock?.stop();
    _clock = null;
    _lagTimer?.cancel();
    _lagAges.dispose();
    _lagMs = const {};
    await _listener?.dispose();
    await _room?.disconnect();
    if (!mounted) return;
    setState(() {
      _room = null;
      _listener = null;
      _localVideoTrack = null;
      _masterIdentity = null;
      _isStudio = false;
      _otherHostDevice = false;
      _slotId = null;
      _slots = const [];
      _graphics = GraphicsState.empty;
      _show = ShowControl.empty;
      _angleCounts = null;
      _scheduledAt = null;
      _pinned = null;
      _quickMessages = const [];
      _studioIdentity = null;
      _nudge = null;
      _seenResyncAt = null;
      _reconnectHint = null;
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
    showStudioSettingsSheet(
      context,
      externalMic: () => _disableAgc,
      switchingMic: () => _switchingMic,
      externalMicConnected: _externalMicConnected,
      connected: _state != CameraState.idle,
      onExternalMic: _setExternalMicMode,
      prefs: _studioMode ? _prefs : null,
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

  Widget _buildReconnectHint() => Material(
    color: NileColors.bgRaised,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        NileSpacing.s16,
        NileSpacing.s8,
        NileSpacing.s8,
        NileSpacing.s8,
      ),
      child: Row(
        children: [
          Icon(Icons.sync_problem, color: NileColors.amber, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$_reconnectHint reconnected · its picture may be out of step.',
              style: NileTextStyles.bodySm().copyWith(
                color: NileColors.txtPrimary,
              ),
            ),
          ),
          TextButton(
            onPressed: _confirmResync,
            child: Text(
              'Resync',
              style: NileTextStyles.labelMd().copyWith(color: NileColors.volt),
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 18, color: NileColors.txtSecondary),
            tooltip: 'Dismiss',
            onPressed: () => setState(() => _reconnectHint = null),
          ),
        ],
      ),
    ),
  );

  Widget _buildExternalMicBanner() {
    return Material(
      color: NileColors.bgRaised,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          NileSpacing.s16,
          NileSpacing.s8,
          NileSpacing.s8,
          NileSpacing.s8,
        ),
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
              icon: Icon(Icons.close, size: 18, color: NileColors.txtSecondary),
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
          // The host picks a slot ("Which camera is this?") or, on a desk-
          // sized window, opens the Studio — no name to type either way.
          if (!widget.isHost) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _cameraNameController,
              style: NileTextStyles.bodyLg(),
              decoration: const InputDecoration(
                labelText: 'Camera Name',
                hintText: 'e.g. Stage Left Cam',
              ),
            ),
          ],
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
            onPressed: !widget.isHost || _studioMode
                ? _enterSoundCheck
                : _chooseSlotAndConnect,
            icon: Icon(
              widget.isHost && _studioMode
                  ? Icons.desktop_mac_outlined
                  : Icons.videocam,
            ),
            label: Text(
              !widget.isHost
                  ? 'Enter Sound Check'
                  : _studioMode
                  ? 'Open Studio'
                  : 'Choose Camera',
            ),
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
  Widget _buildCameraPickerButton() => NileCameraPickerButton(
    devices: _videoInputs,
    selectedId: _selectedCameraId,
    onSelected: _selectCamera,
  );

  /// Phone parity for the Studio's hover menu (#16 phase 2).
  ///
  /// Long-press a line in the overlay. Most hosts run the show from a phone, so
  /// moderation that only existed on a window wide enough for the Studio was
  /// moderation most hosts didn't actually have.
  Future<void> _showChatActions(ChatMessage m) async {
    if (m.isSystem || m.senderId.isEmpty) return;
    if (m.senderId == supabase.auth.currentUser?.id) return;

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: NileColors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(NileRadius.lg),
        ),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NileSpacing.s16,
                NileSpacing.s16,
                NileSpacing.s16,
                NileSpacing.s8,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '@${m.username}',
                  style: NileTextStyles.headingSm(),
                ),
              ),
            ),
            // Room-wide first, same order and same wording as the Studio menu.
            // Remove needs an id, which a line from a pre-#16 client lacks.
            if (_canModerateChat && m.id != null)
              ListTile(
                leading: Icon(
                  Icons.backspace_outlined,
                  color: NileColors.txtPrimary,
                ),
                title: Text(
                  'Remove this message',
                  style: NileTextStyles.bodyMd(),
                ),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
            if (_canModerateChat)
              ListTile(
                leading: Icon(Icons.gavel, color: NileColors.error),
                title: Text(
                  'Ban from this show',
                  style: NileTextStyles.bodyMd().copyWith(
                    color: NileColors.error,
                  ),
                ),
                onTap: () => Navigator.pop(ctx, 'ban'),
              ),
            if (_canModerateChat) const Divider(height: 1),
            ListTile(
              leading: Icon(
                Icons.visibility_off_outlined,
                color: NileColors.txtPrimary,
              ),
              title: Text('Hide for me', style: NileTextStyles.bodyMd()),
              onTap: () => Navigator.pop(ctx, 'hide'),
            ),
            ListTile(
              leading: Icon(Icons.block, color: NileColors.txtPrimary),
              title: Text('Block for me', style: NileTextStyles.bodyMd()),
              onTap: () => Navigator.pop(ctx, 'block'),
            ),
            ListTile(
              leading: Icon(Icons.flag_outlined, color: NileColors.error),
              title: Text(
                m.id != null ? 'Report this message' : 'Report @${m.username}',
                style: NileTextStyles.bodyMd().copyWith(
                  color: NileColors.error,
                ),
              ),
              onTap: () => Navigator.pop(ctx, 'report'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    // Run after the sheet closes so a confirm dialog isn't parented to a route
    // on its way out.
    switch (action) {
      case 'remove':
        await _removeMessage(m);
      case 'ban':
        await _banSender(m);
      case 'hide':
        _hideSender(m);
      case 'block':
        await _blockSender(m);
      case 'report':
        await _reportSender(m);
    }
  }

  /// Chat overlay — top-left under the status badge, newest at the bottom.
  /// Toggled by the chat button in the bottom controls. Long-press a line for
  /// the same actions the Studio column offers on hover.
  Widget _buildChatOverlay() {
    final size = MediaQuery.of(context).size;
    final messages = [
      for (final m in _visibleChatMessages)
        if (!m.filtered) m,
    ];
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
        // Same filter the Studio column applies. It was missing here, which
        // meant hiding or blocking someone on a phone changed nothing at all —
        // the host kept seeing them in the only chat view a phone has. Lines
        // the blocked words held back stay out: the overlay can't mark them.
        child: messages.isEmpty
            ? Text(
                'Chat is quiet — messages will appear here.',
                style: NileTextStyles.bodySm().copyWith(color: Colors.white54),
              )
            : ListView.builder(
                reverse: true,
                shrinkWrap: true,
                itemCount: messages.length,
                itemBuilder: (context, i) {
                  final m = messages[i];
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onLongPress: () => _showChatActions(m),
                    child: Padding(
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
                          : NileLinkText(
                              m.content,
                              linkify: m.mayLink,
                              style: NileTextStyles.bodySm().copyWith(
                                color: Colors.white,
                              ),
                              prefix: TextSpan(
                                text: '@${m.username}  ',
                                style: NileTextStyles.bodySm().copyWith(
                                  color: nileChatNameColor(
                                    m.senderId,
                                    isHost: m.isHost,
                                  ),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
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
  /// A Studio is in the room (or left within the handover grace).
  bool get _studioInCharge => _isStudio || _handover.studioInCharge;

  bool get _masterIsStreamAudio {
    final id = _masterIdentity;
    final p = id == null ? null : _room?.remoteParticipants[id];
    return p != null && _metaOf(p)['role'] == NileRole.streamAudio;
  }

  Widget _statusPill(
    String text,
    Color bg,
    Color fg, {
    IconData icon = Icons.album,
  }) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: NileSpacing.s12,
      vertical: NileSpacing.s6,
    ),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(NileRadius.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: fg),
        const SizedBox(width: 6),
        Text(
          text,
          style: NileTextStyles.labelSm().copyWith(color: fg, fontSize: 12),
        ),
      ],
    ),
  );

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
                  Icon(Icons.videocam_off, size: 64, color: NileColors.border),
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

        // ── Graphics on this camera, as viewers of it see them ───────────
        Positioned.fill(
          child: NileGraphicsLayer(
            graphics: _graphics.forSlot(_slotId),
            elements: _elements.forSlot(_slotId),
            layers: _layout.layersFor(_slotId),
          ),
        ),

        // ── Off air — the Studio took this angle away from viewers ──────
        if (_isOffAir)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: _statusPill(
                  'Off air — viewers can’t see this camera',
                  NileColors.amber.withValues(alpha: 0.9),
                  Colors.white,
                  icon: Icons.videocam_off_outlined,
                ),
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
            padding: const EdgeInsets.symmetric(
              horizontal: NileSpacing.s8,
              vertical: NileSpacing.s4,
            ),
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

        // ── Not-recording badge — under the status badge ───────────────
        // The Studio gets this as a stats chip; the phone layout needs its own,
        // because most hosts run the show from a phone and a toast they scrolled
        // past is the same as never being told. Sticky for the session: there is
        // no recovering the recording mid-show.
        if (_notRecording)
          Positioned(
            top: 48,
            left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: NileSpacing.s8,
                vertical: NileSpacing.s4,
              ),
              decoration: BoxDecoration(
                color: NileColors.error,
                borderRadius: BorderRadius.circular(NileRadius.pill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.fiber_smart_record,
                    size: 10,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'NOT RECORDING',
                    style: NileTextStyles.labelSm().copyWith(
                      color: Colors.white,
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
        // This camera carries the show's sound → MASTER AUDIO. Stream Audio
        // carries it → say so. Otherwise offer to take it — except while the
        // Studio is running the show, where audio is chosen from the Studio.
        Positioned(
          top: 16,
          right: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (_isMainAudioSource)
                _statusPill('MASTER AUDIO', NileColors.volt, NileColors.onVolt)
              else if (_masterIsStreamAudio)
                _statusPill(
                  'STREAM AUDIO ACTIVE',
                  NileColors.amber.withValues(alpha: 0.9),
                  Colors.white,
                )
              else if (!_studioInCharge)
                ElevatedButton.icon(
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
              // The host's own phone while the Studio has the controls.
              if (widget.isHost && !_isStudio && _studioInCharge) ...[
                const SizedBox(height: NileSpacing.s8),
                _statusPill(
                  'STUDIO IS RUNNING THE SHOW',
                  NileColors.bgSurface.withValues(alpha: 0.85),
                  NileColors.txtPrimary,
                  icon: Icons.desktop_mac_outlined,
                ),
              ],
            ],
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
              if (_state == CameraState.soundCheck && _runsShow) ...[
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
                      padding: const EdgeInsets.symmetric(
                        vertical: NileSpacing.s16,
                      ),
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
                      padding: const EdgeInsets.symmetric(
                        vertical: NileSpacing.s16,
                      ),
                      textStyle: NileTextStyles.labelLg(),
                      shape: const StadiumBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              // Sound Check, crew: toggleable "Ready to Stream" — tells the
              // host this feed is good to go. Tap again to un-ready.
              if (_state == CameraState.soundCheck && !_runsShow) ...[
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
                            padding: const EdgeInsets.symmetric(
                              vertical: NileSpacing.s16,
                            ),
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
                            padding: const EdgeInsets.symmetric(
                              vertical: NileSpacing.s16,
                            ),
                            textStyle: NileTextStyles.labelLg(),
                            shape: const StadiumBorder(),
                          ),
                        ),
                ),
                const SizedBox(height: 12),
              ],
              // Live, host: visible End Stream — destructive, confirm-gated. The
              // sole path that ends a show. Operators never see it (host-only).
              if (_state == CameraState.live && _runsShow) ...[
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _confirmEndStream,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('End Stream'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: NileColors.error,
                      side: const BorderSide(color: NileColors.error),
                      padding: const EdgeInsets.symmetric(
                        vertical: NileSpacing.s16,
                      ),
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
                        tooltip: 'Switch camera',
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
                  if (_isMainAudioSource || !_videoEnabled) ...[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _toggleVideo,
                        icon: Icon(
                          _videoEnabled ? Icons.videocam_off : Icons.videocam,
                        ),
                        label: Text(_videoEnabled ? 'Video Off' : 'Video On'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: NileColors.txtPrimary,
                          side: BorderSide(color: NileColors.borderStrong),
                          padding: const EdgeInsets.symmetric(
                            vertical: NileSpacing.s16,
                          ),
                          shape: const StadiumBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  // Resync — the host's phone, live, with no Studio in the room.
                  if (_state == CameraState.live &&
                      _runsShow &&
                      !_isStudio) ...[
                    IconButton(
                      onPressed: _confirmResync,
                      tooltip: 'Resync cameras and audio',
                      icon: const Icon(Icons.sync),
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
                        padding: const EdgeInsets.symmetric(
                          vertical: NileSpacing.s16,
                        ),
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

        // ── Nudge from the Studio — on top of everything until 👍 ───────
        if (_nudge != null)
          Positioned(
            top: NileSpacing.s16,
            left: NileSpacing.s16,
            right: NileSpacing.s16,
            child: _buildNudgeBanner(),
          ),
      ],
    );
  }

  /// "Go wide", "Charge soon"… from the Studio, with a 👍 that tells it the
  /// operator has read it.
  Widget _buildNudgeBanner() => Material(
    color: NileColors.volt,
    borderRadius: BorderRadius.circular(NileRadius.sm),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        NileSpacing.s16,
        NileSpacing.s8,
        NileSpacing.s8,
        NileSpacing.s8,
      ),
      child: Row(
        children: [
          Icon(Icons.campaign_outlined, color: NileColors.onVolt),
          const SizedBox(width: NileSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'FROM THE STUDIO',
                  style: NileTextStyles.labelSm().copyWith(
                    color: NileColors.onVolt,
                    letterSpacing: 1.2,
                  ),
                ),
                Text(
                  _nudge?.text ?? '',
                  style: NileTextStyles.headingSm().copyWith(
                    color: NileColors.onVolt,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _ackNudge,
            child: Text('👍', style: NileTextStyles.headingMd()),
          ),
        ],
      ),
    ),
  );

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

    final studio = NileStudio(
      sources: sources,
      sourceActions: _sourceActions,
      selectedIdentity: _selectedSourceId,
      onSelectSource: (id) => setState(() => _selectedSourceId = id),
      // Ejecting someone is the host's call, not an operator's — same bar as
      // Start Show and End Stream, and the server enforces it too.
      onRemoveSource: widget.isHost ? _removeSource : null,
      // Renaming is a show-control, so only the Studio offers it.
      onRenameSource: _isStudio ? _renameSource : null,
      graphicsFor: (s) => s.element != null
          ? const []
          : _graphics.forSlot(s.isScreenShare ? null : s.slotId),
      previewFor: _isStudio ? _previewFor : null,
      isCued: _isStudio ? _isCued : null,
      overlayFor: _overlayFor,
      previewOverlayFor: _isStudio
          ? (s) => _overlayFor(s, preview: true)
          : null,
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
            .where(
              (s) =>
                  !s.isScreenShare &&
                  !s.identity.startsWith('crew:') &&
                  !s.identity.startsWith('slot:') &&
                  s.element == null &&
                  // The Studio counts once its own camera is on.
                  !(s.isLocal && _isStudio && !_videoEnabled),
            )
            .length,
        quality: _quality,
        audioSourceLabel: _audioSourceLabel,
        notRecording: _notRecording,
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
      // Quick controls for live and cued elements — the control room's alone.
      hud: _isStudio
          ? ElementHudStrip(
              controller: _elementsCtl,
              cue: _cue,
              cameraSummary: _camerasOf,
              onTakeOne: _takeOneElement,
              onOpenPanel: _openElements,
            )
          : null,
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
              // Null hides the room-wide items entirely rather than showing
              // them disabled — same call as `onRemoveSource`. The server
              // re-checks either way.
              onRemove: _canModerateChat ? _removeMessage : null,
              onBan: _canModerateChat ? _banSender : null,
              // Settings are the host's alone, even when crew can moderate:
              // deciding how the room behaves is not the same job as policing
              // it.
              onSettings: widget.isHost ? _showChatSettings : null,
              restrictionLabel: _chatRestrictionLabel,
              onSend: _sendChat,
              quickMessages: _quickMessages,
              onEditQuickMessages: widget.isHost ? _editQuickMessages : null,
              pinned: _pinned,
              onPin: _canModerateChat ? _pinMessage : null,
              onUnpin: _canModerateChat ? _unpinMessage : null,
              onRelease: _canModerateChat ? _releaseMessage : null,
              // Only the control room puts things on screen.
              onShowOnScreen: _isStudio ? _showChatOnScreen : null,
              onShowOnScreenOptions: _isStudio
                  ? _showChatOnScreenOptions
                  : null,
            )
          : null,
      // The Studio's cue comes first; an operator on a desk-sized screen gets
      // nudges here.
      banner:
          _buildCueBar() ??
          (_nudge != null
              ? _buildNudgeBanner()
              : _reconnectHint != null
              ? _buildReconnectHint()
              : _externalMicConnected &&
                    !_disableAgc &&
                    !_externalMicPromptDismissed
              ? _buildExternalMicBanner()
              : null),
    );
    return _isStudio
        ? StudioGraphicsHotkeys(
            onDigit: _onGraphicsHotkey,
            onAltDigit: _layouts.cueNumber,
            onTake: _layouts.cued != null
                ? _applyLayoutCue
                : _cue.value.isEmpty
                ? null
                : _takeCue,
            onClear: _layouts.cued != null
                ? () => _layouts.cue(null)
                : _cue.value.isEmpty
                ? null
                : () => _cue.value = CueSet.empty,
            child: studio,
          )
        : studio;
  }

  /// The Studio's control bar. Same actions, same handlers, same confirms as
  /// the phone layout — laid out as one bar instead of stacked pills, and in a
  /// `Wrap` so a narrow window folds to two rows rather than overflowing.
  Widget _buildStudioControls(BuildContext context, bool hasChatColumn) {
    final picker = _showCameraPicker(context);
    return NileStudioControlBar(
      isLive: _state == CameraState.live,
      isHost: _runsShow,
      isMasterAudio: _isMainAudioSource,
      videoEnabled: _videoEnabled,
      showChatToggle: !hasChatColumn,
      chatVisible: _chatVisible,
      onToggleChat: () {
        setState(() => _chatVisible = !_chatVisible);
        _prefs?.chatVisible = _chatVisible;
      },
      cameraControl: kIsWeb
          ? null
          : picker
          ? _buildCameraPickerButton()
          : NileStudioIconButton(
              onPressed: _switchCamera,
              tooltip: 'Switch camera',
              icon: Icons.flip_camera_ios,
            ),
      showScreenShare: picker,
      isSharingScreen: _isSharingScreen,
      onToggleScreenShare: _togglingShare ? null : _toggleScreenShare,
      onToggleVideo: _toggleVideo,
      onClaimMasterAudio: _claimMasterAudio,
      onViewAsViewer: _openViewerPreview,
      onStartShow: _confirmStartShow,
      isReady: _ready,
      onToggleReady: _toggleReady,
      onEndStream: _confirmEndStream,
      onLeave: _leaveStream,
      studioCameraLabel: _isStudio
          ? (defaultTargetPlatform == TargetPlatform.macOS
                ? 'Use this Mac’s camera'
                : 'Use this iPad’s camera')
          : null,
      showClaimMasterAudio: !_isStudio && !_studioInCharge,
      toolbar: _isStudio ? _buildStudioToolbar() : const [],
    );
  }

  // ── Studio toolbar ──────────────────────────────────────────────────────────

  /// The source the toolbar acts on: the monitor's selection, else the first.
  /// Placeholders for open slots count — you can rename a slot before anyone
  /// is on it — crew placeholders and screen shares don't.
  NileStudioSource? get _toolbarTarget {
    final candidates = [
      ..._localSources,
      ..._remoteSources,
    ].where((s) => !s.isScreenShare && !s.identity.startsWith('crew:'));
    return candidates
            .where((s) => s.identity == _selectedSourceId)
            .firstOrNull ??
        candidates.firstOrNull;
  }

  List<Widget> _buildStudioToolbar() {
    final target = _toolbarTarget;
    return [
      NileStudioIconButton(
        onPressed: target != null && target.isRenamable
            ? () => _renameSource(target)
            : null,
        tooltip: 'Rename camera',
        icon: Icons.drive_file_rename_outline,
      ),
      NileStudioIconButton(
        onPressed: _openGraphics,
        tooltip: 'Graphics',
        icon: Icons.layers_outlined,
        active: !_graphics.isEmpty,
      ),
      NileStudioIconButton(
        onPressed: _openElements,
        tooltip: 'Elements',
        icon: Icons.widgets_outlined,
        active: !_elementsCtl.onAir.isEmpty || !_elements.isEmpty,
      ),
      NileStudioIconButton(
        onPressed: _openLayouts,
        tooltip: 'Layouts',
        icon: Icons.dashboard_customize_outlined,
        active: _layouts.applied != null,
      ),
      NileStudioIconButton(
        onPressed: _confirmResync,
        tooltip: 'Resync cameras and audio',
        icon: Icons.sync,
      ),
      NileStudioMasterAudioMenu(
        options: _audioSourceOptions,
        current: _masterIdentity,
        onSelected: _setMasterAudio,
      ),
      if (_isMainAudioSource)
        NileStudioMicMenu(
          devices: _audioInputs,
          selectedId: _selectedMicId,
          onSelected: _selectMic,
        ),
    ];
  }

  /// Everyone who could carry the show's sound: this Studio, each camera,
  /// Stream Audio. Read off the source list, which is already filtered to
  /// publishers — the room itself may hold hundreds of viewers.
  List<NileAudioSourceOption> get _audioSourceOptions {
    final local = _room?.localParticipant;
    return [
      if (local != null)
        NileAudioSourceOption(
          identity: local.identity,
          label: 'Studio mic',
          icon: Icons.desktop_mac_outlined,
        ),
      for (final s in _remoteSources)
        if (!s.isScreenShare &&
            !s.identity.startsWith('crew:') &&
            !s.identity.startsWith('slot:'))
          NileAudioSourceOption(
            identity: s.identity,
            label: s.label,
            icon: s.label == 'Stream Audio'
                ? Icons.graphic_eq
                : Icons.videocam_outlined,
          ),
    ];
  }
}

/// What one camera phone last told the Studio over the status link.
class _CamStatus {
  _CamStatus(this.firstSeen);

  /// When the Studio first saw this camera — the "update app" grace starts.
  final DateTime firstSeen;
  double? level;
  DateTime? levelAt;
  CameraHealth? health;
  DateTime? ackAt;
}
