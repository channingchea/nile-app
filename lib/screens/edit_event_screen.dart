import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/event_service.dart';
import '../services/profile_service.dart';
import '../theme.dart';

/// Edit an event the signed-in user hosts. Pops with the updated [Event] on
/// success so the caller can refresh its UI without an extra round-trip.
class EditEventScreen extends StatefulWidget {
  final Event event;
  const EditEventScreen({super.key, required this.event});

  @override
  State<EditEventScreen> createState() => _EditEventScreenState();
}

class _EditEventScreenState extends State<EditEventScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _priceController;
  late final TextEditingController _ticketLimitController;

  Uint8List? _coverBytes;          // newly picked, not yet uploaded
  String? _existingCoverUrl;       // current saved cover (may be null)
  bool _coverCleared = false;       // user removed the existing cover
  bool _uploadingCover = false;

  DateTime? _scheduledAt;

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.event;
    _nameController = TextEditingController(text: e.title);
    _descriptionController = TextEditingController(text: e.description ?? '');
    _priceController = TextEditingController(
      text: e.price == null ? '' : (e.price! / 100).toStringAsFixed(2),
    );
    _ticketLimitController =
        TextEditingController(text: e.ticketLimit?.toString() ?? '');
    _existingCoverUrl = e.coverImageUrl;
    _scheduledAt = e.scheduledAt;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _priceController.dispose();
    _ticketLimitController.dispose();
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _formatScheduled(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final t =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year} · $t';
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _pickCover() async {
    setState(() => _uploadingCover = true);
    try {
      final bytes =
          await ProfileService.pickImageBytes(context, maxWidth: 1600, maxHeight: 900);
      if (bytes != null && mounted) {
        setState(() {
          _coverBytes = bytes;
          _coverCleared = false;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _uploadingCover = false);
    }
  }

  void _clearCover() {
    setState(() {
      _coverBytes = null;
      _existingCoverUrl = null;
      _coverCleared = true;
    });
  }

  Future<void> _pickDateTime() async {
    final now = DateTime.now();
    final seed = _scheduledAt ?? now.add(const Duration(hours: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: seed.isBefore(now) ? now : seed,
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
      initialTime: TimeOfDay.fromDateTime(seed),
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
      _scheduledAt =
          DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      // Upload new cover if one was picked. Non-fatal — falls back to keeping
      // the existing cover if upload fails.
      String? newCoverUrl;
      if (_coverBytes != null) {
        try {
          newCoverUrl = await EventService.uploadCoverBytes(
            liveKitEventId: widget.event.liveKitEventId,
            bytes: _coverBytes!,
          );
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Cover upload failed: $e')),
            );
          }
        }
      }

      final name = _nameController.text.trim();
      final desc = _descriptionController.text.trim();
      final priceText = _priceController.text.trim();
      final limitText = _ticketLimitController.text.trim();
      final priceCents = priceText.isEmpty
          ? null
          : (double.parse(priceText) * 100).round();
      final ticketLimit = limitText.isEmpty ? null : int.parse(limitText);

      final scheduledChanged = _scheduledAt != widget.event.scheduledAt;
      final priceChanged = priceCents != widget.event.price;
      final limitChanged = ticketLimit != widget.event.ticketLimit;

      final updated = await EventService.update(
        eventId: widget.event.id,
        title: name != widget.event.title ? name : null,
        description: desc != (widget.event.description ?? '')
            ? (desc.isEmpty ? '' : desc)
            : null,
        coverImageUrl: newCoverUrl,
        clearCoverImageUrl: _coverCleared && _coverBytes == null,
        scheduledAt:
            scheduledChanged && _scheduledAt != null ? _scheduledAt : null,
        clearScheduledAt: scheduledChanged && _scheduledAt == null,
        price: priceChanged && priceCents != null ? priceCents : null,
        clearPrice: priceChanged && priceCents == null,
        ticketLimit:
            limitChanged && ticketLimit != null ? ticketLimit : null,
        clearTicketLimit: limitChanged && ticketLimit == null,
      );

      if (!mounted) return;
      Navigator.pop(context, updated);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Failed to save: $e';
      });
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        title: Text('Edit Event', style: NileTextStyles.headingMd()),
        backgroundColor: Colors.transparent,
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(
              'Save',
              style: NileTextStyles.labelMd().copyWith(
                color: _saving ? NileColors.txtTertiary : NileColors.volt,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      body: NileMaxWidth(child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
        child: AbsorbPointer(
          absorbing: _saving,
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _CoverEditor(
                  newBytes: _coverBytes,
                  existingUrl: _existingCoverUrl,
                  busy: _uploadingCover,
                  onPick: _pickCover,
                  onClear: _clearCover,
                ),
                const SizedBox(height: 24),
                _SectionLabel('Event Name'),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 80,
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
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                    decimal: true),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                  RegExp(r'^\d*\.?\d{0,2}')),
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
                            decoration:
                                const InputDecoration(hintText: 'Unlimited'),
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
                if (_error != null) ...[
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: NileColors.error.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(NileRadius.sm),
                      border:
                          Border.all(color: NileColors.error.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      _error!,
                      style: NileTextStyles.bodySm()
                          .copyWith(color: NileColors.error),
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: NileColors.bgPage,
                          ),
                        )
                      : const Icon(Icons.check),
                  label: Text(_saving ? 'Saving…' : 'Save Changes'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    textStyle: NileTextStyles.labelLg(),
                  ),
                ),
              ],
            ),
          ),
        ),
      )),
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

