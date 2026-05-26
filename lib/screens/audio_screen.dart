import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';
import '../config.dart';

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
      final response = await http.post(
        Uri.parse('$backendUrl/api/audio-token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'eventId': eventId}),
      );

      if (response.statusCode != 200) {
        throw Exception('Server returned ${response.statusCode}');
      }

      final data = jsonDecode(response.body);
      final token = data['token'] as String;
      final wsUrl = data['wsUrl'] as String;

      // Connect and publish microphone only (no video)
      final room = Room();
      await room.connect(wsUrl, token);
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
      appBar: AppBar(
        title: const Text('Stream Audio'),
        backgroundColor: Colors.transparent,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(32.0),
        child: switch (_streamState) {
          AudioStreamState.idle || AudioStreamState.connecting => _buildForm(),
          AudioStreamState.live => _buildLive(),
        },
      ),
    );
  }

  Widget _buildForm() {
    final isConnecting = _streamState == AudioStreamState.connecting;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 48),
        const Icon(Icons.album, size: 64, color: Colors.white38),
        const SizedBox(height: 24),
        const Text(
          'Master Audio',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Connect a mixer or sound board to this device\nand stream audio to all viewers.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: Colors.white54),
        ),
        const SizedBox(height: 48),
        TextField(
          controller: _eventIdController,
          enabled: !isConnecting,
          decoration: const InputDecoration(
            labelText: 'Event ID',
            hintText: 'e.g. show-2024-01',
            border: OutlineInputBorder(),
          ),
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
        ],
        const SizedBox(height: 32),
        FilledButton.icon(
          onPressed: isConnecting ? null : _startStreaming,
          icon: isConnecting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.mic),
          label: Text(isConnecting ? 'Connecting...' : 'Go Live'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            textStyle: const TextStyle(fontSize: 18),
            backgroundColor: Colors.green,
          ),
        ),
      ],
    );
  }

  Widget _buildLive() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.mic, size: 80, color: Colors.greenAccent),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.green,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            '● LIVE AUDIO',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 18,
              letterSpacing: 2,
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Master audio is streaming.\nViewers are hearing this feed.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: Colors.white54),
        ),
        const SizedBox(height: 48),
        OutlinedButton.icon(
          onPressed: _stopStreaming,
          icon: const Icon(Icons.stop, color: Colors.red),
          label: const Text(
            'Stop Audio',
            style: TextStyle(color: Colors.red, fontSize: 16),
          ),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            side: const BorderSide(color: Colors.red),
          ),
        ),
      ],
    );
  }
}
