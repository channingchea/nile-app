import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'camera_screen.dart';
import 'viewer_screen.dart';
import '../config.dart';

class CreateEventScreen extends StatefulWidget {
  const CreateEventScreen({super.key});

  @override
  State<CreateEventScreen> createState() => _CreateEventScreenState();
}

enum _CreateState { idle, creating, created }

class _CreateEventScreenState extends State<CreateEventScreen> {
  final _eventNameController = TextEditingController();

  _CreateState _state = _CreateState.idle;
  String? _errorMessage;
  String? _eventId;
  String? _eventName;

  @override
  void dispose() {
    _eventNameController.dispose();
    super.dispose();
  }

  // Generate a URL-safe event ID from the event name
  String _generateEventId(String name) {
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '-');
    final suffix = (DateTime.now().millisecondsSinceEpoch % 10000)
        .toString()
        .padLeft(4, '0');
    return slug.isNotEmpty ? '$slug-$suffix' : 'event-$suffix';
  }

  Future<void> _createEvent() async {
    final name = _eventNameController.text.trim();

    if (name.isEmpty) {
      setState(() => _errorMessage = 'Please enter an event name.');
      return;
    }

    setState(() {
      _state = _CreateState.creating;
      _errorMessage = null;
    });

    final eventId = _generateEventId(name);

    try {
      final response = await http.post(
        Uri.parse('$backendUrl/api/create-event'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'eventId': eventId, 'eventName': name}),
      );

      if (response.statusCode != 200) {
        throw Exception('Server returned ${response.statusCode}');
      }

      setState(() {
        _eventId = eventId;
        _eventName = name;
        _state = _CreateState.created;
      });
    } catch (e) {
      setState(() {
        _state = _CreateState.idle;
        _errorMessage = 'Failed to create event: ${e.toString()}';
      });
    }
  }

  void _copyEventId() {
    if (_eventId == null) return;
    Clipboard.setData(ClipboardData(text: _eventId!));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Event ID copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Event'),
        backgroundColor: Colors.transparent,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(32.0),
        child: _state == _CreateState.created
            ? _buildCreated()
            : _buildForm(),
      ),
    );
  }

  Widget _buildForm() {
    final isCreating = _state == _CreateState.creating;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 48),
        const Icon(Icons.live_tv, size: 64, color: Colors.white38),
        const SizedBox(height: 24),
        const Text(
          'New Event',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Give your event a name. Cameras and viewers\nwill use the generated Event ID to connect.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: Colors.white54),
        ),
        const SizedBox(height: 48),
        TextField(
          controller: _eventNameController,
          enabled: !isCreating,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Event Name',
            hintText: 'e.g. Spring Concert 2025',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _createEvent(),
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
        ],
        const SizedBox(height: 32),
        FilledButton.icon(
          onPressed: isCreating ? null : _createEvent,
          icon: isCreating
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.add_circle_outline),
          label: Text(isCreating ? 'Creating...' : 'Create Event'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            textStyle: const TextStyle(fontSize: 18),
          ),
        ),
      ],
    );
  }

  Widget _buildCreated() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 48),
        const Icon(Icons.check_circle, size: 64, color: Colors.greenAccent),
        const SizedBox(height: 16),
        Text(
          _eventName!,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Event created. Share the Event ID below\nwith your camera operators and viewers.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: Colors.white54),
        ),
        const SizedBox(height: 40),

        // Event ID display
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.white10,
            border: Border.all(color: Colors.white24),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'EVENT ID',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white38,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _eventId!,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: _copyEventId,
                icon: const Icon(Icons.copy),
                tooltip: 'Copy',
                color: Colors.white54,
              ),
            ],
          ),
        ),

        const SizedBox(height: 40),

        // Quick-start buttons
        FilledButton.icon(
          onPressed: () => Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => CameraScreen(initialEventId: _eventId),
            ),
          ),
          icon: const Icon(Icons.videocam),
          label: const Text('Start Camera'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            textStyle: const TextStyle(fontSize: 16),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => ViewerScreen(initialEventId: _eventId),
            ),
          ),
          icon: const Icon(Icons.tv),
          label: const Text('Watch as Viewer'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            textStyle: const TextStyle(fontSize: 16),
          ),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Back to Home', style: TextStyle(color: Colors.white38)),
        ),
      ],
    );
  }
}
