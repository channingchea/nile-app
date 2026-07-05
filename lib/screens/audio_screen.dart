import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;
import '../services/livekit_service.dart';
import '../services/event_service.dart';
import '../widgets/audio_meter.dart';
import '../theme.dart';

class AudioScreen extends StatefulWidget {
  /// When supplied (assigned audio operator entering from an event), the Event
  /// ID field is pre-filled and Sound Check starts automatically.
  final String? initialEventId;

  /// True when the signed-in user owns this event. Realistically the Stream
  /// Audio operator is never the host, but the param mirrors CameraScreen for
  /// consistency — it gates the Sound Check revert-to-scheduled on leave.
  final bool isHost;

  const AudioScreen({super.key, this.initialEventId, this.isHost = false});

  @override
  State<AudioScreen> createState() => _AudioScreenState();
}

enum AudioStreamState { idle, connecting, soundCheck, live }

class _AudioScreenState extends State<AudioScreen> {
  final _eventIdController = TextEditingController();

  AudioStreamState _streamState = AudioStreamState.idle;
  Room? _room;
  String? _eventId;
  String? _errorMessage;

  /// My "Ready to Stream" flag during Sound Check (mirrored to the host's crew
  /// panel via participant metadata). Always starts false on connect.
  bool _ready = false;

  /// True when this operator (re)joined while the show was already live (e.g.
  /// after a drop). The auto soundcheck→live flip is suppressed and they
  /// rejoin the show by pressing "Ready to Stream" instead.
  bool _joinedLiveShow = false;

  /// Non-host: the host starts/ends the show from their camera screen, so this
  /// screen follows the DB status (the single source of truth) via realtime.
  RealtimeChannel? _statusChannel;

  @override
  void initState() {
    super.initState();
    final id = widget.initialEventId;
    if (id != null && id.isNotEmpty) {
      _eventIdController.text = id;
      WidgetsBinding.instance.addPostFrameCallback((_) => _enterSoundCheck());
    }
  }

  @override
  void dispose() {
    _statusChannel?.unsubscribe();
    _eventIdController.dispose();
    _room?.disconnect();
    super.dispose();
  }

  /// Connect and publish audio, then land in Sound Check so the operator can set
  /// mixer gain against the live meter before any viewer hears the feed. The show
  /// only goes live on Start Show.
  Future<void> _enterSoundCheck() async {
    final eventId = _eventIdController.text.trim();

    if (eventId.isEmpty) {
      setState(() => _errorMessage = 'Please enter an Event ID.');
      return;
    }

    setState(() {
      _streamState = AudioStreamState.connecting;
      _errorMessage = null;
    });

    try {
      final conn = await LivekitService.audioToken(eventId: eventId);

      final room = Room();
      await room.connect(conn.wsUrl, conn.token);

      // Line-level feed from a soundboard: disable WebRTC's auto-gain, noise
      // suppression and echo cancellation so the operator's manual gain staging
      // is what viewers hear (and what the meter reflects).
      final track = await LocalAudioTrack.create(
        const AudioCaptureOptions(
          autoGainControl: false,
          noiseSuppression: false,
          echoCancellation: false,
        ),
      );
      await room.localParticipant?.publishAudioTrack(track);

      setState(() {
        _room = room;
        _eventId = eventId;
        _ready = false; // metadata always starts ready: false at token-issue
        _streamState = AudioStreamState.soundCheck;
      });

      // Best-effort; the show only goes live when the host presses Start Show.
      EventService.enterSoundCheck(eventId).catchError((_) {});

      // If the show is already live (rejoin after a drop), suppress the auto
      // soundcheck→live flip: they re-enter via "Ready to Stream" instead.
      _joinedLiveShow = false;
      EventService.fetchEventState(eventId)
          .then((state) {
            if (mounted) _joinedLiveShow = state?['status'] == 'live';
          })
          .catchError((_) {});

      // Follow the show's DB status: flip to LIVE when the host starts it,
      // tear down when it ends.
      _statusChannel?.unsubscribe();
      _statusChannel = EventService.subscribeToEvent(
        liveKitEventId: eventId,
        onUpdate: (record) {
          if (!mounted) return;
          final status = record['status'];
          if (status == 'live' &&
              _streamState == AudioStreamState.soundCheck &&
              !_joinedLiveShow) {
            setState(() => _streamState = AudioStreamState.live);
          } else if (status == 'ended') {
            _stopStreaming();
          }
        },
      );
    } catch (e) {
      setState(() {
        _streamState = AudioStreamState.idle;
        _errorMessage = 'Failed to connect: ${e.toString()}';
      });
    }
  }

  /// Toggle my "Ready to Stream" flag — surfaced on the host's crew panel.
  Future<void> _toggleReady() async {
    if (_eventId == null) return;
    final next = !_ready;
    setState(() => _ready = next);
    try {
      await LivekitService.setReady(eventId: _eventId!, ready: next);
      if (next &&
          _joinedLiveShow &&
          mounted &&
          _streamState == AudioStreamState.soundCheck) {
        setState(() => _streamState = AudioStreamState.live);
      }
    } catch (_) {
      if (mounted) setState(() => _ready = !next); // revert on failure
    }
  }

