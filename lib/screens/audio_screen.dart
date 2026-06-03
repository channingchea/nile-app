import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import '../services/livekit_service.dart';
import '../theme.dart';

class AudioScreen extends StatefulWidget {
  const AudioScreen({super.key});

  @override
  State<AudioScreen> createState() => _AudioScreenState();
}

enum AudioStreamState { idle, connecting, live }

class _AudioScreenState extends State<AudioScreen> {
  final _eventIdController = TextEditingController();

  AudioStreamState _streamState = AudioStreamState.idle;
  Room? _room;
  String? _errorMessage;

  @override
  void dispose() {
    _eventIdController.dispose();
    _room?.disconnect();
    super.dispose();
  }

  Future<void> _startStreaming() async {
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
      await room.localParticipant?.setMicrophoneEnabled(true);

      setState(() {
        _room = room;
        _streamState = AudioStreamState.live;
      });
    } catch (e) {
      setState(() {
        _streamState = AudioStreamState.idle;
        _errorMessage = 'Failed to connect: ${e.toString()}';
      });
    }
  }

  Future<void> _stopStreaming() async {
    await _room?.disconnect();
    setState(() {
      _room = null;
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
          AudioStreamState.live => _buildLive(),
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
        // Go Live — volt CTA
        FilledButton.icon(
          onPressed: isConnecting ? null : _startStreaming,
          icon: isConnecting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: NileColors.bgPage,
                  ),
                )
              : const Icon(Icons.mic),
          label: Text(isConnecting ? 'Connecting...' : 'Go Live'),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.mic, size: 80, color: NileColors.volt),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: NileColors.coral,
            borderRadius: BorderRadius.circular(NileRadius.sm),
          ),
          child: Text(
            '● LIVE AUDIO',
            textAlign: TextAlign.center,
            style: NileTextStyles.labelLg().copyWith(
              color: Colors.white,
              letterSpacing: 2,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Master audio is streaming.\nViewers are hearing this feed.',
          textAlign: TextAlign.center,
          style: NileTextStyles.bodyMd().copyWith(color: NileColors.txtSecondary),
        ),
        const SizedBox(height: 48),
        OutlinedButton.icon(
          onPressed: _stopStreaming,
          icon: const Icon(Icons.stop, color: NileColors.error),
          label: Text(
            'Stop Audio',
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
