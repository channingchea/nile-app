import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:go_router/go_router.dart';
import 'package:livekit_client/livekit_client.dart' hide ChatMessage;
import 'package:url_launcher/url_launcher.dart';

import '../services/analytics.dart';
import '../services/screen_capture_permission.dart';
import '../services/studio_prefs.dart';
import '../theme.dart';
import '../widgets/audio_meter.dart';
import '../widgets/nile_studio.dart';
import '../widgets/screen_share_picker.dart';
import '../widgets/studio_preview_demo.dart';
import '../widgets/studio_settings_sheet.dart';

/// The host Studio as a private rehearsal.
///
/// Your camera, mic and screen share are real; everyone else — chat, crew,
/// viewers, the show clock — is [StudioPreviewDemo]. Nothing here joins a
/// room, touches an event, or sends a byte: tracks are created locally and
/// never published, which `studio_preview_safety_test.dart` holds this file to.
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
  static const _selfId = 'preview:self';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _demo.addListener(_onDemo);
    StudioPrefs.load().then<void>((p) => _prefs = p, onError: (_) {});
    NileAnalytics.capture(NileEvent.studioPreviewOpened);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Quitting from the menu bar never pops the route; the camera light must
    // still go out.
    if (state == AppLifecycleState.detached) _stopTracks();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _demo
      ..removeListener(_onDemo)
      ..dispose();
    _stopTracks();
    super.dispose();
  }

  void _onDemo() {
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
        _toast('That camera was disconnected — switched to the default camera.');
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

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
                Icon(Icons.lock_outline, size: 16, color: NileColors.txtTertiary),
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
                style: NileTextStyles.bodyMd().copyWith(color: NileColors.amber),
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
                style: NileTextStyles.bodySm().copyWith(color: NileColors.error),
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

  List<NileStudioSource> get _sources => [
    NileStudioSource(
      identity: _selfId,
      label: 'Your camera',
      sublabel: 'Broadcast audio',
      track: _videoEnabled ? _camera : null,
      isLocal: true,
      isMasterAudio: true,
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
    ...StudioPreviewDemo.crew,
  ];

  Widget _buildChat() => NileStudioChat(
    messages: _demo.messages,
    hiddenSenders: _demo.hiddenSenders,
    blockedSenders: const {},
    selfId: null,
    onHide: (m) => _demo.hide(m.senderId),
    onShowAll: _demo.showAll,
    onBlock: _previewOnly,
    onReport: _previewOnly,
    onRemove: _previewOnly,
    onBan: _previewOnly,
    onSettings: _previewOnly,
  );

  Widget _buildStudio(bool hasChatColumn) {
    final live = _demo.isLive;
    return Stack(
      children: [
        NileStudio(
          sources: _sources,
          selectedIdentity: _selectedSourceId,
          onSelectSource: (id) => setState(() => _selectedSourceId = id),
          selfIdentity: _selfId,
          stats: NileStudioStats(
            isLive: live,
            elapsed: _demo.elapsed,
            remaining: _demo.remaining,
            viewerCount: _demo.viewerCount,
            readyCount: _demo.readyCount,
            crewCount: _demo.crewCount,
            cameraCount: (_videoEnabled ? 1 : 0) + (_share != null ? 1 : 0),
            audioSourceLabel: 'Your mic',
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
          banner: StudioPreviewBanner(
            live: live,
            onChanged: (v) => _demo.isLive = v,
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
            isMasterAudio: true,
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