  /// Leave the feed. Never ends a live show (host-only, from their camera
  /// screen). Only a HOST leaving during Sound Check reverts to scheduled.
  Future<void> _stopStreaming() async {
    if (_eventId != null &&
        widget.isHost &&
        _streamState == AudioStreamState.soundCheck) {
      EventService.revertToScheduled(_eventId!).catchError((_) {});
    }
    _statusChannel?.unsubscribe();
    _statusChannel = null;
    await _room?.disconnect();
    if (!mounted) return;
    setState(() {
      _room = null;
      _eventId = null;
      _ready = false;
      _joinedLiveShow = false;
      _streamState = AudioStreamState.idle;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        title: Text('Stream Audio', style: NileTextStyles.headingMd()),
        backgroundColor: Colors.transparent,
      ),
      body: NileMaxWidth(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(NileSpacing.s32),
          child: switch (_streamState) {
            AudioStreamState.idle ||
            AudioStreamState.connecting => _buildForm(),
            AudioStreamState.soundCheck ||
            AudioStreamState.live => _buildLive(),
          },
        ),
      ),
    );
  }

  Widget _buildForm() {
    final isConnecting = _streamState == AudioStreamState.connecting;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 48),
        Icon(Icons.album, size: 64, color: NileColors.border),
        const SizedBox(height: 24),
        Text(
          'Master Audio',
          textAlign: TextAlign.center,
          style: NileTextStyles.headingLg(),
        ),
        const SizedBox(height: 8),
        Text(
          'Connect a mixer or sound board to this device\nand stream audio to all viewers.',
          textAlign: TextAlign.center,
          style: NileTextStyles.bodyMd().copyWith(
            color: NileColors.txtSecondary,
          ),
        ),
        const SizedBox(height: 48),
        TextField(
          controller: _eventIdController,
          enabled: !isConnecting,
          style: NileTextStyles.bodyLg(),
          decoration: const InputDecoration(
            labelText: 'Event ID',
            hintText: 'e.g. my-live-show',
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
        // Enter Sound Check — volt CTA. Going live happens from Start Show.
        FilledButton.icon(
          onPressed: isConnecting ? null : _enterSoundCheck,
          icon: isConnecting
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: NileColors.onVolt,
                  ),
                )
              : const Icon(Icons.tune),
          label: Text(isConnecting ? 'Connecting...' : 'Sound Check'),
          style: FilledButton.styleFrom(
            backgroundColor: NileColors.volt,
            foregroundColor: NileColors.onVolt,
            padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
            textStyle: NileTextStyles.labelLg(),
            shape: const StadiumBorder(),
          ),
        ),
      ],
    );
  }

  Widget _buildLive() {
    final inSoundCheck = _streamState == AudioStreamState.soundCheck;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_room?.localParticipant != null) ...[
          Center(child: AudioMeter(participant: _room!.localParticipant!)),
          const SizedBox(height: 24),
          Text(
            'Keep levels out of the red. If CLIP lights, lower the gain\non your mixer — clipping can\'t be fixed after the fact.',
            textAlign: TextAlign.center,
            style: NileTextStyles.bodyMd().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
          const SizedBox(height: 32),
        ] else
          Icon(Icons.mic, size: 80, color: NileColors.volt),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16, vertical: NileSpacing.s12),
          decoration: BoxDecoration(
            color: inSoundCheck ? NileColors.bgRaised : NileColors.coral,
            borderRadius: BorderRadius.circular(NileRadius.sm),
          ),
          child: Text(
            inSoundCheck ? 'SOUND CHECK' : '● LIVE AUDIO',
            textAlign: TextAlign.center,
            style: NileTextStyles.labelLg().copyWith(
              color: Colors.white,
              letterSpacing: 2,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          inSoundCheck
              ? 'Set your mixer levels against the meter.\nViewers can\'t hear this yet.'
              : 'Master audio is streaming.\nViewers are hearing this feed.',
          textAlign: TextAlign.center,
          style: NileTextStyles.bodyMd().copyWith(
            color: NileColors.txtSecondary,
          ),
        ),
        const SizedBox(height: 48),
        // Ready to Stream — tells the host this feed is good to go. The show
        // itself is started by the host (Start Show lives on their screen).
        if (inSoundCheck) ...[
          if (_ready)
            FilledButton.icon(
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
          else
            OutlinedButton.icon(
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
          const SizedBox(height: 12),
        ],
        OutlinedButton.icon(
          onPressed: _stopStreaming,
          icon: const Icon(Icons.stop, color: NileColors.error),
          label: Text(
            inSoundCheck ? 'Cancel' : 'Stop Audio',
            style: NileTextStyles.labelMd().copyWith(color: NileColors.error),
          ),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
            side: const BorderSide(color: NileColors.error),
            shape: const StadiumBorder(),
          ),
        ),
      ],
    );
  }
}
