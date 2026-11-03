import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:go_router/go_router.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;

import '../router.dart';
import '../services/backstage.dart';
import '../services/event_service.dart';
import '../services/interview.dart';
import '../services/interview_service.dart';
import '../services/livekit_service.dart';
import '../services/profile_service.dart';
import '../services/screen_capture_permission.dart';
import '../services/server_clock.dart';
import '../services/studio_roles.dart';
import '../theme.dart';
import '../widgets/audio_meter.dart';
import '../widgets/guest_parts.dart';
import '../widgets/interview_stage.dart';
import '../widgets/live_badge.dart';
import '../widgets/nile_studio.dart';
import '../widgets/screen_share_picker.dart';

/// What a guest's app subscribes to from one remote participant: the host's
/// talkback always (it's silent until they talk to this guest), everyone
/// visible on stage (video, plus their audio as part of the show) and the
/// show's master audio. Green-room peers stay unheard and unseen.
@visibleForTesting
({bool audio, bool video}) guestWants({
  required String identity,
  required String? role,
  required String backstage,
  required Set<String> visible,
  required String? master,
  required bool showAudio,
}) {
  if (role == NileRole.backstage) {
    return (audio: identity == backstage, video: false);
  }
  final staged = visible.contains(identity);
  return (audio: showAudio && (staged || identity == master), video: staged);
}

String _plain(Object e) => e.toString().replaceFirst('Exception: ', '');

/// `/g/<code>`: a host's share link. Puts the caller on the guest list, then
/// opens the green room by the event's LiveKit slug.
class GuestLinkScreen extends StatefulWidget {
  const GuestLinkScreen({super.key, required this.code});

  final String code;

  @override
  State<GuestLinkScreen> createState() => _GuestLinkScreenState();
}

class _GuestLinkScreenState extends State<GuestLinkScreen> {
  late final _join = LivekitService.guestJoin(widget.code);

  Future<void> _openEvent(String slug) async {
    try {
      final id = (await EventService.fetchEventState(slug))?['id'] as String?;
      if (mounted && id != null) context.pushReplacement(NileRoutes.event(id));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<({String eventId, bool isHost})>(
        future: _join,
        builder: (context, snap) {
          final d = snap.data;
          if (snap.hasError) {
            return _NoticeScaffold(
              notice: GuestNotice(
                icon: Icons.link_off_rounded,
                title: 'Can’t open this invite',
                message: _plain(snap.error!),
              ),
            );
          }
          if (d == null) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (d.isHost) {
            return _NoticeScaffold(
              notice: GuestNotice(
                icon: Icons.mic_external_on_outlined,
                title: 'You’re the host of this show',
                message:
                    'Guests use this link to join your green room. Run the '
                    'show from the Studio.',
                actionLabel: 'Open event',
                onAction: () => _openEvent(d.eventId),
              ),
            );
          }
          return GuestGreenRoomScreen(slug: d.eventId);
        },
      );
}

class _NoticeScaffold extends StatelessWidget {
  const _NoticeScaffold({required this.notice});

  final Widget notice;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: NileColors.bgPage,
    appBar: AppBar(backgroundColor: Colors.transparent),
    body: NileMaxWidth(child: notice),
  );
}

enum _Phase { loading, form, live, reconnecting, notice }

/// Interview mode, the guest's side (docs/plans/studio-modes.md, phase 3): a
/// camera check, then the green room, the "you're on in 5" countdown and the
/// stage. Pass [eventId] (events PK) or [slug] (events.livekit_room).
///
/// The guest's own tracks are only subscribable by the people behind the
/// scenes until the stage lists them ([applyGuestPrivacy], enforced by the
/// SFU). Everything that could change who that is re-applies it.
class GuestGreenRoomScreen extends StatefulWidget {
  const GuestGreenRoomScreen({super.key, this.eventId, this.slug})
    : assert(eventId != null || slug != null);

  final String? eventId;
  final String? slug;

  @override
  State<GuestGreenRoomScreen> createState() => _GuestGreenRoomScreenState();
}

class _GuestGreenRoomScreenState extends State<GuestGreenRoomScreen> {
  _Phase _phase = _Phase.loading;
  ({IconData icon, String title, String message, bool rejoin})? _notice;
  String? _error;
  bool _joining = false;
  bool _leaving = false;

  // The show.
  String? _slug;
  String? _eventTitle;
  String _status = 'scheduled';
  RealtimeChannel? _statusChannel;

  // A share-link request the host hasn't answered yet.
  String? _eventPk;
  bool _awaiting = false;
  RealtimeChannel? _inviteChannel;
  Timer? _invitePoll;

  // Who.
  String _name = '';
  String? _avatarUrl;
  final _title = TextEditingController();
  bool _savingTitle = false;
  String? _device;

  // Devices.
  List<MediaDevice> _videoInputs = const [];
  List<MediaDevice> _audioInputs = const [];
  String? _cameraId;
  String? _micId;
  bool _front = true;
  bool _micOn = true;
  bool _cameraOn = true;
  StreamSubscription<List<MediaDevice>>? _deviceSub;

  // Camera check, before there is a room.
  LocalVideoTrack? _previewCam;
  LocalAudioTrack? _previewMic;
  AudioVisualizer? _viz;
  bool _recording = false;
  double _level = 0;

  // The room.
  Room? _room;
  EventsListener<RoomEvent>? _listener;
  BackstageChat? _chat;
  String? _identity;
  StageState _stage = StageState.empty;
  List<String> _visible = const [];
  Timer? _ticker;
  ConnectionQuality _quality = ConnectionQuality.unknown;
  bool _reconnecting = false;
  bool _showAudioMuted = false;
  bool _chatOpen = true;
  bool _chatSheetOpen = false;
  LocalVideoTrack? _share;
  bool _togglingShare = false;

