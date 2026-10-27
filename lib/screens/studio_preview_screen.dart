import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:go_router/go_router.dart';
import 'package:livekit_client/livekit_client.dart' hide ChatMessage;
import 'package:url_launcher/url_launcher.dart';

import '../services/analytics.dart';
import '../services/camera_status.dart';
import '../services/chat_service.dart' show ChatMessage;
import '../services/brand_kit.dart';
import '../services/chat_tools_service.dart';
import '../services/graphics_service.dart';
import '../services/live_elements.dart';
import '../services/overlay_layout.dart';
import '../services/screen_capture_permission.dart';
import '../services/share_urls.dart';
import '../services/studio_elements_controller.dart';
import '../services/studio_graphics.dart';
import '../services/studio_prefs.dart';
import '../theme.dart';
import '../widgets/audio_meter.dart';
import '../widgets/elements/element_kinds.dart' show ElementInteraction;
import '../widgets/nile_studio.dart';
import '../widgets/screen_share_picker.dart';
import '../widgets/studio_chat_tools.dart';
import '../widgets/studio_element_hud.dart';
import '../widgets/studio_elements_panel.dart';
import '../widgets/studio_layout_sheet.dart';
import '../widgets/studio_preview_demo.dart';
import '../widgets/studio_graphics_panel.dart';
import '../widgets/studio_settings_sheet.dart';

/// The host Studio as a private rehearsal.
///
/// Your camera, mic and screen share are real; everyone else — chat, crew,
/// viewers, the show clock — is [StudioPreviewDemo]. Nothing here joins a
/// room, touches an event, or sends a byte: tracks are created locally and
/// never published, which `studio_preview_test.dart` holds this file to.
/// Every production tool — graphics, tile controls, nudges, chat tools — acts
/// on the demo or on local state. The only account data it reads is your own
/// graphics and elements libraries and quick messages, which belong to you,
/// not a show — element edits here stay in the preview.
///
/// What it does change is [StudioPrefs], on purpose — the camera, mic mode and
/// chat column picked here are what the next real Sound Check opens with.
class StudioPreviewScreen extends StatefulWidget {
  const StudioPreviewScreen({super.key});

  @override
  State<StudioPreviewScreen> createState() => _StudioPreviewScreenState();
}

