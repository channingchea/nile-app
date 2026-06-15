import 'package:croppy/croppy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/event_service.dart';
import '../services/livekit_service.dart';
import '../services/profile_service.dart';
import '../theme.dart';
import 'camera_screen.dart';
import 'viewer_screen.dart';

class CreateEventScreen extends StatefulWidget {
  const CreateEventScreen({super.key});

  @override
  State<CreateEventScreen> createState() => _CreateEventScreenState();
}

enum _CreateState { idle, creating, created }

class _CreateEventScreenState extends State<CreateEventScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _priceController = TextEditingController();
  final _ticketLimitController = TextEditingController();

  Uint8List? _coverBytes;
  bool _uploadingCover = false;

  DateTime? _scheduledAt;

  _CreateState _state = _CreateState.idle;
  String? _errorMessage;
  String? _eventId;
  String? _eventName;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _priceController.dispose();
    _ticketLimitController.dispose();
    super.dispose();
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

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

  String _formatScheduled(DateTime dt) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final t =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year} · $t';
  }

  // ── Actions ─────────────────────────────────────────────────────────────────

  Future<void> _pickCover() async {
    setState(() => _uploadingCover = true);
    try {
      final bytes = await ProfileService.pickImageBytes(
        context,
        maxWidth: 1600,
        maxHeight: 900,
        allowedAspectRatios: [const CropAspectRatio(width: 16, height: 9)],
      );
      if (bytes != null && mounted) setState(() => _coverBytes = bytes);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _uploadingCover = false);
    }
  }

  Future<void> _pickDateTime() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _scheduledAt ?? now.add(const Duration(hours: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365 * 2)),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: NileColors.volt,
            onPrimary: NileColors.bgPage,
            surface: NileColors.bgSurface,
            onSurface: NileColors.txtPrimary,
          ),
        ),
        child: child!,
      ),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
        _scheduledAt ?? now.add(const Duration(hours: 1)),
      ),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: NileColors.volt,
            onPrimary: NileColors.bgPage,
            surface: NileColors.bgSurface,
            onSurface: NileColors.txtPrimary,
          ),
        ),
        child: child!,
      ),
    );
    if (time == null) return;
    setState(() {
      _scheduledAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _createEvent() async {
    if (!_formKey.currentState!.validate()) return;
    final name = _nameController.text.trim();
    final desc = _descriptionController.text.trim();
    final priceText = _priceController.text.trim();
    final limitText = _ticketLimitController.text.trim();

    setState(() {
      _state = _CreateState.creating;
      _errorMessage = null;
    });

    final eventId = _generateEventId(name);

    try {
      // 1) Create the LiveKit room via the livekit Edge Function.
      await LivekitService.createRoom(eventId: eventId, eventName: name);

      // 2) Upload cover photo if provided. Non-fatal — if the bucket isn't
      // configured or the upload fails, we still create the event row.
      String? coverUrl;
      if (_coverBytes != null) {
        try {
          coverUrl = await EventService.uploadCoverBytes(
            liveKitEventId: eventId,
            bytes: _coverBytes!,
          );
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Cover upload failed — saved without one. ($e)'),
              ),
            );
          }
        }
      }

      // 3) Persist event row.
      final priceCents = priceText.isEmpty
          ? null
          : (double.parse(priceText) * 100).round();
      final ticketLimit = limitText.isEmpty ? null : int.parse(limitText);

      await EventService.create(
        title: name,
        liveKitEventId: eventId,
        description: desc.isEmpty ? null : desc,
        coverImageUrl: coverUrl,
        scheduledAt: _scheduledAt,
        price: priceCents,
        ticketLimit: ticketLimit,
      );

      if (!mounted) return;
      setState(() {
        _eventId = eventId;
        _eventName = name;
        _state = _CreateState.created;
      });
    } catch (e) {
      if (!mounted) return;
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

  // ── UI ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        title: Text('Create Event', style: NileTextStyles.headingMd()),
        backgroundColor: Colors.transparent,
      ),
      body: NileMaxWidth(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(NileSpacing.s24, NileSpacing.s8, NileSpacing.s24, NileSpacing.s40),
          child: _state == _CreateState.created
              ? _buildCreated()
              : _buildForm(),
        ),
      ),
    );
  }

  Widget _buildForm() {
    final isCreating = _state == _CreateState.creating;

    return AbsorbPointer(
      absorbing: isCreating,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CoverPicker(
              bytes: _coverBytes,
              busy: _uploadingCover,
              onPick: _pickCover,
              onClear: () => setState(() => _coverBytes = null),
            ),
            const SizedBox(height: 24),
            _SectionLabel('Event Name'),
            const SizedBox(height: 6),
            TextFormField(
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              maxLength: 80,
              decoration: const InputDecoration(
                hintText: 'e.g. Spring Concert 2025',
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 20),
            _SectionLabel('Description'),
            const SizedBox(height: 6),
            TextFormField(
              controller: _descriptionController,
              maxLines: 4,
              maxLength: 500,
              decoration: const InputDecoration(
                hintText: 'Tell viewers what to expect…',
              ),
            ),
            const SizedBox(height: 20),
            _SectionLabel('Scheduled For'),
            const SizedBox(height: 6),
            _DateField(
              value: _scheduledAt,
              onTap: _pickDateTime,
              onClear: () => setState(() => _scheduledAt = null),
              formatter: _formatScheduled,
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SectionLabel('Price (USD)'),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _priceController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'^\d*\.?\d{0,2}'),
                          ),
                        ],
                        decoration: const InputDecoration(
                          prefixText: '\$ ',
                          hintText: 'Free',
                        ),
                        validator: (v) {
                          if (v == null || v.isEmpty) return null;
                          final n = double.tryParse(v);
                          if (n == null || n < 0) return 'Invalid';
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SectionLabel('Ticket Limit'),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _ticketLimitController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: const InputDecoration(
                          hintText: 'Unlimited',
                        ),
                        validator: (v) {
                          if (v == null || v.isEmpty) return null;
                          final n = int.tryParse(v);
                          if (n == null || n <= 0) return 'Invalid';
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(NileSpacing.s12),
                decoration: BoxDecoration(
                  color: NileColors.error.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(NileRadius.sm),
                  border: Border.all(
                    color: NileColors.error.withValues(alpha: 0.4),
                  ),
                ),
                child: Text(
                  _errorMessage!,
                  style: NileTextStyles.bodySm().copyWith(
                    color: NileColors.error,
                  ),
                ),
              ),
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
                        color: NileColors.bgPage,
                      ),
                    )
                  : const Icon(Icons.add_circle_outline),
              label: Text(isCreating ? 'Creating…' : 'Create Event'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                textStyle: NileTextStyles.labelLg().copyWith(color: null),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCreated() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 32),
        const Icon(Icons.check_circle, size: 64, color: NileColors.volt),
        const SizedBox(height: 16),
        Text(
          _eventName!,
          textAlign: TextAlign.center,
          style: NileTextStyles.headingLg(),
        ),
        const SizedBox(height: 8),
        Text(
          'Event created. Share the Event ID below\nwith your camera operators and viewers.',
          textAlign: TextAlign.center,
          style: NileTextStyles.bodyMd().copyWith(
            color: NileColors.txtSecondary,
          ),
        ),
        const SizedBox(height: 32),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16, vertical: NileSpacing.s16),
          decoration: BoxDecoration(
            color: NileColors.bgSurface,
            border: Border.all(color: NileColors.border),
            borderRadius: BorderRadius.circular(NileRadius.lg),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'EVENT ID',
                      style: NileTextStyles.caption().copyWith(
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _eventId!,
                      style: NileTextStyles.headingSm().copyWith(
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
                color: NileColors.txtSecondary,
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),
        FilledButton.icon(
          onPressed: () => Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              // The creator of the event is its host.
              builder: (_) =>
                  CameraScreen(initialEventId: _eventId, isHost: true),
            ),
          ),
          icon: const Icon(Icons.videocam),
          label: const Text('Start Camera'),
          style: FilledButton.styleFrom(
            backgroundColor: NileColors.coral,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
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
            padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
          ),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Back to Home',
            style: NileTextStyles.bodyMd().copyWith(
              color: NileColors.txtTertiary,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: NileTextStyles.labelSm());
}

