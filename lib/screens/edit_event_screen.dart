import 'package:croppy/croppy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/crew_service.dart';
import '../services/event_service.dart';
import '../services/profile_service.dart';
import '../services/topic_service.dart';
import '../theme.dart';
import '../widgets/crew_editor.dart';
import '../widgets/duration_field.dart';
import '../widgets/payout_gate.dart';
import '../widgets/topic_chips.dart';

/// Edit an event the signed-in user hosts. Mirrors the create flow's fields
/// (details + duration + crew) on a single screen. Pops with the updated
/// [Event] on success so the caller can refresh without an extra round-trip.
class EditEventScreen extends StatefulWidget {
  final Event event;
  const EditEventScreen({super.key, required this.event});

  @override
  State<EditEventScreen> createState() => _EditEventScreenState();
}

class _EditEventScreenState extends State<EditEventScreen> {
  bool get _isDraft => widget.event.isDraft;

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _priceController;
  late final TextEditingController _ticketLimitController;
  late final TextEditingController _durationController;

  Uint8List? _coverBytes; // newly picked, not yet uploaded
  String? _existingCoverUrl; // current saved cover (may be null)
  bool _coverCleared = false; // user removed the existing cover
  bool _uploadingCover = false;

  DateTime? _scheduledAt;
  String? _dateError; // "Scheduled For" is required
  bool _durationInHours = true;

  // Crew working state + the originally-saved durations for change detection.
  final CrewState _crew = CrewState();
  bool _crewLoading = true;
  String? _crewError;

  // Topic tags: working set + originally-saved set for change detection.
  final Set<String> _topicIds = {};
  Set<String> _savedTopicIds = {};

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
    _ticketLimitController = TextEditingController(
      text: e.ticketLimit?.toString() ?? '',
    );
    _existingCoverUrl = e.coverImageUrl;
    // toLocal(): the server returns UTC; the picker and previews are all
    // wall-clock local. Save converts back with toUtc().
    _scheduledAt = e.scheduledAt?.toLocal();

    // Seed duration from the saved end_at − scheduled_at (default 60 min).
    final mins = _initialDurationMinutes();
    _durationController = TextEditingController(
      text: _trimNum(mins / 60),
    ); // hours by default
    _durationController.addListener(() => setState(() {}));