class _StudioPreviewScreenState extends State<StudioPreviewScreen>
    with WidgetsBindingObserver {
  static const _selfId = StudioPreviewDemo.selfId;
  static const _shareId = 'preview:self#share';

  final _demo = StudioPreviewDemo();
  StudioPrefs? _prefs;

  bool _started = false;
  bool _starting = false;
  String? _error;

  LocalVideoTrack? _camera;
  LocalAudioTrack? _mic;
  LocalVideoTrack? _share;
  AudioVisualizer? _visualizer;
  bool _recording = false;

  /// Latest mic level, 0–1. Read by the meter on its own ticker, so it is a
  /// plain field rather than state — writing it must not rebuild the Studio.
  double _level = 0;

  List<MediaDevice> _videoInputs = const [];
  String? _selectedCameraId;
  bool _videoEnabled = true;
  bool _chatVisible = true;
  bool _disableAgc = false;
  bool _switchingMic = false;
  bool _togglingShare = false;
  String? _selectedSourceId;
  StreamSubscription? _deviceSub;

  /// Graphics rehearsed on the tiles and monitor. Local only — a preview has
  /// no show to put them on, so the panel's "push" is just a setState.
  GraphicsState _graphics = GraphicsState.empty;
  Timer? _hideTimer;

  /// Your saved library, for hotkeys 1–9, and where each graphic last went.
  List<StudioGraphic> _library = const [];
  final Map<String, GraphicTargets> _lastTargets = {};

  /// Cue before air, the host's brand kit (edited locally only here) and a
  /// stand-in sponsor so the sponsor graphic can be rehearsed.
  final _cue = ValueNotifier<CueSet>(CueSet.empty);
  BrandKit? _brandKit;
  static final _demoSponsor = StudioGraphic.sponsor(
    campaignId: 'preview-sponsor',
    sponsorName: 'Your sponsor',
  );

  /// Live elements rehearsed locally: the controller's "push" hands each
  /// change straight back. The library starts from your saved elements but
  /// saves nowhere; the demo audience votes on anything open for taps.
  late final _elements = StudioElementsController(
    push: (e, _) async => e,
    rehearsal: true,
  )..addListener(_onElements);
  final _elementLibrary = PreviewElementLibrary();

  /// Your own test votes, per element, with the round they belong to (a
  /// reset clears them).
  final Map<String, ({int round, List<String> picks})> _myVotes = {};

  /// Spots and layer order per camera (each tile's Layout sheet).
  OverlayLayout _layout = OverlayLayout.empty;

  /// Fiction for "count down to show start": ten minutes after you start.
  DateTime? _showStartAt;

  List<QuickMessage> _quickMessages = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _demo
      ..addListener(_onDemo)
      ..onAlert = _onAlert
      ..onTally = _elements.setTally;
    StudioPrefs.load().then<void>((p) => _prefs = p, onError: (_) {});
    _cue.addListener(() {
      if (mounted) setState(() {});
    });
    // Rehearse in the real kit; edits here stay in the preview.
    BrandKitService.load().then<void>((k) {
      if (mounted) setState(() => _brandKit = k);
    }, onError: (_) {});
    NileAnalytics.capture(NileEvent.studioPreviewOpened);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Quitting from the menu bar never pops the route; the camera light must
    // still go out.
    if (state == AppLifecycleState.detached) _stopTracks();
  }

  // Toasts live on the app-wide messenger; captured here so dispose can clear
  // them — an alert whose action points at the dead demo must not outlive it.
  ScaffoldMessengerState? _messenger;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.maybeOf(context);
  }

  @override
  void dispose() {
    _messenger?.clearSnackBars();
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _cue.dispose();
    _demo
      ..removeListener(_onDemo)
      ..dispose();
    _elements
      ..removeListener(_onElements)
      ..dispose();
    _stopTracks();
    super.dispose();
  }

  void _onDemo() {
    if (mounted) setState(() {});
  }

  /// Element angles become tiles, and whatever is open for taps gets votes.
  void _onElements() {
    _demo
      ..elementAngles = [for (final e in _elements.angles) e.id]
      ..vote([
        for (final item in _elements.library)
          if (_elements.live(item.id) case final e?
              when e.openChoices.isNotEmpty)
            e,
      ]);
    if (mounted) setState(() {});
  }

  // ── Devices ────────────────────────────────────────────────────────────────

  bool get _showCameraPicker {
    if (kIsWeb) return false;
    if (defaultTargetPlatform == TargetPlatform.macOS) return true;
    return defaultTargetPlatform == TargetPlatform.iOS &&
        MediaQuery.sizeOf(context).shortestSide >= 600;
  }

  /// Same rule as the real Studio. iPad shares through the broadcast
  /// extension, which only works with a live room behind it.
  bool get _canShareScreen =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  CameraCaptureOptions get _cameraOptions => _selectedCameraId != null
      ? CameraCaptureOptions(deviceId: _selectedCameraId)
      : const CameraCaptureOptions();

  Future<void> _refreshDevices() async {
    try {
      final devices = await Hardware.instance.enumerateDevices(
        type: 'videoinput',
      );
      if (!mounted) return;
      final lost =
          _selectedCameraId != null &&
          !devices.any((d) => d.deviceId == _selectedCameraId);
      setState(() {
        _videoInputs = devices;
        if (lost) _selectedCameraId = null;
      });
      if (lost && _started && _videoEnabled) {
        await _reopenCamera();
        _toast(
          'That camera was disconnected — switched to the default camera.',
        );
      }
    } catch (_) {
      // Enumeration unsupported here; the default camera still works.
    }
  }

  // ── Start / stop ───────────────────────────────────────────────────────────

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final prefs = _prefs ??= await StudioPrefs.load();
      _selectedCameraId = prefs.cameraDeviceId;
      _disableAgc = prefs.externalMicProcessing;
      _chatVisible = prefs.chatVisible;
      _videoEnabled = !prefs.videoStartsOff;
      await _refreshDevices();

      if (_videoEnabled) {
        _camera = await LocalVideoTrack.createCameraTrack(_cameraOptions);
      }
      await _openMic();
      _deviceSub = Hardware.instance.onDeviceChange.stream.listen(
        (_) => _refreshDevices(),
      );
      if (!mounted) return;
      _demo.start();
      _showStartAt = DateTime.now().add(const Duration(minutes: 10));
      unawaited(_loadLibrary());
      unawaited(_loadQuickMessages());
      setState(() => _started = true);
      NileAnalytics.capture(NileEvent.studioPreviewStarted);
    } catch (_) {
      await _stopTracks();
      if (mounted) {
        setState(
          () => _error =
              'Nile couldn’t open your camera or microphone. Allow access in '
              'System Settings → Privacy & Security, then try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _openMic() async {
    await _closeMic();
    final mic = await LocalAudioTrack.create(
      _disableAgc
          ? const AudioCaptureOptions(
              autoGainControl: false,
              noiseSuppression: false,
              echoCancellation: false,
            )
          : const AudioCaptureOptions(),
    );
    _mic = mic;
    try {
      final visualizer = createVisualizer(
        mic,
        options: const AudioVisualizerOptions(
          barCount: 7,
          centeredBands: false,
          smoothTransition: false,
        ),
      );
      visualizer.events.on<AudioVisualizerEvent>((e) {
        var peak = 0.0;
        for (final v in e.event) {
          if (v is num) peak = max(peak, v.toDouble());
        }
        _level = peak;
      });
      await visualizer.start();
      _visualizer = visualizer;
      // With no peer connection the native audio device never starts
      // capturing on its own, so the track would stay silent. LiveKit's
      // pre-connect buffer starts it the same way.
      if (!kIsWeb) {
        await rtc.NativeAudioManagement.startLocalRecording();
        _recording = true;
      }
    } catch (_) {
      // No meter on this platform; the rest of the preview still works.
    }
  }

  Future<void> _closeMic() async {
    final visualizer = _visualizer;
    final mic = _mic;
    final recording = _recording;
    _visualizer = null;
    _mic = null;
    _recording = false;
    _level = 0;
    try {
      await visualizer?.stop();
      await visualizer?.dispose();
      if (recording) await rtc.NativeAudioManagement.stopLocalRecording();
    } catch (_) {}
    await mic?.dispose();
  }

  /// Releases every device. Never calls setState — it also runs from dispose.
  Future<void> _stopTracks() async {
    unawaited(_deviceSub?.cancel());
    _deviceSub = null;
    final camera = _camera;
    final share = _share;
    _camera = null;
    _share = null;
    await _closeMic();
    await camera?.dispose();
    await share?.dispose();
  }

  Future<void> _exit() async {
    await _stopTracks();
    if (!mounted) return;
    context.canPop() ? context.pop() : context.go('/');
  }

  // ── Controls ───────────────────────────────────────────────────────────────

  Future<void> _reopenCamera() async {
    final old = _camera;
    setState(() => _camera = null);
    // Release first: a camera generally can't be opened twice.
    await old?.dispose();
    try {
      final cam = await LocalVideoTrack.createCameraTrack(_cameraOptions);
      if (!mounted) {
        unawaited(cam.dispose());
        return;
      }
      setState(() => _camera = cam);
    } catch (_) {
      if (_selectedCameraId == null || !mounted) return;
      // The picked device refused to open (busy elsewhere) — fall back.
      setState(() => _selectedCameraId = null);
      await _reopenCamera();
    }
  }

  Future<void> _selectCamera(String? deviceId) async {
    if (deviceId == _selectedCameraId) return;
    setState(() => _selectedCameraId = deviceId);
    _prefs?.cameraDeviceId = deviceId;
    if (_videoEnabled) await _reopenCamera();
  }

  /// Video Off really closes the camera, so the light goes out — the same thing
  /// a viewer would see is nothing, and the same thing the host should see is
  /// that the lens is off.
  Future<void> _toggleVideo() async {
    if (_videoEnabled) {
      final cam = _camera;
      setState(() {
        _videoEnabled = false;
        _camera = null;
      });
      await cam?.dispose();
    } else {
      setState(() => _videoEnabled = true);
      await _reopenCamera();
    }
  }

  Future<void> _setExternalMic(bool enabled) async {
    if (_switchingMic) return;
    setState(() {
      _disableAgc = enabled;
      _switchingMic = true;
    });
    _prefs?.externalMicProcessing = enabled;
    try {
      await _openMic();
    } catch (_) {
      _toast('Couldn’t reopen the microphone. Try again.');
    } finally {
      if (mounted) setState(() => _switchingMic = false);
    }
  }

  Future<void> _toggleShare() async {
    if (_togglingShare) return;
    setState(() => _togglingShare = true);
    try {
      if (_share != null) {
        await _stopShare();
        return;
      }
      if (!await ScreenCapturePermission.ensure(context)) return;
      if (!mounted) return;
      final source = await ScreenSharePicker.show(context);
      if (source == null) return;
      final track = await LocalVideoTrack.createScreenShareTrack(
        ScreenShareCaptureOptions(sourceId: source.id, maxFrameRate: 15.0),
      );
      if (!mounted) {
        unawaited(track.dispose());
        return;
      }
      // The shared window can close underneath us.
      track.mediaStreamTrack.onEnded = () {
        if (mounted && _share == track) _stopShare();
      };
      setState(() => _share = track);
    } catch (_) {
      _toast(
        'Could not share the screen. Check Screen Recording permission in '
        'System Settings → Privacy & Security, then relaunch.',
      );
    } finally {
      if (mounted) setState(() => _togglingShare = false);
    }
  }

  Future<void> _stopShare() async {
    final track = _share;
    setState(() => _share = null);
    await track?.dispose();
  }

  void _toggleChat() {
    setState(() => _chatVisible = !_chatVisible);
    _prefs?.chatVisible = _chatVisible;
  }

  void _openSettings() {
    showStudioSettingsSheet(
      context,
      externalMic: () => _disableAgc,
      switchingMic: () => _switchingMic,
      externalMicConnected: false,
      connected: true,
      onExternalMic: _setExternalMic,
      prefs: _prefs,
    );
  }

  void _toast(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    _messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: action,
          showCloseIcon: true,
          duration: Duration(seconds: action == null ? 4 : 8),
        ),
      );
  }

  /// The real Studio asks before anything viewers would notice mid-show.
  Future<bool> _confirmLive(String title, String body, String action) async {
    if (!_demo.isLive) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text(title, style: NileTextStyles.headingMd()),
        content: Text(
          body,
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
              action,
              style: NileTextStyles.labelMd().copyWith(color: NileColors.volt),
            ),
          ),
        ],
      ),
    );
    return ok == true && mounted;
  }

  // ── Graphics ───────────────────────────────────────────────────────────────

  /// The cameras a graphic or element can go on, in tile order.
  List<StudioSlotRef> get _slots => [
    for (final s in _sources)
      if (s.isAngle && s.element == null) (id: s.slotId!, label: s.label),
  ];

  Future<void> _loadLibrary() async {
    try {
      final items = await GraphicsService.list();
      if (mounted) setState(() => _library = items);
    } catch (_) {
      // Offline or signed out: the panel's presets still work.
    }
  }

  Future<bool> _push(GraphicsState next) async {
    setState(() => _graphics = next.withBrand(_brandKit?.style));
    _scheduleHide();
    return true;
  }

  /// Takes auto-hidden graphics down when they are due, as the Studio does.
  void _scheduleHide() {
    _hideTimer?.cancel();
    final at = _graphics.nextHideAt;
    if (at == null) return;
    final wait = at - DateTime.now().millisecondsSinceEpoch;
    _hideTimer = Timer(Duration(milliseconds: max(0, wait)), () {
      if (!mounted) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      setState(() => _graphics = _graphics.withoutExpired(now));
      _scheduleHide();
    });
  }

  void _openGraphics() => showGraphicsPushPanel(
    context,
    current: _graphics,
    slots: _slots,
    push: _push,
    cue: _cue,
    onTargetsUsed: (id, targets) => _lastTargets[id] = targets,
    onLibrary: (items) {
      if (mounted) setState(() => _library = items);
    },
    showStartAt: _showStartAt,
    isLive: _demo.isLive,
    sponsor: _demoSponsor,
    resolveLink: _resolveLink,
    brandKit: _brandKit,
    onBrandKit: (k) {
      setState(() => _brandKit = k);
      _push(_graphics);
    },
    brandKitDemo: true,
    takeElements: _takeElementCues,
  );

  /// Stand-in links: the real ones only exist for a real show.
  static String? _resolveLink(String source) => switch (source) {
    'event' => ShareUrls.event('preview'),
    'profile' => ShareUrls.profile('you'),
    _ => null,
  };

  Future<void> _openLibrary() async {
    await showGraphicsLibrary(
      context,
      brandKit: _brandKit,
      resolveLink: _resolveLink,
    );
    await _loadLibrary();
  }

  void _take() {
    final cues = _cue.value;
    if (cues.isEmpty) return;
    if (cues.items.isNotEmpty) _push(cues.take(_graphics, DateTime.now()));
    _takeElementCues(cues.elements);
    _cue.value = CueSet.empty;
  }

  // ── Elements + layout ──────────────────────────────────────────────────────

  Future<bool> _takeElementCues(List<ElementCue> cues) async {
    for (final c in cues) {
      await _elements.setTargets(c.id, c.targets);
    }
    return true;
  }

  void _openElements([String? select]) => showElementsPanel(
    context,
    controller: _elements,
    slots: _slots,
    cue: _cue,
    onTake: () async => _take(),
    library: _elementLibrary,
    kit: _brandKit?.style,
    initialSelected: select,
  );

  /// A HUD card's Take: just that element; the rest of the cue waits.
  Future<void> _takeOne(ElementCue c) async {
    await _elements.setTargets(c.id, c.targets);
    _cue.value = _cue.value.without(c.id);
  }

  String _camerasOf(GraphicTargets t) => t.summary(
    (id) => _slots.where((r) => r.id == id).firstOrNull?.label ?? 'Camera',
    [for (final r in _slots) r.id],
  );

  /// Preview shows elements the way a viewer sees them — a poll's totals
  /// hidden until you reveal them (or until you vote) — and you can vote too;
  /// your vote joins the pretend audience's. The Elements panel still shows
  /// the full totals.
  ElementInteraction _viewerView(LiveElement e) {
    final round = (e.state['round'] as num?)?.toInt() ?? 0;
    final mine = _myVotes[e.id];
    return ElementInteraction(
      tally: _elements.tally(e.id),
      mine: mine != null && mine.round == round ? mine.picks : const [],
      onTap: (picks) => _vote(e, picks),
    );
  }

  void _vote(LiveElement e, List<String> picks) {
    final live = _elements.live(e.id) ?? e;
    if (live.openChoices.isEmpty) return;
    final round = (live.state['round'] as num?)?.toInt() ?? 0;
    final before = _myVotes[e.id];
    _demo.castVote(
      live,
      picks,
      previous: before != null && before.round == round
          ? before.picks
          : const [],
    );
    setState(() => _myVotes[e.id] = (round: round, picks: picks));
  }

  NileOverlayExtras _overlayFor(NileStudioSource s, {bool preview = false}) {
    // An element's own angle: no camera overlay, but votes and totals.
    if (s.element != null) {
      return (
        elements: const [],
        layers: const [],
        interactionFor: _viewerView,
      );
    }
    final slot = s.isScreenShare ? null : s.slotId;
    final state = preview ? _elements.preview(_cue.value) : _elements.onAir;
    return (
      elements: state.forSlot(slot),
      layers: _layout.layersFor(slot),
      interactionFor: _viewerView,
    );
  }

  /// A camera tile's "Layout…": spots and layer order, kept locally.
  Future<void> _openLayout(NileStudioSource s) async {
    final slot = s.slotId;
    if (slot == null || s.element != null) return;
    final choice = await showLayoutSheet(
      context,
      cameraLabel: s.label,
      graphics: _graphics.forSlot(slot),
      elements: _elements.onAir.forSlot(slot),
      layers: _layout.layersFor(slot),
    );
    if (choice == null || !mounted) return;
    setState(
      () => _layout = choice.copyToAll
          ? _layout.copiedToAll(choice.layers)
          : _layout.withLayers(slot, choice.layers),
    );
  }

  Widget _cueBar() {
    final cues = _cue.value;
    final d = cues.describe(
      (id) => _slots.where((r) => r.id == id).firstOrNull?.label ?? 'Camera',
      [for (final r in _slots) r.id],
    );
    return NileStudioCueBar(
      name: d.name,
      targets: d.targets,
      count: cues.length,
      onTake: _take,
      onClear: () => _cue.value = CueSet.empty,
    );
  }

  List<LiveGraphic> _previewFor(NileStudioSource s) {
    if (s.element != null) return const [];
    final slot = s.isScreenShare ? null : s.slotId;
    final base = _graphics.withBrand(_brandKit?.style);
    return _cue.value.preview(base, DateTime.now()).forSlot(slot);
  }

  bool _isCued(NileStudioSource s) =>
      s.element == null && _cue.value.lands(s.isScreenShare ? null : s.slotId);

  void _hotkey(int digit) {
    final action = graphicsHotkeyAction(
      digit: digit,
      library: _library,
      current: _graphics,
      lastTargets: _lastTargets,
      showStartAt: _showStartAt,
      resolveLink: _resolveLink,
    );
    if (action != null) {
      if (action.cue != null) _cue.value = _cue.value.toggled(action.cue!);
      if (action.off != null) _push(action.off!);
    } else {
      _toast(
        _library.isEmpty
            ? 'Keys 1–9 play your saved graphics — add some in the Graphics '
                  'library.'
            : 'Nothing on key $digit yet.',
      );
    }
  }

  LiveGraphic _chatCard(ChatMessage m, [int seconds = 10]) =>
      LiveGraphic.chatMessage(
        messageId: m.id ?? '${m.senderId}-${m.sentAt.millisecondsSinceEpoch}',
        username: m.username,
        message: m.content,
        avatarUrl: m.avatarUrl,
        now: DateTime.now(),
        seconds: seconds,
      );

  GraphicCue _chatCue(
    ChatMessage m,
    GraphicTargets targets, [
    int seconds = 10,
  ]) => GraphicCue(
    id: _chatCard(m).id,
    name: 'Chat · @${m.username}',
    targets: targets,
    build: (_) => _chatCard(m, seconds),
  );

  void _showOnScreen(ChatMessage m) =>
      _cue.value = _cue.value.adding(_chatCue(m, const GraphicTargets.all()));

  Future<void> _showOnScreenOptions(ChatMessage m) async {
    final id = _chatCard(m).id;
    final current = _graphics.targetsOf(id);
    final choice = await showGraphicTargetsDialog(
      context,
      title: '@${m.username}',
      slots: _slots,
      initial: current,
      autoHideSeconds: 10,
      canRemove: !current.isNone,
    );
    if (choice == null || !mounted) return;
    if (choice.targets.isNone) {
      await _push(_graphics.withoutEverywhere(id));
    } else {
      _cue.value = _cue.value.adding(
        _chatCue(m, choice.targets, choice.autoHideSeconds),
      );
    }
  }

  // ── Tiles ──────────────────────────────────────────────────────────────────

  NileStudioSourceActions get _sourceActions => NileStudioSourceActions(
    onToggleOffAir: (s) {
      _demo.toggleOffAir(s.slotId!);
      _toast(
        _demo.isOffAir(s.slotId!)
            ? '${s.label} is off air. Anyone watching it moves to the '
                  'default angle.'
            : '${s.label} is back on air.',
      );
    },
    onSetDefault: (s) => _demo.toggleDefault(s.slotId!),
    onSendEveryone: _sendEveryone,
    onMakeMasterAudio: _makeMasterAudio,
    onRemoveGraphic: (s, g, {required everywhere}) => _push(
      everywhere || !s.isAngle
          ? _graphics.withoutEverywhere(g.id)
          : _graphics.withoutOnSlot(g.id, s.slotId!),
    ),
    onNudge: _nudge,
    onCommand: (s, c) {
      final notice = _demo.command(s.identity, c);
      _toast(
        notice == null ? 'Sent to ${s.label}.' : 'Sent to ${s.label}: $notice',
      );
    },
    onReorder: _demo.reorder,
    onLayout: _openLayout,
  );

  Future<void> _sendEveryone(NileStudioSource s) async {
    if (!await _confirmLive(
      'Send everyone to ${s.label}?',
      'Every viewer switches to this angle now. They can still pick another.',
      'Send everyone',
    )) {
      return;
    }
    _demo.sendEveryone(s.slotId!);
    _toast('Everyone moved to ${s.label}');
  }

  Future<void> _makeMasterAudio(NileStudioSource s) async {
    if (!await _confirmLive(
      'Switch show audio?',
      'Viewers will hear ${s.label} from now on. There may be a brief jump in '
          'the sound while it switches.',
      'Switch',
    )) {
      return;
    }
    _demo.master = s.identity;
  }

  void _nudge(NileStudioSource s, String text) {
    _demo.nudge(s.identity, text);
    _toast('Nudge sent to ${s.label}: “$text”');
  }

  void _onAlert(String identity, CameraAlertKind kind) {
    final camera = _sources.where((s) => s.identity == identity).firstOrNull;
    if (camera == null) return;
    switch (kind) {
      case CameraAlertKind.battery:
        _toast(
          '${camera.label}: battery at ${camera.health?.battery}%.',
          action: SnackBarAction(
            label: 'Send “${NudgePresets.chargeSoon}”',
            onPressed: () => _nudge(camera, NudgePresets.chargeSoon),
          ),
        );
      case CameraAlertKind.heat:
        _toast('${camera.label} is running hot — it may lower quality.');
      case CameraAlertKind.signal:
        _toast('${camera.label} has had a poor connection for a while.');
    }
  }

  // ── Chat ───────────────────────────────────────────────────────────────────

  Future<void> _loadQuickMessages() async {
    try {
      final items = await ChatToolsService.quickMessages();
      if (mounted) setState(() => _quickMessages = items);
    } catch (_) {
      // Signed out or offline: the ⚡ menu just starts empty.
    }
  }

  Future<void> _editQuickMessages() async {
    final items = await showQuickMessagesEditor(context);
    if (items == null) return _loadQuickMessages();
    if (mounted) setState(() => _quickMessages = items);
  }

  void _previewOnly([Object? _]) =>
      _toast('Preview only — nothing is broadcast.');

  void _startShowTapped() => _toast(
    'Preview only — nothing is broadcast. Use the Live switch above to see '
    'the live layout.',
  );

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final window = NileBreakpoints.of(context);
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: _started && !window.isCompact
          ? null
          : AppBar(
              leading: IconButton(
                onPressed: _exit,
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Back',
              ),
              title: Text('Studio Preview', style: NileTextStyles.headingMd()),
              backgroundColor: Colors.transparent,
            ),
      body: _started && !window.isCompact
          ? NileMaxWidth(
              maxWidth: double.infinity,
              child: _buildStudio(window.hasContextRail),
            )
          : NileMaxWidth(child: _buildIntro(window.isCompact)),
    );
  }

  Widget _buildIntro(bool compact) {
    final isMac = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(NileSpacing.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.videocam_outlined, size: 48, color: NileColors.volt),
            const SizedBox(height: NileSpacing.s16),
            Text(
              'Try the Studio before your show',
              style: NileTextStyles.headingLg(),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: NileSpacing.s8),
            Text(
              'Set up your camera and mic, learn the layout, and see how it '
              'looks in Sound Check and Live. Chat, crew and viewers are '
              'sample content.',
              style: NileTextStyles.bodyMd().copyWith(
                color: NileColors.txtSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: NileSpacing.s16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 16,
                  color: NileColors.txtTertiary,
                ),
                const SizedBox(width: NileSpacing.s8),
                Flexible(
                  child: Text(
                    'Your camera and mic stay on this device — nothing is '
                    'broadcast or recorded.',
                    style: NileTextStyles.bodySm().copyWith(
                      color: NileColors.txtTertiary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: NileSpacing.s24),
            if (compact)
              Text(
                'Studio Preview needs a wider window. Make this window wider '
                'to continue.',
                style: NileTextStyles.bodyMd().copyWith(
                  color: NileColors.amber,
                ),
                textAlign: TextAlign.center,
              )
            else
              FilledButton.icon(
                onPressed: _starting ? null : _start,
                icon: _starting
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: const Text('Start preview'),
                style: FilledButton.styleFrom(
                  backgroundColor: NileColors.volt,
                  foregroundColor: NileColors.onVolt,
                  shape: const StadiumBorder(),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: NileSpacing.s16),
              Text(
                _error!,
                style: NileTextStyles.bodySm().copyWith(
                  color: NileColors.error,
                ),
                textAlign: TextAlign.center,
              ),
              if (isMac)
                TextButton(
                  onPressed: () => launchUrl(
                    Uri.parse(
                      'x-apple.systempreferences:com.apple.preference.security'
                      '?Privacy_Camera',
                    ),
                  ),
                  child: const Text('Open System Settings'),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// Your camera, the demo crew and element angles in the order you dragged
  /// them, each with the show state the demo holds; your screen share rides
  /// under your camera.
  List<NileStudioSource> get _sources {
    final d = _demo;
    final crew = {for (final c in StudioPreviewDemo.crew) c.slotId!: c};
    final angles = {for (final e in _elements.angles) elementAngleId(e.id): e};
    return [
      for (final slot in d.order)
        if (angles[slot] case final e?)
          NileStudioSource(
            identity: slot,
            label: e.name,
            sublabel: 'Element angle',
            slotId: slot,
            element: e,
            isOffAir: d.isOffAir(slot),
            isDefaultAngle: d.defaultSlot == slot,
            viewers: d.viewersOn(slot),
          )
        else if (crew[slot] case final c?)
          NileStudioSource(
            identity: c.identity,
            label: d.labelOf(c),
            sublabel: c.sublabel,
            isReady: c.isReady,
            slotId: slot,
            isMasterAudio: d.master == c.identity,
            isOffAir: d.isOffAir(slot),
            isDefaultAngle: d.defaultSlot == slot,
            viewers: d.viewersOn(slot),
            level: d.levelOf(c.identity),
            health: d.healthOf(c.identity),
            nudgeAcked: d.ackedNudge(c.identity),
          )
        else if (slot == StudioPreviewDemo.selfSlot) ...[
          NileStudioSource(
            identity: _selfId,
            label: 'Your camera',
            sublabel: d.master == _selfId ? 'Broadcast audio' : null,
            track: _videoEnabled ? _camera : null,
            isLocal: true,
            isMasterAudio: d.master == _selfId,
            slotId: slot,
            isOffAir: d.isOffAir(slot),
            isDefaultAngle: d.defaultSlot == slot,
            viewers: d.viewersOn(slot),
          ),
          if (_share != null)
            NileStudioSource(
              identity: _shareId,
              label: 'Your screen',
              sublabel: 'Screen share',
              track: _share,
              isLocal: true,
              isScreenShare: true,
            ),
        ],
    ];
  }

  String get _audioLabel {
    final master = _demo.master;
    if (master == _selfId) return 'Your mic';
    return _demo.labelOf(
      StudioPreviewDemo.crew.firstWhere((c) => c.identity == master),
    );
  }

  Widget _buildChat() => NileStudioChat(
    messages: _demo.messages,
    hiddenSenders: _demo.hiddenSenders,
    blockedSenders: const {},
    selfId: StudioPreviewDemo.hostId,
    onHide: (m) => _demo.hide(m.senderId),
    onShowAll: _demo.showAll,
    onBlock: _previewOnly,
    onReport: _previewOnly,
    onRemove: _previewOnly,
    onBan: _previewOnly,
    onSettings: _previewOnly,
    onSend: _demo.send,
    quickMessages: _quickMessages,
    onEditQuickMessages: _editQuickMessages,
    pinned: _demo.pinned,
    onPin: _demo.pin,
    onUnpin: _demo.unpin,
    onShowOnScreen: _showOnScreen,
    onShowOnScreenOptions: _showOnScreenOptions,
    onRelease: _demo.release,
  );

  Widget _buildStudio(bool hasChatColumn) {
    final live = _demo.isLive;
    final selfIsMaster = _demo.master == _selfId;
    return StudioGraphicsHotkeys(
      // Not while a dialog (the graphics panel among them) is over the Studio.
      enabled: ModalRoute.of(context)?.isCurrent ?? true,
      onDigit: _hotkey,
      onTake: _cue.value.isEmpty ? null : _take,
      onClear: _cue.value.isEmpty ? null : () => _cue.value = CueSet.empty,
      child: Stack(
        children: [
          NileStudio(
            sources: _sources,
            selectedIdentity: _selectedSourceId,
            onSelectSource: (id) => setState(() => _selectedSourceId = id),
            selfIdentity: _selfId,
            graphicsFor: (s) => s.element != null
                ? const []
                : _graphics.forSlot(s.isScreenShare ? null : s.slotId),
            previewFor: _previewFor,
            isCued: _isCued,
            overlayFor: _overlayFor,
            previewOverlayFor: (s) => _overlayFor(s, preview: true),
            sourceActions: _sourceActions,
            stats: NileStudioStats(
              isLive: live,
              elapsed: _demo.elapsed,
              remaining: _demo.remaining,
              viewerCount: _demo.viewerCount,
              readyCount: _demo.readyCount,
              crewCount: _demo.crewCount,
              cameraCount: (_videoEnabled ? 1 : 0) + (_share != null ? 1 : 0),
              audioSourceLabel: _audioLabel,
            ),
            leading: IconButton(
              onPressed: _exit,
              icon: const Icon(Icons.arrow_back),
              color: NileColors.txtPrimary,
              tooltip: 'Exit preview',
            ),
            trailing: IconButton(
              onPressed: _openSettings,
              icon: const Icon(Icons.settings),
              color: NileColors.txtPrimary,
              tooltip: 'Audio settings',
            ),
            banner: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                StudioPreviewBanner(
                  live: live,
                  onChanged: (v) => _demo.isLive = v,
                ),
                if (_cue.value.isNotEmpty) _cueBar(),
              ],
            ),
            hud: ElementHudStrip(
              controller: _elements,
              cue: _cue,
              cameraSummary: _camerasOf,
              onTakeOne: _takeOne,
              onOpenPanel: _openElements,
            ),
            meter: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AudioMeter(level: () => _level, height: 120),
                const SizedBox(height: NileSpacing.s8),
                Text(
                  'YOUR MIC',
                  style: NileTextStyles.labelSm().copyWith(
                    color: NileColors.volt,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
            controls: NileStudioControlBar(
              isLive: live,
              isHost: true,
              isMasterAudio: selfIsMaster,
              onClaimMasterAudio: () => _demo.master = _selfId,
              videoEnabled: _videoEnabled,
              showChatToggle: !hasChatColumn,
              chatVisible: _chatVisible,
              onToggleChat: _toggleChat,
              cameraControl: _showCameraPicker
                  ? NileCameraPickerButton(
                      devices: _videoInputs,
                      selectedId: _selectedCameraId,
                      onSelected: _selectCamera,
                    )
                  : null,
              showScreenShare: _canShareScreen,
              isSharingScreen: _share != null,
              onToggleScreenShare: _togglingShare ? null : _toggleShare,
              onToggleVideo: _toggleVideo,
              onViewAsViewer: _previewOnly,
              onStartShow: _startShowTapped,
              onEndStream: _previewOnly,
              onLeave: _exit,
              leaveLabel: 'Exit',
              leaveIcon: Icons.close,
              toolbar: [
                NileStudioIconButton(
                  onPressed: _openGraphics,
                  tooltip: 'Graphics',
                  icon: Icons.layers_outlined,
                  active: !_graphics.isEmpty,
                ),
                NileStudioIconButton(
                  onPressed: _openLibrary,
                  tooltip: 'Graphics library',
                  icon: Icons.collections_bookmark_outlined,
                ),
                NileStudioIconButton(
                  onPressed: _openElements,
                  tooltip: 'Elements',
                  icon: Icons.widgets_outlined,
                  active:
                      !_elements.onAir.isEmpty || _elements.angles.isNotEmpty,
                ),
              ],
            ),
            showChatColumn: hasChatColumn,
            chat: hasChatColumn ? _buildChat() : null,
          ),
          // Too narrow for a third column: chat floats over the monitor, the
          // same fallback the real Studio uses.
          if (!hasChatColumn && _chatVisible)
            Positioned(
              right: NileSpacing.s16,
              top: 112,
              bottom: 96,
              width: NileStudio.chatColumnWidth,
              child: Material(
                color: NileColors.bgSurface,
                elevation: 8,
                borderRadius: BorderRadius.circular(NileRadius.md),
                clipBehavior: Clip.antiAlias,
                child: _buildChat(),
              ),
            ),
        ],
      ),
    );
  }
}

/// The strip under the stats row: says plainly that this is a rehearsal, and
/// switches the pretend show between Sound Check and Live.
class StudioPreviewBanner extends StatelessWidget {
  const StudioPreviewBanner({
    super.key,
    required this.live,
    required this.onChanged,
  });

  final bool live;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: NileColors.bgRaised,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          NileSpacing.s16,
          NileSpacing.s8,
          NileSpacing.s16,
          NileSpacing.s8,
        ),
        child: Row(
          children: [
            Icon(Icons.visibility_outlined, size: 18, color: NileColors.volt),
            const SizedBox(width: NileSpacing.s8),
            Expanded(
              child: Text(
                'Preview — not live. Only you can see this.',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NileTextStyles.bodySm().copyWith(
                  color: NileColors.txtPrimary,
                ),
              ),
            ),
            const SizedBox(width: NileSpacing.s8),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('Sound Check')),
                ButtonSegment(value: true, label: Text('Live')),
              ],
              selected: {live},
              onSelectionChanged: (s) => onChanged(s.first),
            ),
          ],
        ),
      ),
    );
  }
}