class _CoverPicker extends StatelessWidget {
  final Uint8List? bytes;
  final bool busy;
  final VoidCallback onPick;
  final VoidCallback onClear;

  const _CoverPicker({
    required this.bytes,
    required this.busy,
    required this.onPick,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final hasImage = bytes != null;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: InkWell(
        onTap: busy ? null : onPick,
        borderRadius: BorderRadius.circular(NileRadius.md),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: NileColors.bgSurface,
            borderRadius: BorderRadius.circular(NileRadius.lg),
            border: Border.all(
              color: hasImage ? Colors.transparent : NileColors.border,
              style: hasImage ? BorderStyle.solid : BorderStyle.solid,
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (hasImage)
                Image.memory(bytes!, fit: BoxFit.cover)
              else
                _emptyState(),
              if (busy)
                const ColoredBox(
                  color: Colors.black54,
                  child: Center(
                    child: CircularProgressIndicator(color: NileColors.volt),
                  ),
                ),
              if (hasImage && !busy)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Material(
                    color: Colors.black54,
                    shape: const CircleBorder(),
                    child: IconButton(
                      icon: const Icon(
                        Icons.close,
                        size: 18,
                        color: Colors.white,
                      ),
                      onPressed: onClear,
                      tooltip: 'Remove cover',
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyState() => const Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.add_photo_alternate_outlined,
          size: 36,
          color: NileColors.txtTertiary,
        ),
        SizedBox(height: 8),
        Text(
          'Add cover photo',
          style: TextStyle(color: NileColors.txtSecondary),
        ),
      ],
    ),
  );
}

class _DateField extends StatelessWidget {
  final DateTime? value;
  final VoidCallback onTap;
  final VoidCallback onClear;
  final String Function(DateTime) formatter;

  const _DateField({
    required this.value,
    required this.onTap,
    required this.onClear,
    required this.formatter,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NileRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s12, vertical: NileSpacing.s12),
        decoration: BoxDecoration(
          color: NileColors.bgSurface,
          border: Border.all(color: NileColors.border),
          borderRadius: BorderRadius.circular(NileRadius.sm),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.calendar_today,
              size: 16,
              color: NileColors.txtSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                value == null
                    ? 'Pick a date & time (optional)'
                    : formatter(value!),
                style: value == null
                    ? NileTextStyles.bodyMd().copyWith(
                        color: NileColors.txtTertiary,
                      )
                    : NileTextStyles.bodyMd(),
              ),
            ),
            if (value != null)
              IconButton(
                icon: const Icon(
                  Icons.close,
                  size: 18,
                  color: NileColors.txtTertiary,
                ),
                onPressed: onClear,
                tooltip: 'Clear',
              ),
          ],
        ),
      ),
    );
  }
}
