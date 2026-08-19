import 'package:croppy/croppy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/ad_service.dart';
import '../services/crew_service.dart';
import '../services/event_service.dart';
import '../services/pricing_service.dart';
import '../services/profile_service.dart';
import '../services/topic_service.dart';
import '../theme.dart';
import '../widgets/crew_editor.dart';
import '../widgets/duration_field.dart';
import '../widgets/payout_gate.dart';
import '../widgets/payout_preview_card.dart';
import '../widgets/topic_chips.dart';
import '../services/formats.dart';

/// "$25" / "$2,500" — sponsorship bounds are whole dollars, and "$2500.00" in
/// an error string reads like a bug.
String _wholeDollars(int cents) {
  final s = (cents ~/ 100).toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return '\$$buf';
}

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

  /// Whether the event actually had an end time when this screen opened, and
  /// the duration text we seeded from it — together they tell us whether the
  /// host has expressed an opinion about duration at all. See [_save].
  late final bool _hadEndAt;
  late final String _initialDurationText;

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

  // Pre-Show sponsorship opt-in (0079); seeded from the event row.
  late bool _sponsorshipOpen;
  late bool _sponsorshipAutoAccept; // 0096
  late final TextEditingController _minOfferController;

  /// app_config bounds and the server's price suggestion. Both fetched only
  /// when the toggle is on — most events never open to sponsors.
  SponsorshipBounds? _sponsorshipBounds;
  PriceSuggestion? _suggestion;

  // Server pricing constants; local fallback until the real config loads.
  PricingConfig _pricing = PricingService.current;

  @override
  void initState() {
    super.initState();
    PricingService.load().then((c) {
      if (mounted) setState(() => _pricing = c);
    });
    final e = widget.event;
    // Seed cameras from the event row so the ticket floor is right before the
    // crew fetch resolves; _loadCrew refines it from the saved camera slots.
    _crew.cameraCount = e.cameraCount;
    _nameController = TextEditingController(text: e.title);
    _descriptionController = TextEditingController(text: e.description ?? '');
    _priceController = TextEditingController(
      text: e.price == null ? '' : (e.price! / 100).toStringAsFixed(2),
    );
    _ticketLimitController = TextEditingController(
      text: e.ticketLimit?.toString() ?? '',
    );
    _existingCoverUrl = e.coverImageUrl;
    _sponsorshipOpen = e.sponsorshipOpen;
    _sponsorshipAutoAccept = e.sponsorshipAutoAccept;
    _minOfferController = TextEditingController(
      text: e.sponsorshipMinOfferCents == null
          ? ''
          : (e.sponsorshipMinOfferCents! / 100).toStringAsFixed(2),
    );
    if (_sponsorshipOpen) _loadSponsorshipTerms();
    // toLocal(): the server returns UTC; the picker and previews are all
    // wall-clock local. Save converts back with toUtc().
    _scheduledAt = e.scheduledAt?.toLocal();

    // Seed duration from the saved end_at − scheduled_at (default 60 min).
    // _hadEndAt records whether that 60 was real or a placeholder: an event
    // saved with no end time used to have one silently imposed on it the next
    // time anything else on this screen was edited.
    _hadEndAt = e.endAt != null;
    final mins = _initialDurationMinutes();
    _durationController = TextEditingController(
      text: _trimNum(mins / 60),
    ); // hours by default
    _initialDurationText = _durationController.text;
    _durationController.addListener(() => setState(() {}));
    _priceController.addListener(() => setState(() {}));

    _loadCrew();
    _loadTopics();
  }

  // ── Pricing (mirrors the create flow) ───────────────────────────────────────

  int get _cameraCount => _crew.cameraCount;

  int get _minPriceCents => _pricing.minTicketCentsFor(
    durationMinutes: _parsedDurationMinutes() ?? 60,
    cameraCount: _cameraCount,
  );

  int get _typedPriceCents {
    final raw = _priceController.text.trim();
    if (raw.isEmpty) return 0;
    final n = double.tryParse(raw);
    return n == null || n < 0 ? 0 : (n * 100).round();
  }

  static String _money(int cents) => '\$${(cents / 100).toStringAsFixed(2)}';

  String? _validatePrice(String? v) {
    final cents = (v == null || v.trim().isEmpty)
        ? 0
        : ((double.tryParse(v.trim()) ?? -1) * 100).round();
    if (cents < 0) return 'Invalid';
    if (cents == 0) {
      return _cameraCount > 1 ? 'Needs a price' : null;
    }
    if (cents < _minPriceCents) return 'Min ${_money(_minPriceCents)}';
    return null;
  }

  void _changeCameraCount(int delta) {
    final next = _cameraCount + delta;
    if (next < 1 || next > CrewState.maxCameras) return;
    setState(() => _crew.cameraCount = next);
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

  /// Same instant, regardless of whether either side is UTC or local.
  static bool _sameInstant(DateTime? a, DateTime? b) {
    if (a == null || b == null) return a == b;
    return a.isAtSameMomentAs(b);
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
    _minOfferController.dispose();
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
    return 'Ends ${_fmtDuration(mins)} after start · ${NileFormats.time(end)}';
  }

  String _formatScheduled(DateTime dt) => NileFormats.dayMonthYearTime(dt);

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
    final picked = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    // firstDate constrains the DATE only — picking today and then a time that
    // has already been meant an event the auto-end sweep closed within five
    // minutes. Migration 0100 enforces the same rule server-side.
    if (picked.isBefore(DateTime.now())) {
      setState(() => _dateError = 'Pick a start time in the future.');
      return;
    }
    setState(() {
      _scheduledAt = picked;
      _dateError = null;
    });
  }

  /// Sponsorship opt-in requires an active payout account (the sponsor's 70%
  /// share is a Connect destination charge). Mirrors the create flow.
  Future<void> _toggleSponsorship(bool v) async {
    if (!v) {
      // Auto-accept goes with it. Leaving it armed on a closed event means it
      // silently fires the day the host reopens sponsorship.
      setState(() {
        _sponsorshipOpen = false;
        _sponsorshipAutoAccept = false;
      });
      return;
    }
    final ok = await ensurePaidPublishAllowed(
      context,
      title: 'Set up payouts first',
      message:
          'Sponsorship revenue is paid straight to your connected payout '
          'account. Set it up, then open your event to sponsors.',
    );
    if (!mounted) return;
    setState(() => _sponsorshipOpen = ok);
    if (ok) _loadSponsorshipTerms();
  }

  /// Platform bounds plus the server's suggested minimum for THIS event.
  /// Best-effort on both counts — the field falls back to the platform floor.
  Future<void> _loadSponsorshipTerms() async {
    final (bounds, suggestion) = await (
      AdService.sponsorshipBounds(),
      AdService.suggestSponsorshipPrice(widget.event.id),
    ).wait;
    if (!mounted) return;
    setState(() {
      _sponsorshipBounds = bounds;
      _suggestion = suggestion;
      // Only ever fills a blank field. A saved minimum — or one the host typed
      // while this was in flight — is theirs, not ours to overwrite.
      if (suggestion != null && _minOfferController.text.trim().isEmpty) {
        _minOfferController.text = (suggestion.suggestedCents / 100)
            .toStringAsFixed(2);
      }
    });
  }

  SponsorshipBounds get _bounds =>
      _sponsorshipBounds ?? (minCents: 2500, maxCents: 250000);

  /// The typed minimum in cents, or null for "use the platform floor".
  int? get _typedMinOfferCents {
    final raw = _minOfferController.text.trim();
    if (raw.isEmpty) return null;
    final n = double.tryParse(raw);
    return n == null ? null : (n * 100).round();
  }

  String? _validateMinOffer(String? v) {
    if (!_sponsorshipOpen) return null;
    if (v == null || v.trim().isEmpty) return null; // platform floor
    final n = double.tryParse(v.trim());
    if (n == null) return 'Invalid';
    final cents = (n * 100).round();
    if (cents < _bounds.minCents) {
      return 'At least ${_wholeDollars(_bounds.minCents)}';
    }
    if (cents > _bounds.maxCents) {
      return 'At most ${_wholeDollars(_bounds.maxCents)}';
    }
    return null;
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
      // An event with no end time keeps having none unless the host actually
      // touches the duration field. It used to acquire a silent 60 minutes on
      // the next save of anything at all — which then priced it at the
      // 60-minute floor while the auto-end sweep still assumed eight hours.
      final durationUntouched =
          _durationController.text.trim() == _initialDurationText;
      final newEndAt = (!_hadEndAt && durationUntouched)
          ? null
          : _scheduledAt?.add(Duration(minutes: durationMinutes));

      // isAtSameMomentAs, not ==: _scheduledAt is local and event.scheduledAt is
      // UTC, and Dart's == compares isUtc as well as the instant. Every save
      // therefore wrote both fields whether or not anything had changed.
      final scheduledChanged =
          !_sameInstant(_scheduledAt, widget.event.scheduledAt);
      final endChanged = !_sameInstant(newEndAt, widget.event.endAt);
      final priceChanged = priceCents != widget.event.price;
      final limitChanged = ticketLimit != widget.event.ticketLimit;
      final minOfferCents = _typedMinOfferCents;
      final minOfferChanged =
          minOfferCents != widget.event.sponsorshipMinOfferCents;

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
        sponsorshipOpen: _sponsorshipOpen != widget.event.sponsorshipOpen
            ? _sponsorshipOpen
            : null,
        // Terms are only written while the event is open to sponsors — closing
        // it must not wipe a minimum the host set. Auto-accept is the exception:
        // _toggleSponsorship clears it on the way out, and that clear has to
        // land.
        sponsorshipMinOfferCents:
            _sponsorshipOpen && minOfferChanged ? minOfferCents : null,
        clearSponsorshipMinOffer:
            _sponsorshipOpen && minOfferChanged && minOfferCents == null,
        sponsorshipAutoAccept:
            _sponsorshipAutoAccept != widget.event.sponsorshipAutoAccept
            ? _sponsorshipAutoAccept
            : null,
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
        _error = PricingService.friendlyError(e) ?? 'Failed to save: $e';
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
                    maxMinutes: _pricing.maxStreamMinutes,
                  ),
                  const SizedBox(height: 20),
                  _SectionLabel('Cameras'),
                  const SizedBox(height: 6),
                  CameraStepper(
                    count: _cameraCount,
                    max: CrewState.maxCameras,
                    onAdd: () => _changeCameraCount(1),
                    onRemove: () => _changeCameraCount(-1),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _cameraCount > 1
                        ? 'Multi-camera streams need a ticket — minimum '
                              '${_money(_minPriceCents)} for this event.'
                        : 'Single-camera streams can be free.',
                    style: NileTextStyles.caption().copyWith(
                      color: NileColors.txtTertiary,
                    ),
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
                              decoration: InputDecoration(
                                prefixText: '\$ ',
                                hintText: _cameraCount > 1
                                    ? (_minPriceCents / 100).toStringAsFixed(2)
                                    : 'Free',
                              ),
                              validator: _validatePrice,
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
                  if (_cameraCount > 1 || _typedPriceCents > 0) ...[
                    const SizedBox(height: 16),
                    PayoutPreviewCard(
                      priceCents: _typedPriceCents,
                      minCents: _minPriceCents,
                      cameraCount: _cameraCount,
                      config: _pricing,
                    ),
                  ],
                  const SizedBox(height: 20),
                  _SectionLabel('Sponsorship'),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _sponsorshipOpen,
                    onChanged: _toggleSponsorship,
                    title: Text(
                      'Open to sponsorship',
                      style: NileTextStyles.bodyMd(),
                    ),
                    subtitle: Text(
                      'Let a brand sponsor your pre-show lobby. You keep 70% '
                      'of the sponsorship price; every ad is reviewed by Nile '
                      'before it can appear.',
                      style: NileTextStyles.caption().copyWith(
                        color: NileColors.txtTertiary,
                      ),
                    ),
                    activeTrackColor: NileColors.volt,
                  ),
                  // Only once the toggle is on: two fields about terms are
                  // noise to the majority of hosts who leave sponsorship off.
                  if (_sponsorshipOpen) ...[
                    const SizedBox(height: 12),
                    _SectionLabel('Minimum offer'),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: _minOfferController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'^\d*\.?\d{0,2}'),
                        ),
                      ],
                      decoration: InputDecoration(
                        prefixText: '\$ ',
                        hintText: (_bounds.minCents / 100).toStringAsFixed(2),
                        helperText:
                            'Offers below this are turned down for you. Leave '
                            'blank for the ${_wholeDollars(_bounds.minCents)} '
                            'platform minimum.',
                        helperMaxLines: 3,
                      ),
                      validator: _validateMinOffer,
                    ),
                    if (_suggestion != null) ...[
                      const SizedBox(height: 6),
                      // `basis` verbatim, separated rather than folded into a
                      // sentence: "4 past events" and "estimated from follower
                      // count" don't both survive a shared prefix, and the
                      // difference between them is the whole point.
                      Text(
                        'Suggested '
                        '${_wholeDollars(_suggestion!.suggestedCents)} · '
                        '${_suggestion!.basis}',
                        style: NileTextStyles.caption().copyWith(
                          color: NileColors.txtTertiary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    CheckboxListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _sponsorshipAutoAccept,
                      onChanged: (v) => setState(
                        () => _sponsorshipAutoAccept = v ?? false,
                      ),
                      title: Text(
                        'Automatically accept offers at or above my minimum',
                        style: NileTextStyles.bodyMd(),
                      ),
                      subtitle: Text(
                        'Nile still screens every ad for policy. What you\'re '
                        'giving up is the look — you won\'t see which brand it '
                        'is before it runs in your lobby.',
                        style: NileTextStyles.caption().copyWith(
                          color: NileColors.txtTertiary,
                        ),
                      ),
                      activeColor: NileColors.volt,
                      checkColor: NileColors.onVolt,
                    ),
                  ],
                  const SizedBox(height: 24),
                  Divider(color: NileColors.border),
                  const SizedBox(height: 16),

                  // Crew editor (operators only — cameras live above, next to
                  // the price they drive).
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
                    CrewEditor(
                      state: _crew,
                      showCameras: false,
                      onChanged: () => setState(() {}),
                    ),

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