    _loadCrew();
    _loadTopics();
  }

  Future<void> _loadTopics() async {
    try {
      final ids = await TopicService.topicIdsForEvent(widget.event.id);
      if (!mounted) return;
      setState(() {
        _savedTopicIds = ids.toSet();
        _topicIds.addAll(ids);
      });
    } catch (_) {
      /* chips just start empty — non-fatal */
    }
  }

  int _initialDurationMinutes() {
    final s = widget.event.scheduledAt;
    final end = widget.event.endAt;
    if (s != null && end != null) {
      final m = end.difference(s).inMinutes;
      if (m > 0) return m;
    }
    return 60;
  }

  Future<void> _loadCrew() async {
    try {
      final cams = await CrewService.fetchCameras(widget.event.id);
      final ops = await CrewService.fetchOperators(widget.event.id);
      if (!mounted) return;
      setState(() {
        if (cams.isNotEmpty) _crew.cameraCount = cams.length;
        // Every assigned person is just a crew member here; camera/device role
        // assignment lives on the Sound Check page now.
        for (final op in ops) {
          _crew.operators[op.profile.id] = OperatorPick(op.profile);
        }
        _crewLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _crewLoading = false;
          _crewError = 'Couldn\'t load crew: $e';
        });
      }
    }
  }

  static String _trimNum(num n) {
    final s = n.toString();
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  static bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _priceController.dispose();
    _ticketLimitController.dispose();
    _durationController.dispose();
    super.dispose();
  }

  // ── Duration helpers (mirror the create flow) ────────────────────────────────

  int? _parsedDurationMinutes() {
    final raw = _durationController.text.trim();
    if (raw.isEmpty) return null;
    final n = double.tryParse(raw);
    if (n == null || n <= 0) return null;
    return _durationInHours ? (n * 60).round() : n.round();
  }

  void _changeUnit(bool toHours) {
    if (toHours == _durationInHours) return;
    final mins = _parsedDurationMinutes();
    setState(() {
      _durationInHours = toHours;
      if (mins != null) {
        _durationController.text = toHours
            ? _trimNum(double.parse((mins / 60).toStringAsFixed(2)))
            : mins.toString();
      }
    });
  }

  static String _fmtDuration(int mins) {
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h > 0 && m > 0) return '${h}h ${m}m';
    if (h > 0) return '${h}h';
    return '${m}m';
  }

  String? _durationPreview() {
    final mins = _parsedDurationMinutes();
    if (mins == null) return null;
    if (_scheduledAt == null) return 'Runs ${_fmtDuration(mins)}';
    final end = _scheduledAt!.add(Duration(minutes: mins));
    final t =
        '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
    return 'Ends ${_fmtDuration(mins)} after start · $t';
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

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _pickCover() async {
    setState(() => _uploadingCover = true);
    try {
      final bytes = await ProfileService.pickImageBytes(
        context,
        maxWidth: 1600,
        maxHeight: 900,
        allowedAspectRatios: [const CropAspectRatio(width: 16, height: 9)],
      );
      if (bytes != null && mounted) {
        setState(() {
          _coverBytes = bytes;
          _coverCleared = false;
        });
      }
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
          colorScheme: Theme.of(ctx).colorScheme,
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
          colorScheme: Theme.of(ctx).colorScheme,
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
      _dateError = null;
    });
  }

  Future<void> _save() async {
    final formOk = _formKey.currentState!.validate();
    final dateOk = _scheduledAt != null;
    setState(() => _dateError = dateOk ? null : 'Required');
    if (!formOk || !dateOk) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      // Upload new cover if one was picked (non-fatal).
      String? newCoverUrl;
      if (_coverBytes != null) {
        try {
          newCoverUrl = await EventService.uploadCoverBytes(
            liveKitEventId: widget.event.liveKitEventId ?? widget.event.id,
            bytes: _coverBytes!,
          );
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Cover upload failed: $e')));
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
      final durationMinutes = _parsedDurationMinutes() ?? 60;
      final newEndAt = _scheduledAt?.add(Duration(minutes: durationMinutes));

      final scheduledChanged = _scheduledAt != widget.event.scheduledAt;
      final endChanged = newEndAt != widget.event.endAt;
      final priceChanged = priceCents != widget.event.price;
      final limitChanged = ticketLimit != widget.event.ticketLimit;

      // Publishing a paid draft or flipping a free event to paid requires an
      // active payout account. Gate before writing so we never leave an event
      // paid-and-public without payouts (the server trigger backs this up).
      if ((priceCents ?? 0) > 0 &&
          (widget.event.isDraft || (widget.event.price ?? 0) == 0)) {
        if (!mounted) return;
        if (!await ensurePaidPublishAllowed(context)) {
          setState(() => _saving = false);
          return;
        }
      }

      final updated = await EventService.update(
        eventId: widget.event.id,
        title: name != widget.event.title ? name : null,
        description: desc != (widget.event.description ?? '')
            ? (desc.isEmpty ? '' : desc)
            : null,
        coverImageUrl: newCoverUrl,
        clearCoverImageUrl: _coverCleared && _coverBytes == null,
        scheduledAt: scheduledChanged && _scheduledAt != null
            ? _scheduledAt
            : null,
        clearScheduledAt: scheduledChanged && _scheduledAt == null,
        endAt: endChanged && newEndAt != null ? newEndAt : null,
        clearEndAt: endChanged && newEndAt == null,
        price: priceChanged && priceCents != null ? priceCents : null,
        clearPrice: priceChanged && priceCents == null,
        ticketLimit: limitChanged && ticketLimit != null ? ticketLimit : null,
        clearTicketLimit: limitChanged && ticketLimit == null,
        cameraCount: _crew.cameraCount != widget.event.cameraCount
            ? _crew.cameraCount
            : null,
        topicIds: _setEquals(_topicIds, _savedTopicIds)
            ? null
            : _topicIds.toList(),
      );

      // Persist crew: adjust camera count, add/remove crew members.
      await _saveCrew();

      // Editing a draft and saving publishes it (status → scheduled).
      var result = updated;
      if (widget.event.isDraft) {
        result = await EventService.publishDraft(widget.event.id);
      }

      if (!mounted) return;
      Navigator.pop(context, result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Failed to save: $e';
      });
    }
  }

  /// Reconcile crew against the picker state: adjust the camera slot count,
  /// add newly-picked crew (no slot/device — that's set during Sound Check),
  /// and remove anyone dropped. Existing crew members and any camera/device
  /// roles already assigned in Sound Check are left untouched.
  Future<void> _saveCrew() async {
    final eventId = widget.event.id;

    final previous = await CrewService.fetchOperators(eventId);
    final previousIds = previous.map((o) => o.profile.id).toSet();
    final currentIds = _crew.operators.keys.toSet();

    // Grow/shrink camera slots to match the chosen count without wiping the
    // slots (and their Sound Check assignments) that remain.
    await CrewService.setCameraCount(
      eventId: eventId,
      count: _crew.cameraCount,
    );

    // Add crew members that are new in this edit (idempotent RPC, no slot).
    for (final id in currentIds.difference(previousIds)) {
      await CrewService.assignOperator(eventId: eventId, operatorId: id);
    }

    // Remove crew members that were dropped from the picker.
    for (final id in previousIds.difference(currentIds)) {
      await CrewService.removeOperator(eventId: eventId, operatorId: id);
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        title: Text(
          _isDraft ? 'Edit Draft' : 'Edit Event',
          style: NileTextStyles.headingMd(),
        ),
        backgroundColor: Colors.transparent,
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(
              _isDraft ? 'Publish' : 'Save',
              style: NileTextStyles.labelMd().copyWith(
                color: _saving ? NileColors.txtTertiary : NileColors.volt,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      body: NileMaxWidth(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(NileSpacing.s24, NileSpacing.s8, NileSpacing.s24, NileSpacing.s40),
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
                  _SectionLabel('Topics'),
                  const SizedBox(height: 10),
                  TopicChips(selected: _topicIds),
                  const SizedBox(height: 20),
                  _SectionLabel('Scheduled For'),
                  const SizedBox(height: 6),
                  _DateField(
                    value: _scheduledAt,
                    onTap: _pickDateTime,
                    onClear: () => setState(() => _scheduledAt = null),
                    formatter: _formatScheduled,
                    errorText: _dateError,
                  ),
                  const SizedBox(height: 20),
                  _SectionLabel('Duration'),
                  const SizedBox(height: 6),
                  DurationField(
                    controller: _durationController,
                    inHours: _durationInHours,
                    onUnitChanged: _changeUnit,
                    preview: _durationPreview(),
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
                  const SizedBox(height: 24),
                  Divider(color: NileColors.border),
                  const SizedBox(height: 16),

                  // Crew editor (cameras + operators) — same as the create flow.
                  if (_crewLoading)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: NileSpacing.s24),
                      child: Center(
                        child: CircularProgressIndicator(
                          color: NileColors.volt,
                        ),
                      ),
                    )
                  else
                    CrewEditor(state: _crew, onChanged: () => setState(() {})),

                  if (_crewError != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _crewError!,
                      style: NileTextStyles.bodySm().copyWith(
                        color: NileColors.error,
                      ),
                    ),
                  ],

                  if (_error != null) ...[
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
                        _error!,
                        style: NileTextStyles.bodySm().copyWith(
                          color: NileColors.error,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: NileColors.onVolt,
                            ),
                          )
                        : const Icon(Icons.check),
                    label: Text(
                      _saving
                          ? (_isDraft ? 'Publishing…' : 'Saving…')
                          : (_isDraft ? 'Publish Event' : 'Save Changes'),
                    ),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                      textStyle: NileTextStyles.labelLg(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
            borderRadius: BorderRadius.circular(NileRadius.lg),
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
                  cacheWidth: nileDecodeWidth(600),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _empty(),
                )
              else
                _empty(),
              if (busy)
                ColoredBox(
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
              if (hasImage && !busy)
                Positioned(
                  bottom: 8,
                  right: 8,
                  child: Material(
                    color: Colors.black54,
                    shape: const StadiumBorder(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: NileSpacing.s12,
                        vertical: NileSpacing.s6,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.edit, size: 14, color: Colors.white),
                          const SizedBox(width: 4),
                          Text(
                            'Replace',
                            style: NileTextStyles.caption().copyWith(
                              color: Colors.white,
                            ),
                          ),
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

  Widget _empty() => Center(
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
  final String? errorText;

  const _DateField({
    required this.value,
    required this.onTap,
    required this.onClear,
    required this.formatter,
    this.errorText,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(NileRadius.sm),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s12, vertical: NileSpacing.s12),
            decoration: BoxDecoration(
              color: NileColors.bgSurface,
              border: Border.all(
                color: errorText != null ? NileColors.error : NileColors.border,
              ),
              borderRadius: BorderRadius.circular(NileRadius.sm),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.calendar_today,
                  size: 16,
                  color: NileColors.txtSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    value == null ? 'Pick a date & time' : formatter(value!),
                    style: value == null
                        ? NileTextStyles.bodyMd().copyWith(
                            color: NileColors.txtTertiary,
                          )
                        : NileTextStyles.bodyMd(),
                  ),
                ),
                if (value != null)
                  IconButton(
                    icon: Icon(
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
        ),
        if (errorText != null)
          Padding(
            padding: const EdgeInsets.only(left: NileSpacing.s12, top: NileSpacing.s8),
            child: Text(
              errorText!,
              style: NileTextStyles.caption().copyWith(color: NileColors.error),
            ),
          ),
      ],
    );
  }
}
