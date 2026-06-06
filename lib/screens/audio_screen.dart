import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import '../services/livekit_service.dart';
import '../services/event_service.dart';
import '../widgets/audio_meter.dart';
import '../theme.dart';

class AudioScreen extends StatefulWidget {
  /// When supplied (assigned audio operator entering from an event), the Event
  /// ID field is pre-filled and Sound Check starts automatically.
  final String? initialEventId;

  const AudioScreen({super.key, this.initialEventId});

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
      final track = await LocalAudioTrack.create(const AudioCaptureOptions(
        autoGainControl: false,
        noiseSuppression: false,
        echoCancellation: false,
      ));
      await room.localParticipant?.publishAudioTrack(track);

      setState(() {
        _room = room;
        _eventId = eventId;
        _streamState = AudioStreamState.soundCheck;
      });

      // Best-effort; the show only goes live on Start Show.
      EventService.enterSoundCheck(eventId).catchError((_) {});
    } catch (e) {
      setState(() {
        _streamState = AudioStreamState.idle;
        _errorMessage = 'Failed to connect: ${e.toString()}';
      });
    }
  }

  /// Flip the event live — viewers waiting in the Lobby now hear the feed.
  Future<void> _startShow() async {
    if (_eventId != null) {
      EventService.goLive(_eventId!).catchError((_) {});
      // Stamp the camera-sync anchor (showStartedAt) into the room metadata.
      LivekitService.startShow(eventId: _eventId!).catchError((_) {});
    }
    setState(() => _streamState = AudioStreamState.live);
  }

  Future<void> _stopStreaming() async {
    // Live → end it; left during Sound Check → revert to scheduled.
    if (_eventId != null) {
      if (_streamState == AudioStreamState.live) {
        EventService.end(_eventId!).catchError((_) {});
      } else if (_streamState == AudioStreamState.soundCheck) {
        EventService.revertToScheduled(_eventId!).catchError((_) {});
      }
    }
    await _room?.disconnect();
    setState(() {
      _room = null;
      _eventId = null;
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
      body: NileMaxWidth(child: SingleChildScrollView(
        padding: const EdgeInsets.all(32.0),
        child: switch (_streamState) {
          AudioStreamState.idle || AudioStreamState.connecting => _buildForm(),
          AudioStreamState.soundCheck || AudioStreamState.live => _buildLive(),
        },
      )),
    );
  }

  Widget _buildForm() {
    final isConnecting = _streamState == AudioStreamState.connecting;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 48),
        const Icon(Icons.album, size: 64, color: NileColors.border),
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
          style: NileTextStyles.bodyMd().copyWith(color: NileColors.txtSecondary),
        ),
        const SizedBox(height: 48),
        TextField(
          controller: _eventIdController,
          enabled: !isConnecting,
          style: NileTextStyles.bodyLg(),
          decoration: const InputDecoration(
            labelText: 'Event ID',
            hintText: 'e.g. show-2024-01',
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
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: NileColors.bgPage,
                  ),
                )
              : const Icon(Icons.tune),
          label: Text(isConnecting ? 'Connecting...' : 'Sound Check'),
          style: FilledButton.styleFrom(
            backgroundColor: NileColors.volt,
            foregroundColor: NileColors.bgPage,
            padding: const EdgeInsets.symmetric(vertical: 16),
            textStyle: NileTextStyles.labelLg(),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(NileRadius.sm),
            ),
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
            style: NileTextStyles.bodyMd().copyWith(color: NileColors.txtSecondary),
          ),
          const SizedBox(height: 32),
        ] else
          const Icon(Icons.mic, size: 80, color: NileColors.volt),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
          style: NileTextStyles.bodyMd().copyWith(color: NileColors.txtSecondary),
        ),
        const SizedBox(height: 48),
        if (inSoundCheck) ...[
          FilledButton.icon(
            onPressed: _startShow,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start Show'),
            style: FilledButton.styleFrom(
              backgroundColor: NileColors.coral,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              textStyle: NileTextStyles.labelLg(),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(NileRadius.sm),
              ),
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
            padding: const EdgeInsets.symmetric(vertical: 16),
            side: const BorderSide(color: NileColors.error),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(NileRadius.sm),
            ),
          ),
        ),
      ],
    );
  }
}