class _CoverEditor extends StatelessWidget {
  final Uint8List? newBytes;
  final String? existingUrl;
  final bool busy;
  final VoidCallback onPick;
  final VoidCallback onClear;

  const _CoverEditor({
    required this.newBytes,
    required this.existingUrl,
    required this.busy,
    required this.onPick,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final hasImage = newBytes != null || existingUrl != null;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: InkWell(
        onTap: busy ? null : onPick,
        borderRadius: BorderRadius.circular(NileRadius.md),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: NileColors.bgSurface,
            borderRadius: BorderRadius.circular(NileRadius.md),
            border: Border.all(color: NileColors.border),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (newBytes != null)
                Image.memory(newBytes!, fit: BoxFit.cover)
              else if (existingUrl != null)
                Image.network(
                  existingUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _empty(),
                )
              else
                _empty(),
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
                      icon: const Icon(Icons.close,
                          size: 18, color: Colors.white),
                      onPressed: onClear,
                      tooltip: 'Remove cover',
                    ),
                  ),
                ),
              if (hasImage && !busy)
                Positioned(
                  bottom: 8,
                  right: 8,
                  child: Material(
                    color: Colors.black54,
                    shape: const StadiumBorder(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.edit,
                              size: 14, color: Colors.white),
                          const SizedBox(width: 4),
                          Text('Replace',
                              style: NileTextStyles.caption()
                                  .copyWith(color: Colors.white)),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _empty() => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_photo_alternate_outlined,
                size: 36, color: NileColors.txtTertiary),
            SizedBox(height: 8),
            Text('Add cover photo',
                style: TextStyle(color: NileColors.txtSecondary)),
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: NileColors.bgSurface,
          border: Border.all(color: NileColors.border),
          borderRadius: BorderRadius.circular(NileRadius.sm),
        ),
        child: Row(
          children: [
            const Icon(Icons.calendar_today,
                size: 16, color: NileColors.txtSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                value == null
                    ? 'Pick a date & time (optional)'
                    : formatter(value!),
                style: value == null
                    ? NileTextStyles.bodyMd()
                        .copyWith(color: NileColors.txtTertiary)
                    : NileTextStyles.bodyMd(),
              ),
            ),
            if (value != null)
              IconButton(
                icon: const Icon(Icons.close,
                    size: 18, color: NileColors.txtTertiary),
                onPressed: onClear,
                tooltip: 'Clear',
              ),
          ],
        ),
      ),
    );
  }
}