  /// Tracks muted while a full reconnect is in flight (see [_holdPrivacy]).
  final List<LocalTrack> _held = [];

  bool get _onStage => _identity != null && _stage.contains(_identity!);

  /// Viewers may see and hear this guest: on stage AND past the countdown.
  /// Privacy follows this, not [_onStage], so "on in 5" stays private.
  bool get _revealed =>
      _identity != null &&
      _stage.visibleAt(ServerClock.now()).contains(_identity!);
  LocalParticipant? get _lp => _room?.localParticipant;
  bool get _micLive => _lp?.isMicrophoneEnabled() ?? _micOn;
  bool get _cameraLive => _lp?.isCameraEnabled() ?? _cameraOn;
  bool get _isLive => _status == 'live';

  CameraCaptureOptions get _cameraOptions => _cameraId != null
      ? CameraCaptureOptions(deviceId: _cameraId)
      : CameraCaptureOptions(
          cameraPosition: _front ? CameraPosition.front : CameraPosition.back,
        );

  /// iPad and Mac pick devices from a menu; phones flip front/back.
  bool _hasDeviceMenus(BuildContext context) =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          (defaultTargetPlatform == TargetPlatform.iOS &&
              MediaQuery.sizeOf(context).shortestSide >= 600));

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _device = nileDeviceLabel(context);
  }

  @override
  void dispose() {
    _leaving = true;
    _statusChannel?.unsubscribe();
    _stopAwaiting();
    unawaited(_deviceSub?.cancel());
    unawaited(_teardownRoom());
    unawaited(_stopPreview());
    _title.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _showNotice(
    IconData icon,
    String title,
    String message, {
    bool rejoin = false,
  }) {
    if (!mounted) return;
    unawaited(_stopPreview());
    setState(() {
      _phase = _Phase.notice;
      _notice = (icon: icon, title: title, message: message, rejoin: rejoin);
    });
  }

  void _showEnded() => _showNotice(
    Icons.event_busy_outlined,
    'This show has ended',
    'Thanks for being a guest.',
  );

  void _showRemoved() => _showNotice(
    Icons.person_remove_outlined,
    'You’re off the show',
    'The host removed you from the show.',
  );

  /// Waits for the host to answer a share-link request: the guest's own
  /// row changes (realtime), with a slow poll in case that drops.
  void _startAwaiting() {
    final pk = _eventPk;
    if (pk == null) return;
    _awaiting = true;
    _inviteChannel ??= InterviewService.watch(pk, _recheckInvite);
    _invitePoll ??= Timer.periodic(
      const Duration(seconds: 15),
      (_) => _recheckInvite(),
    );
  }

  void _stopAwaiting() {
    _inviteChannel?.unsubscribe();
    _inviteChannel = null;
    _invitePoll?.cancel();
    _invitePoll = null;
  }

  Future<void> _recheckInvite() async {
    final pk = _eventPk;
    if (pk == null || !_awaiting) return;
    InterviewGuest? invite;
    try {
      invite = await InterviewService.myInvite(pk);
    } catch (_) {
      return; // Next change or poll tries again.
    }
    if (!mounted || !_awaiting) return;
    if (invite == null || invite.status == GuestStatus.removed) {
      _awaiting = false;
      _stopAwaiting();
      return _showNotice(
        Icons.person_off_outlined,
        'The host didn’t let you in',
        'Ask the host if you think this is a mistake.',
      );
    }
    if (invite.status == GuestStatus.requested) return;
    _stopAwaiting();
    setState(() => _awaiting = false);
    _toast('The host let you in. Join when you’re ready.');
  }

  /// Server refusals that end the visit rather than asking for a retry.
  bool _handleRefusal(Object e) {
    final msg = _plain(e);
    if (msg.contains('Waiting for the host')) {
      setState(() {
        _joining = false;
        _startAwaiting();
      });
      unawaited(_openPreview());
    } else if (msg.contains('ended')) {
      _showEnded();
    } else if (msg.contains('removed')) {
      _showRemoved();
    } else if (msg.contains('guest list')) {
      _showNotice(Icons.lock_outline, 'You’re not a guest on this show', msg);
    } else {
      return false;
    }
    return true;
  }

  // ── Getting in ─────────────────────────────────────────────────────────────

  Future<void> _resolve() async {
    try {
      var slug = widget.slug;
      if (slug == null) {
        final event = await EventService.fetchById(widget.eventId!);
        if (event == null) throw Exception('This show isn’t available.');
        slug = event.liveKitEventId;
        if (slug == null) {
          throw Exception('The host hasn’t set this show up yet.');
        }
      }
      final state = await EventService.fetchEventState(slug);
      if (state == null) throw Exception('This show isn’t available.');
      final status = state['status'] as String? ?? 'scheduled';
      if (Event.isOverAt(
        status: status,
        scheduledAt: DateTime.tryParse(state['scheduled_at'] as String? ?? ''),
        endAt: DateTime.tryParse(state['end_at'] as String? ?? ''),
      )) {
        return _showEnded();
      }
      final results = await Future.wait([
        InterviewService.myInvite(state['id'] as String),
        ProfileService.fetchCurrentProfile(),
      ]);
      final invite = results[0] as InterviewGuest?;
      final profile = results[1] as UserProfile?;
      if (invite == null) {
        return _showNotice(
          Icons.lock_outline,
          'You’re not a guest on this show',
          'Ask the host for an invite.',
        );
      }
      if (invite.status == GuestStatus.removed) return _showRemoved();
      if (!mounted) return;
      _slug = slug;
      _eventPk = state['id'] as String;
      if (invite.status == GuestStatus.requested) _startAwaiting();
      _eventTitle = state['title'] as String?;
      _status = status;
      _name = (profile?.displayName.isNotEmpty ?? false)
          ? profile!.displayName
          : profile?.username ?? invite.name;
      _avatarUrl = profile?.avatarUrl ?? invite.avatarUrl;
      _title.text = invite.title ?? '';
      _statusChannel = EventService.subscribeToEvent(
        liveKitEventId: slug,
        onUpdate: (r) {
          final s = r['status'] as String?;
          if (s == null || !mounted) return;
          setState(() => _status = s);
          if (s == 'ended') {
            unawaited(_teardownRoom());
            _showEnded();
          }
        },
      );
      setState(() => _phase = _Phase.form);
      await _openPreview();
    } catch (e) {
      _showNotice(Icons.error_outline, 'Can’t open the green room', _plain(e));
    }
  }

  Future<void> _refreshDevices() async {
    try {
      final video = await Hardware.instance.enumerateDevices(
        type: 'videoinput',
      );
      final audio = await Hardware.instance.enumerateDevices(
        type: 'audioinput',
      );
      if (!mounted) return;
      final lostCam =
          _cameraId != null && !video.any((d) => d.deviceId == _cameraId);
      final lostMic = _micId != null && !audio.any((d) => d.deviceId == _micId);
      setState(() {
        _videoInputs = video;
        _audioInputs = audio;
      });
      // An unplugged device falls back to the default rather than freezing.
      if (lostCam) await _selectCamera(null);
      if (lostMic) await _selectMic(null);
    } catch (_) {
      // Enumeration unsupported here; the defaults still work.
    }
  }

  Future<void> _openPreview() async {
    _deviceSub ??= Hardware.instance.onDeviceChange.stream.listen(
      (_) => _refreshDevices(),
    );
    await _refreshDevices();
    try {
      if (_cameraOn) await _reopenPreviewCamera();
      if (_micOn) await _openPreviewMic();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Nile couldn’t open your camera or microphone. Allow access '
              'in Settings, then try again.',
        );
      }
    }
  }

  Future<void> _reopenPreviewCamera() async {
    final old = _previewCam;
    _previewCam = null;
    _refresh();
    // Release first: a camera generally can't be opened twice.
    await old?.dispose();
    if (!_cameraOn || _phase != _Phase.form) return;
    final cam = await LocalVideoTrack.createCameraTrack(_cameraOptions);
    if (!mounted || _phase != _Phase.form) {
      unawaited(cam.dispose());
      return;
    }
    setState(() => _previewCam = cam);
  }

  /// Same as Studio Setup's preview mic: a track plus a visualizer for the
  /// meter, with native recording started because there's no peer connection
  /// to start it.
  Future<void> _openPreviewMic() async {
    await _closePreviewMic();
    final mic = await LocalAudioTrack.create(
      AudioCaptureOptions(deviceId: _micId),
    );
    _previewMic = mic;
    try {
      final viz = createVisualizer(
        mic,
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
        _level = peak.clamp(0.0, 1.0);
      });
      await viz.start();
      _viz = viz;
      if (!kIsWeb) {
        await rtc.NativeAudioManagement.startLocalRecording();
        _recording = true;
      }
    } catch (_) {
      // No meter on this platform; the check still works.
    }
  }

  Future<void> _closePreviewMic() async {
    final viz = _viz;
    final mic = _previewMic;
    final recording = _recording;
    _viz = null;
    _previewMic = null;
    _recording = false;
    _level = 0;
    try {
      await viz?.stop();
      await viz?.dispose();
      if (recording) await rtc.NativeAudioManagement.stopLocalRecording();
    } catch (_) {}
    await mic?.dispose();
  }

  /// Never calls setState — it also runs from dispose.
  Future<void> _stopPreview() async {
    final cam = _previewCam;
    _previewCam = null;
    await _closePreviewMic();
    await cam?.dispose();
  }

  Future<void> _join() async {
    if (_joining || _slug == null) return;
    setState(() {
      _joining = true;
      _error = null;
    });
    // Hand the devices to the room; the preview can't share them.
    await _stopPreview();
    try {
      await _connect(title: _title.text.trim());
    } catch (e) {
      if (!mounted || _handleRefusal(e)) return;
      setState(() {
        _joining = false;
        _error = _plain(e);
      });
      await _openPreview();
    }
  }

  Future<void> _connect({String? title}) async {
    unawaited(ServerClock.ensure());
    final conn = await LivekitService.guestToken(
      eventId: _slug!,
      title: title,
      device: _device,
    );
    // adaptiveStream sizes each subscribed feed to its tile, so the small
    // stage preview pulls a low layer and the on-stage view a high one.
    final room = Room(roomOptions: const RoomOptions(adaptiveStream: true));
    final listener = room.createListener();
    _wire(listener);
    try {
      await room
          .connect(
            conn.wsUrl,
            conn.token,
            connectOptions: const ConnectOptions(autoSubscribe: false),
          )
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () =>
                throw Exception('Connection timed out. Try again.'),
          );
    } catch (_) {
      await listener.dispose();
      await room.disconnect();
      rethrow;
    }
    // Left, or the show ended / the guest was removed while connecting.
    if (!mounted || _leaving || _phase == _Phase.notice) {
      await listener.dispose();
      await room.disconnect();
      return;
    }
    _room = room;
    _listener = listener;
    _identity = conn.identity;
    _stage = StageState.fromRoomMetadata(room.metadata);
    // Privacy before a single track is published.
    _applyPrivacy();
    final lp = room.localParticipant!;
    try {
      if (_cameraOn) {
        await lp
            .setCameraEnabled(true, cameraCaptureOptions: _cameraOptions)
            .timeout(const Duration(seconds: 15));
      }
      if (_micOn) {
        await lp.setMicrophoneEnabled(
          true,
          audioCaptureOptions: AudioCaptureOptions(deviceId: _micId),
        );
      }
    } catch (_) {
      _toast('Couldn’t open your camera or microphone.');
    }
    _chat = BackstageChat(room, selfName: _name)..addListener(_onChat);
    if (!mounted) return;
    setState(() {
      _phase = _Phase.live;
      _joining = false;
      _reconnecting = false;
    });
    _syncSubscriptions();
    _tickStage();
  }

  void _wire(EventsListener<RoomEvent> l) {
    void people() {
      _applyPrivacy();
      _syncSubscriptions();
      _refresh();
    }

    l
      ..on<ParticipantConnectedEvent>((_) => people())
      ..on<ParticipantDisconnectedEvent>((_) => people())
      ..on<ParticipantMetadataUpdatedEvent>((_) => people())
      ..on<RoomMetadataChangedEvent>((e) => _onRoomMetadata(e.metadata))
      ..on<TrackPublishedEvent>((_) => _syncSubscriptions())
      // The host opening the talkback line to this guest arrives as a
      // permission change; subscribe() is ignored while it isn't allowed.
      ..on<TrackSubscriptionPermissionChangedEvent>((_) => _syncSubscriptions())
      ..on<TrackSubscribedEvent>((_) => _refresh())
      ..on<TrackUnsubscribedEvent>((_) => _refresh())
      ..on<TrackUnpublishedEvent>((_) => _refresh())
      ..on<TrackMutedEvent>((_) => _refresh())
      ..on<TrackUnmutedEvent>((_) => _refresh())
      ..on<ActiveSpeakersChangedEvent>((_) => _refresh())
      ..on<LocalTrackPublishedEvent>((_) => _refresh())
      // The share can end outside our button (iPad's system broadcast stop,
      // the shared window closing on macOS).
      ..on<LocalTrackUnpublishedEvent>((e) {
        if (e.publication.source == TrackSource.screenShareVideo) {
          _share = null;
        }
        _refresh();
      })
      ..on<ParticipantConnectionQualityUpdatedEvent>((e) {
        if (e.participant is! LocalParticipant) return;
        _quality = e.connectionQuality;
        _refresh();
      })
      // A resume keeps the server session (and its permissions; the SDK
      // resends them). A full restart doesn't — see [_holdPrivacy].
      ..on<RoomResumingEvent>((_) {
        _reconnecting = true;
        _refresh();
      })
      ..on<RoomReconnectingEvent>((_) {
        _reconnecting = true;
        _holdPrivacy();
        _refresh();
      })
      ..on<RoomReconnectedEvent>((_) {
        _reconnecting = false;
        _applyPrivacy();
        _releasePrivacyHold();
        _syncSubscriptions();
        _refresh();
      })
      ..on<RoomDisconnectedEvent>((e) => _onDisconnected(e.reason));
  }

  // ── Privacy ────────────────────────────────────────────────────────────────

  void _applyPrivacy() {
    final room = _room;
    if (room != null) applyGuestPrivacy(room, onStage: _revealed);
  }

  /// A full reconnect (livekit_client 2.7) republishes this guest's tracks
  /// and never resends subscription permissions, and the new server session
  /// starts open to everyone. Off stage, mute until [_applyPrivacy] has gone
  /// out again. Tracks, not publications: the republish replaces those.
  void _holdPrivacy() {
    final lp = _lp;
    if (lp == null || _revealed) return;
    for (final pub in [
      ...lp.videoTrackPublications,
      ...lp.audioTrackPublications,
    ]) {
      final track = pub.track;
      if (track != null && !track.muted) {
        _held.add(track);
        unawaited(track.mute());
      }
    }
  }

  void _releasePrivacyHold() {
    for (final track in _held) {
      unawaited(track.unmute());
    }
    _held.clear();
  }

  // ── The stage ──────────────────────────────────────────────────────────────

  void _onRoomMetadata(String? raw) {
    final stage = StageState.fromRoomMetadata(raw);
    if (stage == _stage) return;
    final wasOn = _onStage;
    _stage = stage;
    _applyPrivacy();
    _syncSubscriptions();
    _tickStage();
    if (wasOn && !_onStage) {
      if (_share != null) unawaited(_toggleShare());
      _toast('You’re back in the green room.');
    } else if (!wasOn && _onStage) {
      unawaited(HapticFeedback.mediumImpact());
    }
    _refresh();
  }

  /// Runs while anyone's "on in 5" is counting down: redraws the countdown
  /// and subscribes to people the moment they appear.
  void _tickStage() {
    final visible = _stage.visibleAt(ServerClock.now());
    if (!listEquals(visible, _visible)) {
      _visible = visible;
      _applyPrivacy();
      _syncSubscriptions();
    }
    final pending = _stage.entries.length != visible.length;
    if (!pending) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    _ticker ??= Timer.periodic(const Duration(milliseconds: 250), (_) {
      _refresh();
      _tickStage();
    });
  }

  void _syncSubscriptions() {
    final room = _room;
    final slug = _slug;
    if (room == null || slug == null) return;
    final remotes = room.remoteParticipants.values;
    final master = resolveMasterAudio([
      for (final p in remotes)
        PublisherInfo.fromMeta(p.identity, parseParticipantMeta(p.metadata)),
    ]);
    final visible = _stage.visibleAt(ServerClock.now()).toSet();
    for (final p in remotes) {
      final role = parseParticipantMeta(p.metadata)['role'];
      final want = guestWants(
        identity: p.identity,
        role: role is String ? role : null,
        backstage: backstageIdentity(slug),
        visible: visible,
        master: master,
        showAudio: _onStage || !_showAudioMuted,
      );
      for (final pub in p.trackPublications.values) {
        final w = pub.kind == TrackType.AUDIO
            ? want.audio
            : want.video && pub.source == TrackSource.camera;
        if (w && !pub.subscribed) unawaited(pub.subscribe());
        if (!w && pub.subscribed) unawaited(pub.unsubscribe());
      }
    }
  }

  /// The host's talkback is open to this guest and unmuted.
  bool get _hostTalking {
    final room = _room;
    final slug = _slug;
    if (room == null || slug == null) return false;
    final p = room.remoteParticipants[backstageIdentity(slug)];
    return p?.audioTrackPublications.any((a) => a.subscribed && !a.muted) ??
        false;
  }

  VideoTrack? get _selfTrack {
    if (_room == null) return _previewCam;
    final pub = _lp?.videoTrackPublications
        .where((p) => p.source == TrackSource.camera && !p.muted)
        .firstOrNull;
    return pub?.track as VideoTrack?;
  }

  List<StageTile> _stageTiles() {
    final room = _room;
    if (room == null) return const [];
    return [
      for (final id in _stage.visibleAt(ServerClock.now()))
        if (id == _identity)
          StageTile(
            identity: id,
            name: _name,
            title: _title.text.trim().isEmpty ? null : _title.text.trim(),
            avatarUrl: _avatarUrl,
            track: _selfTrack,
            speaking: _lp?.isSpeaking ?? false,
            muted: !_micLive,
          )
        else if (room.remoteParticipants[id] case final p?)
          _remoteTile(p),
    ];
  }

  StageTile _remoteTile(RemoteParticipant p) {
    final g = GuestMeta.fromJson(parseParticipantMeta(p.metadata));
    final cam = p.videoTrackPublications
        .where((t) => t.source == TrackSource.camera && t.subscribed)
        .where((t) => !t.muted)
        .firstOrNull;
    return StageTile(
      identity: p.identity,
      name: g?.name ?? (p.name.isNotEmpty ? p.name : 'Host'),
      title: g?.title,
      avatarUrl: g?.avatarUrl,
      track: cam?.track as VideoTrack?,
      speaking: p.isSpeaking,
      muted: !p.isMicrophoneEnabled(),
    );
  }

  // ── Controls ───────────────────────────────────────────────────────────────

  Future<void> _toggleMic() async {
    final on = !_micLive;
    setState(() => _micOn = on);
    final lp = _lp;
    try {
      if (lp == null) {
        on ? await _openPreviewMic() : await _closePreviewMic();
      } else {
        await lp.setMicrophoneEnabled(
          on,
          audioCaptureOptions: AudioCaptureOptions(deviceId: _micId),
        );
      }
    } catch (_) {
      _toast('Couldn’t change your microphone.');
      if (mounted) setState(() => _micOn = !on);
    }
    _refresh();
  }

  Future<void> _toggleCamera() async {
    final on = !_cameraLive;
    setState(() => _cameraOn = on);
    final lp = _lp;
    try {
      if (lp == null) {
        await _reopenPreviewCamera();
      } else {
        await lp.setCameraEnabled(
          on,
          cameraCaptureOptions: on ? _cameraOptions : null,
        );
      }
    } catch (_) {
      _toast('Couldn’t change your camera.');
      if (mounted) setState(() => _cameraOn = !on);
    }
    _refresh();
  }

  /// Restart the camera with the current options (camera_screen's pattern).
  Future<void> _restartCamera() async {
    final lp = _lp;
    if (lp == null) return _reopenPreviewCamera();
    if (!_cameraLive) return;
    await lp.setCameraEnabled(false);
    await lp.setCameraEnabled(true, cameraCaptureOptions: _cameraOptions);
    _refresh();
  }

  Future<void> _selectCamera(String? id) async {
    if (id == _cameraId && id != null) return;
    setState(() => _cameraId = id);
    try {
      await _restartCamera();
    } catch (_) {
      if (id == null || !mounted) return;
      // The picked device refused to open (busy elsewhere) — fall back.
      await _selectCamera(null);
    }
  }

  Future<void> _flipCamera() async {
    final front = !_front;
    final track = _selfTrack;
    try {
      if (_room != null && track is LocalVideoTrack) {
        var nowFront = front;
        if (defaultTargetPlatform == TargetPlatform.android) {
          // Android can't reopen the other lens while this one is releasing;
          // the native switch has no such race (see camera_screen).
          nowFront = await rtc.Helper.switchCamera(track.mediaStreamTrack);
          track.currentOptions = CameraCaptureOptions(
            cameraPosition: nowFront
                ? CameraPosition.front
                : CameraPosition.back,
          );
        } else {
          await track.setCameraPosition(
            front ? CameraPosition.front : CameraPosition.back,
          );
        }
        if (!mounted) return;
        setState(() {
          _front = nowFront;
          _cameraId = null;
        });
      } else {
        setState(() {
          _front = front;
          _cameraId = null;
        });
        await _reopenPreviewCamera();
      }
    } catch (_) {
      _toast('Couldn’t switch cameras.');
    }
  }

  Future<void> _selectMic(String? id) async {
    if (id == _micId && id != null) return;
    setState(() => _micId = id);
    final lp = _lp;
    try {
      if (lp == null) {
        if (_micOn) await _openPreviewMic();
        return;
      }
      final existing = lp.audioTrackPublications.firstOrNull;
      if (existing != null) await lp.removePublishedTrack(existing.sid);
      if (_micOn) {
        await lp.setMicrophoneEnabled(
          true,
          audioCaptureOptions: AudioCaptureOptions(deviceId: _micId),
        );
      }
    } catch (_) {
      if (id == null) return;
      _toast('Couldn’t open that input. Back to the default mic.');
      await _selectMic(null);
    }
    _refresh();
  }

  /// Screen share, on stage, where it works today: macOS (source picker) and
  /// iPad (the broadcast extension). Same path as camera_screen.
  Future<void> _toggleShare() async {
    final lp = _lp;
    if (lp == null || _togglingShare) return;
    setState(() => _togglingShare = true);
    try {
      if (_share != null || lp.isScreenShareEnabled()) {
        await _stopShare(lp);
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        final pub = await lp.setScreenShareEnabled(
          true,
          screenShareCaptureOptions: const ScreenShareCaptureOptions(
            useiOSBroadcastExtension: true,
            maxFrameRate: 15.0,
          ),
        );
        _share = pub?.track as LocalVideoTrack?;
      } else {
        if (!await ScreenCapturePermission.ensure(context)) return;
        if (!mounted) return;
        final source = await ScreenSharePicker.show(context);
        if (source == null) return;
        final track = await LocalVideoTrack.createScreenShareTrack(
          ScreenShareCaptureOptions(sourceId: source.id, maxFrameRate: 15.0),
        );
        await lp.publishVideoTrack(track);
        _share = track;
      }
    } catch (_) {
      _toast(
        defaultTargetPlatform == TargetPlatform.iOS
            ? 'Couldn’t start the screen broadcast. Try again.'
            : 'Couldn’t share the screen. Check Screen Recording permission '
                  'in System Settings → Privacy & Security, then relaunch.',
      );
    } finally {
      if (mounted) setState(() => _togglingShare = false);
    }
  }

  Future<void> _stopShare(LocalParticipant lp) async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await lp.setScreenShareEnabled(false);
    } else if (_share case final track?) {
      final pub = lp.videoTrackPublications
          .where((p) => p.track == track)
          .firstOrNull;
      if (pub != null) await lp.removePublishedTrack(pub.sid);
      await track.stop();
    }
    _share = null;
  }

  void _toggleShowAudio() {
    setState(() => _showAudioMuted = !_showAudioMuted);
    _syncSubscriptions();
  }

  Future<void> _saveTitle() async {
    final slug = _slug;
    if (slug == null || _savingTitle) return;
    final t = _title.text.trim();
    setState(() => _savingTitle = true);
    try {
      await LivekitService.setGuestTitle(
        eventId: slug,
        title: t.isEmpty ? null : t,
      );
      _toast('Name tag saved.');
    } catch (e) {
      _toast(_plain(e));
    } finally {
      if (mounted) setState(() => _savingTitle = false);
    }
  }

  void _onChat() {
    final chat = _chat;
    if (chat == null || !mounted) return;
    // Wide layouts show the chat beside the green room (and beside the stage
    // unless it's closed), so it's read as it lands.
    final wide = !NileBreakpoints.of(context).isCompact;
    if (_chatSheetOpen || (wide && (!_onStage || _chatOpen))) chat.markRead();
    _refresh();
  }

  Future<void> _openChatSheet() async {
    final chat = _chat;
    if (chat == null) return;
    chat.markRead();
    _chatSheetOpen = true;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: NileColors.bgSurface,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: NileSpacing.s16,
          right: NileSpacing.s16,
          top: NileSpacing.s16,
          bottom: MediaQuery.viewInsetsOf(ctx).bottom + NileSpacing.s16,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.5,
          child: ListenableBuilder(
            listenable: chat,
            builder: (_, _) =>
                GuestChatPanel(messages: chat.messages, onSend: chat.send),
          ),
        ),
      ),
    );
    _chatSheetOpen = false;
  }

  Future<void> _openNameTagSheet() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: NileColors.bgSurface,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
        left: NileSpacing.s16,
        right: NileSpacing.s16,
        top: NileSpacing.s16,
        bottom: MediaQuery.viewInsetsOf(ctx).bottom + NileSpacing.s16,
      ),
      child: _titleEditor(),
    ),
  );

  void _toggleChatPanel() {
    setState(() => _chatOpen = !_chatOpen);
    if (_chatOpen) _chat?.markRead();
  }

  // ── Leaving ────────────────────────────────────────────────────────────────

  Future<void> _onDisconnected(DisconnectReason? reason) async {
    if (_leaving || !mounted || _room == null) return;
    switch (reason) {
      case DisconnectReason.clientInitiated:
        return;
      case DisconnectReason.participantRemoved:
        await _teardownRoom();
        return _showRemoved();
      case DisconnectReason.duplicateIdentity:
        await _teardownRoom();
        return _showNotice(
          Icons.devices_outlined,
          'Joined on another device',
          'You joined this show from another device.',
        );
      default:
        await _rejoin();
    }
  }

  /// The network dropped for good (or the room was closed): mint a fresh
  /// token and come back, a few times, before asking the guest.
  Future<void> _rejoin() async {
    await _teardownRoom();
    if (!mounted) return;
    setState(() => _phase = _Phase.reconnecting);
    for (var attempt = 1; attempt <= 4; attempt++) {
      await Future<void>.delayed(Duration(seconds: attempt * 2));
      if (!mounted || _leaving) return;
      try {
        await _connect();
        return;
      } catch (e) {
        if (_handleRefusal(e)) return;
      }
    }
    _showNotice(
      Icons.wifi_off_rounded,
      'Lost the connection',
      'Check your network, then rejoin the green room.',
      rejoin: true,
    );
  }

  Future<void> _backToForm() async {
    setState(() {
      _phase = _Phase.form;
      _notice = null;
      _error = null;
    });
    await _openPreview();
  }

  /// Releases the room and everything hung off it. Never calls setState — it
  /// also runs from dispose.
  Future<void> _teardownRoom() async {
    _ticker?.cancel();
    _ticker = null;
    final room = _room;
    final listener = _listener;
    final chat = _chat;
    _room = null;
    _listener = null;
    _chat = null;
    _identity = null;
    _stage = StageState.empty;
    _visible = const [];
    _held.clear();
    chat
      ?..removeListener(_onChat)
      ..dispose();
    // Stop capture explicitly — disconnect unpublishes the share but doesn't
    // always halt the native capturer promptly.
    try {
      if (room?.localParticipant case final lp?) {
        if (_share != null || lp.isScreenShareEnabled()) await _stopShare(lp);
      }
    } catch (_) {}
    _share = null;
    await listener?.dispose();
    await room?.disconnect();
  }

  Future<void> _leave() async {
    if (_onStage) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Leave the stage?'),
          content: const Text('Viewers will see you go.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Stay'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Leave'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    _leaving = true;
    await _teardownRoom();
    await _stopPreview();
    if (!mounted) return;
    context.canPop() ? context.pop() : context.go(NileRoutes.feed);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final inRoom = _phase == _Phase.live || _phase == _Phase.reconnecting;
    return PopScope(
      canPop: !inRoom,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: switch (_phase) {
        _Phase.loading => const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
        _Phase.notice => _NoticeScaffold(
          notice: GuestNotice(
            icon: _notice!.icon,
            title: _notice!.title,
            message: _notice!.message,
            actionLabel: _notice!.rejoin ? 'Rejoin' : null,
            onAction: _notice!.rejoin ? _backToForm : null,
          ),
        ),
        _Phase.form => _buildForm(context),
        _Phase.reconnecting => _buildReconnecting(),
        _Phase.live => _buildLive(context),
      },
    );
  }

  Widget _buildReconnecting() => Scaffold(
    backgroundColor: NileColors.bgPage,
    body: NileMaxWidth(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: NileSpacing.s16),
            Text('Reconnecting…', style: NileTextStyles.bodyMd()),
            const SizedBox(height: NileSpacing.s24),
            TextButton(onPressed: _leave, child: const Text('Leave')),
          ],
        ),
      ),
    ),
  );

  Widget _buildForm(BuildContext context) => Scaffold(
    backgroundColor: NileColors.bgPage,
    appBar: AppBar(
      backgroundColor: Colors.transparent,
      title: Text('Green room', style: NileTextStyles.headingSm()),
    ),
    body: NileMaxWidth(
      child: GuestPreJoinForm(
        eventTitle: _eventTitle,
        preview: AspectRatio(aspectRatio: 16 / 9, child: _selfPreview()),
        controls: _controlBar(context, leave: false),
        name: _name,
        titleController: _title,
        joining: _joining,
        waiting: _awaiting,
        error: _error,
        onJoin: _join,
      ),
    ),
  );

  /// The guest's own camera with a mic meter: the preview mic before joining,
  /// the published one after.
  Widget _selfPreview() {
    final track = _selfTrack;
    final lp = _lp;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (track != null)
            VideoTrackRenderer(
              track,
              fit: VideoViewFit.cover,
              mirrorMode: _front || _cameraId != null
                  ? VideoViewMirrorMode.mirror
                  : VideoViewMirrorMode.off,
            )
          else
            StageAvatar(name: _name, avatarUrl: _avatarUrl),
          Positioned(
            right: NileSpacing.s8,
            top: NileSpacing.s8,
            bottom: NileSpacing.s8,
            child: Center(
              child: lp != null
                  ? AudioMeter(participant: lp, height: 96, active: _micLive)
                  : AudioMeter(level: () => _level, height: 96, active: _micOn),
            ),
          ),
        ],
      ),
    );
  }

  Widget _controlBar(
    BuildContext context, {
    bool leave = true,
    bool share = false,
    bool chatButton = false,
    bool nameTag = false,
  }) {
    final menus = _hasDeviceMenus(context);
    return GuestControlBar(
      micOn: _micLive,
      cameraOn: _cameraLive,
      onMic: _toggleMic,
      onCamera: _toggleCamera,
      onFlip: menus ? null : _flipCamera,
      devicePickers: [
        if (menus) ...[
          NileCameraPickerButton(
            devices: _videoInputs,
            selectedId: _cameraId,
            onSelected: _selectCamera,
          ),
          NileStudioMicMenu(
            devices: _audioInputs,
            selectedId: _micId,
            onSelected: _selectMic,
          ),
        ],
      ],
      sharing: _share != null,
      onShare: share && menus && !_togglingShare ? _toggleShare : null,
      showAudioMuted: _showAudioMuted,
      onShowAudio: _room != null && !_onStage ? _toggleShowAudio : null,
      onNameTag: nameTag ? _openNameTagSheet : null,
      chatUnread: _chat?.unread ?? 0,
      onChat: chatButton ? _onChatButton : null,
      onLeave: leave ? _leave : null,
    );
  }

  void _onChatButton() => NileBreakpoints.of(context).isCompact
      ? unawaited(_openChatSheet())
      : _toggleChatPanel();

  Widget _titleEditor() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Name tag', style: NileTextStyles.labelMd()),
      const SizedBox(height: NileSpacing.s8),
      Text(_name, style: NileTextStyles.bodyMd()),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _title,
              maxLength: 60,
              onSubmitted: (_) => _saveTitle(),
              decoration: const InputDecoration(
                labelText: 'Title',
                hintText: 'e.g. Director',
              ),
            ),
          ),
          TextButton(
            onPressed: _savingTitle ? null : _saveTitle,
            child: const Text('Save'),
          ),
        ],
      ),
    ],
  );

  Widget _buildLive(BuildContext context) {
    final countdown = _identity == null
        ? null
        : _stage.countdownFor(_identity!, ServerClock.now());
    final body = _onStage && countdown == null
        ? _buildStage(context)
        : _buildGreenRoom(context);
    return Scaffold(
      backgroundColor: _onStage ? Colors.black : NileColors.bgPage,
      body: NileMaxWidth(
        maxWidth: double.infinity,
        child: Stack(
          children: [
            Positioned.fill(child: body),
            if (countdown != null)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.8),
                  child: Center(child: GuestCountdown(seconds: countdown)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusLine() => Wrap(
    spacing: NileSpacing.s12,
    runSpacing: NileSpacing.s8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hourglass_top, size: 18, color: NileColors.txtSecondary),
          const SizedBox(width: NileSpacing.s6),
          Text(
            'Waiting for the host to bring you on',
            style: NileTextStyles.labelMd(),
          ),
        ],
      ),
      if (_hostTalking) const GuestTalkbackPill(),
    ],
  );

  Widget _stagePreview() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('On stage now', style: NileTextStyles.labelSm()),
      const SizedBox(height: NileSpacing.s6),
      ClipRRect(
        borderRadius: BorderRadius.circular(NileRadius.sm),
        child: _stageView(compact: true),
      ),
    ],
  );

  Widget _stageView({required bool compact}) {
    final tiles = _stageTiles();
    return InterviewStageView(
      tiles: tiles,
      layout: _stage.layout,
      focusIndex: _stage.focusIndexIn([for (final t in tiles) t.identity]),
      compact: compact,
    );
  }

  Widget _chatPanel() {
    final chat = _chat;
    if (chat == null) return const SizedBox.shrink();
    return GuestChatPanel(messages: chat.messages, onSend: chat.send);
  }

  Widget _buildGreenRoom(BuildContext context) {
    final compact = NileBreakpoints.of(context).isCompact;
    final health = GuestHealthRow(
      quality: _quality,
      micOn: _micLive,
      cameraOn: _cameraLive,
      reconnecting: _reconnecting,
    );
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_eventTitle != null)
          Text(_eventTitle!, style: NileTextStyles.caption()),
        Text('Green room', style: NileTextStyles.headingSm()),
        const SizedBox(height: NileSpacing.s8),
        _statusLine(),
      ],
    );
    final preview = ClipRRect(
      borderRadius: BorderRadius.circular(NileRadius.md),
      child: AspectRatio(aspectRatio: 16 / 9, child: _selfPreview()),
    );
    if (compact) {
      return SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(NileSpacing.s16),
                children: [
                  header,
                  const SizedBox(height: NileSpacing.s16),
                  preview,
                  const SizedBox(height: NileSpacing.s12),
                  health,
                  const SizedBox(height: NileSpacing.s24),
                  _stagePreview(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(NileSpacing.s12),
              child: _controlBar(context, chatButton: true, nameTag: true),
            ),
          ],
        ),
      );
    }
    return SafeArea(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(NileSpacing.s24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  const SizedBox(height: NileSpacing.s16),
                  Expanded(child: Center(child: preview)),
                  const SizedBox(height: NileSpacing.s12),
                  health,
                  const SizedBox(height: NileSpacing.s16),
                  _controlBar(context),
                ],
              ),
            ),
          ),
          Container(
            width: 340,
            padding: const EdgeInsets.all(NileSpacing.s16),
            decoration: BoxDecoration(
              color: NileColors.bgSurface,
              border: Border(left: BorderSide(color: NileColors.border)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _stagePreview(),
                const SizedBox(height: NileSpacing.s16),
                _titleEditor(),
                const SizedBox(height: NileSpacing.s16),
                Expanded(child: _chatPanel()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStage(BuildContext context) {
    final compact = NileBreakpoints.of(context).isCompact;
    final top = Padding(
      padding: const EdgeInsets.all(NileSpacing.s12),
      child: Wrap(
        spacing: NileSpacing.s12,
        runSpacing: NileSpacing.s8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (_isLive)
            const LiveBadge()
          else
            Text(
              'On stage — rehearsal (not live yet)',
              style: NileTextStyles.labelMd().copyWith(color: Colors.white),
            ),
          if (_hostTalking) const GuestTalkbackPill(),
          if (_reconnecting)
            Text(
              'Reconnecting…',
              style: NileTextStyles.labelSm().copyWith(
                color: NileColors.warning,
              ),
            ),
        ],
      ),
    );
    final stage = Expanded(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s12),
          child: _stageView(compact: false),
        ),
      ),
    );
    final controls = Padding(
      padding: const EdgeInsets.all(NileSpacing.s12),
      child: _controlBar(context, share: true, chatButton: true),
    );
    return SafeArea(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: Column(children: [top, stage, controls])),
          if (!compact && _chatOpen)
            Container(
              width: 320,
              padding: const EdgeInsets.all(NileSpacing.s16),
              color: NileColors.bgSurface,
              child: _chatPanel(),
            ),
        ],
      ),
    );
  }
}
