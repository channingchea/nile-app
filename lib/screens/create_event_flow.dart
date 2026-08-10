import 'package:croppy/croppy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../services/crew_service.dart';
import '../services/share_urls.dart';
import '../services/event_service.dart';
import '../services/livekit_service.dart';
import '../services/pricing_service.dart';
import '../services/profile_service.dart';
import '../router.dart';
import '../theme.dart';
import '../widgets/crew_editor.dart';
import '../widgets/duration_field.dart';
import '../widgets/nile_desktop.dart';
import '../widgets/payout_gate.dart';
import '../widgets/payout_preview_card.dart';
import '../widgets/topic_chips.dart';

/// Mutable draft carried across the create-event flow pages. Page 1 fills the
/// event fields and creates the row; later pages attach crew + show the summary.
class EventDraft {
  // Page 1 inputs
  Uint8List? coverBytes;
  String name = '';
  String description = '';
  DateTime? scheduledAt;
  int durationMinutes = 60; // default 1h
  int? priceCents;
  int? ticketLimit;

  /// Host opt-in: let a brand sponsor this event's Pre-Show lobby (0079).
  bool sponsorshipOpen = false;

  /// Topic tags — what `recommend_events_by_topic` matches interests against.
  final Set<String> topicIds = {};

  // Set once the event row is created (end of Page 1).
  Event? event;

  // Page 2 (crew) state — cameras + chosen operators, shared with [CrewEditor].
  final CrewState crew = CrewState();

  /// Persisted camera rows after Page 2 commits (for slot ids + summary).
  List<EventCamera> savedCameras = [];

  /// Computed end time, or null if there's no start.
  DateTime? get endAt => scheduledAt?.add(Duration(minutes: durationMinutes));
}

/// Full-screen create-event flow. A self-contained [Navigator] stack so users
/// can go back to edit earlier pages; the top-left X (or [_cancel]) pops the
/// whole flow back to the screen that launched it.
class CreateEventFlow extends StatefulWidget {
  const CreateEventFlow({super.key});

  @override
  State<CreateEventFlow> createState() => _CreateEventFlowState();
}

class _CreateEventFlowState extends State<CreateEventFlow> {
  final _draft = EventDraft();
  final _navKey = GlobalKey<NavigatorState>();

  /// Pop the entire flow back to the launching screen.
  void _cancel() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    // Intercept the system/back gesture: pop the inner nav if it can, else
    // exit the whole flow.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final nav = _navKey.currentState!;
        if (nav.canPop()) {
          nav.pop();
        } else {
          _cancel();
        }
      },
      child: Navigator(
        key: _navKey,
        onGenerateRoute: (_) => MaterialPageRoute(
          builder: (_) => EventDetailsPage(draft: _draft, onCancel: _cancel),
        ),
      ),
    );
  }
}

// ── Page 1: Event Details ─────────────────────────────────────────────────────

/// Desktop split geometry. The panel is wide enough for a legible 16:9 card,
/// and the pair is capped so a maximised window doesn't stretch the form into
/// 1600 pt input fields — a form reads as a document, centred, not as a band.
const double _kPreviewWidth = 360;
const double _kSplitMaxWidth = 1100;

class EventDetailsPage extends StatefulWidget {
  final EventDraft draft;
  final VoidCallback onCancel;

  const EventDetailsPage({
    super.key,
    required this.draft,
    required this.onCancel,
  });

  @override
  State<EventDetailsPage> createState() => _EventDetailsPageState();
}

class _EventDetailsPageState extends State<EventDetailsPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _priceController;
  late final TextEditingController _ticketLimitController;
  late final TextEditingController _durationController;

  bool _uploadingCover = false;
  bool _submitting = false;
  String? _errorMessage;
  String?
  _dateError; // "Scheduled For" is required; not a FormField so tracked here.

  // Duration unit toggle: false = minutes, true = hours.
  bool _durationInHours = true;

  // Server pricing constants; starts on the local fallback and swaps in the
  // real config as soon as it loads.
  PricingConfig _pricing = PricingService.current;

  /// Signed-in host, for the preview card's byline. Null until it loads — and
  /// always, on a phone, where there is no preview to put it in.
  UserProfile? _host;
  bool _previewWired = false;

  EventDraft get _draft => widget.draft;

  @override
  void initState() {
    super.initState();
    PricingService.load().then((c) {
      if (mounted) setState(() => _pricing = c);
    });
    _nameController = TextEditingController(text: _draft.name);
    _descriptionController = TextEditingController(text: _draft.description);
    _priceController = TextEditingController(
      text: _draft.priceCents == null
          ? ''
          : (_draft.priceCents! / 100).toStringAsFixed(2),
    );
    _ticketLimitController = TextEditingController(
      text: _draft.ticketLimit?.toString() ?? '',
    );
    // Seed duration field from the draft in the currently-selected unit (hours).
    _durationController = TextEditingController(
      text: _trimNum(_draft.durationMinutes / 60),
    );
    // Live preview: rebuild on every keystroke so the "ends at" caption and the
    // payout card track what's typed.
    _durationController.addListener(() => setState(() {}));
    _priceController.addListener(() => setState(() {}));
  }

  /// Wiring the desktop preview needs and the phone doesn't: the title has to
  /// echo per keystroke, and the byline needs a host. Done here rather than in
  /// [initState] because the window class isn't known until the first
  /// dependency pass, and re-checked after that so a window dragged wide picks
  /// the preview up. A phone never gets here, so it neither rebuilds on every
  /// character nor pays for the profile fetch.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_previewWired || !NileBreakpoints.of(context).hasNavRail) return;
    _previewWired = true;
    _nameController.addListener(() => setState(() {}));
    ProfileService.fetchCurrentProfile().then((p) {
      if (mounted) setState(() => _host = p);
    });
  }

  // ── Pricing ─────────────────────────────────────────────────────────────────

  int get _cameraCount => _draft.crew.cameraCount;

  /// Break-even ticket floor for the currently-entered duration + cameras.
  int get _minPriceCents => _pricing.minTicketCentsFor(
    durationMinutes: _parsedDurationMinutes() ?? 60,
    cameraCount: _cameraCount,
  );

  /// Price typed right now, in cents (0 when blank).
  int get _typedPriceCents {
    final raw = _priceController.text.trim();
    if (raw.isEmpty) return 0;
    final n = double.tryParse(raw);
    return n == null || n < 0 ? 0 : (n * 100).round();
  }

  static String _money(int cents) => '\$${(cents / 100).toStringAsFixed(2)}';

  /// The payout card is a pricing coach, not a receipt — it only has something
  /// to say once the event is priced or multi-camera. Same rule on both
  /// layouts; only where the card sits changes.
  bool get _showPayout => _cameraCount > 1 || _typedPriceCents > 0;

  /// Every number in here comes from [PricingConfig] — the floor from
  /// `minTicketCentsFor`, the host's cut from `creatorEarningsCents`. Nothing
  /// on this screen does pricing arithmetic of its own.
  Widget _payoutCard() => PayoutPreviewCard(
    priceCents: _typedPriceCents,
    minCents: _minPriceCents,
    cameraCount: _cameraCount,
    config: _pricing,
  );

  /// Free is single-camera only; anything priced must clear the floor.
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
    setState(() => _draft.crew.cameraCount = next);
  }

  /// Formats a number without a trailing ".0" (e.g. 2.0 → "2", 2.5 → "2.5").
  static String _trimNum(num n) {
    final s = n.toString();
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _priceController.dispose();
    _ticketLimitController.dispose();
    _durationController.dispose();
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

  /// Parse the duration field into minutes given the current unit. Returns null
  /// if blank/invalid (validation guards the submit path separately).
  int? _parsedDurationMinutes() {
    final raw = _durationController.text.trim();
    if (raw.isEmpty) return null;
    final n = double.tryParse(raw);
    if (n == null || n <= 0) return null;
    return _durationInHours ? (n * 60).round() : n.round();
  }

  /// Switch the duration unit and convert the field's current value so the real
  /// duration is preserved (2.5 hr ⇄ 150 min). No-op if the field is empty.
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

  /// "2h 30m" style label for a minutes total.
  static String _fmtDuration(int mins) {
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h > 0 && m > 0) return '${h}h ${m}m';
    if (h > 0) return '${h}h';
    return '${m}m';
  }

  /// Live preview line under the field, or null when there's nothing to show.
  String? _durationPreview() {
    final mins = _parsedDurationMinutes();
    if (mins == null) return null;
    final start = _draft.scheduledAt;
    if (start == null) return 'Runs ${_fmtDuration(mins)}';
    final end = start.add(Duration(minutes: mins));
    final t =
        '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
    return 'Ends ${_fmtDuration(mins)} after start · $t';
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
      if (bytes != null && mounted) setState(() => _draft.coverBytes = bytes);
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
      initialDate: _draft.scheduledAt ?? now.add(const Duration(hours: 1)),
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
      initialTime: TimeOfDay.fromDateTime(
        _draft.scheduledAt ?? now.add(const Duration(hours: 1)),
      ),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: Theme.of(ctx).colorScheme,
        ),
        child: child!,
      ),
    );
    if (time == null) return;
    setState(() {
      _draft.scheduledAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      _dateError = null;
    });
  }

  /// Sponsorship opt-in requires an active payout account — the sponsor's 70%
  /// share is a Connect destination charge, so there's nothing to sell without
  /// one. Reuses the payout gate sheet with sponsorship copy.
  Future<void> _toggleSponsorship(bool v) async {
    if (!v) {
      setState(() => _draft.sponsorshipOpen = false);
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
    setState(() => _draft.sponsorshipOpen = ok);
  }

  /// Validate, persist the draft fields, create the LiveKit room + event row,
  /// then advance to the next page (crew). Crew page is built in a later step;
  /// for now Page 1 routes to a temporary "created" page so the flow runs
  /// end-to-end.
  Future<void> _next() async {
    final formOk = _formKey.currentState!.validate();
    // "Scheduled For" is required but isn't a FormField, so check it here.
    final dateOk = _draft.scheduledAt != null;
    setState(() => _dateError = dateOk ? null : 'Required');
    if (!formOk || !dateOk) return;

    // Commit form values into the draft.
    _draft.name = _nameController.text.trim();
    _draft.description = _descriptionController.text.trim();
    _draft.priceCents = _priceController.text.trim().isEmpty
        ? null
        : (double.parse(_priceController.text.trim()) * 100).round();
    _draft.ticketLimit = _ticketLimitController.text.trim().isEmpty
        ? null
        : int.parse(_ticketLimitController.text.trim());
    _draft.durationMinutes = _parsedDurationMinutes() ?? 60;

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    final eventId = _generateEventId(_draft.name);

    try {
      // 1) LiveKit room.
      await LivekitService.createRoom(eventId: eventId, eventName: _draft.name);

      // 2) Cover upload (non-fatal).
      String? coverUrl;
      if (_draft.coverBytes != null) {
        try {
          coverUrl = await EventService.uploadCoverBytes(
            liveKitEventId: eventId,
            bytes: _draft.coverBytes!,
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

      // 3) Persist the event row as a draft; it stays hidden from feeds until
      // the host hits Continue on the crew page (which publishes it). Saving as
      // a draft instead simply leaves it in this state.
      final event = await EventService.create(
        title: _draft.name,
        liveKitEventId: eventId,
        description: _draft.description.isEmpty ? null : _draft.description,
        coverImageUrl: coverUrl,
        scheduledAt: _draft.scheduledAt,
        endAt: _draft.endAt,
        price: _draft.priceCents,
        ticketLimit: _draft.ticketLimit,
        cameraCount: _draft.crew.cameraCount,
        asDraft: true,
        topicIds: _draft.topicIds.toList(),
        sponsorshipOpen: _draft.sponsorshipOpen,
      );
      _draft.event = event;

      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              ChooseCrewPage(draft: _draft, onCancel: widget.onCancel),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _errorMessage =
            PricingService.friendlyError(e) ?? 'Failed to create event: $e',
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // ── UI ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Desktop sets the form beside a live preview of the card it produces;
    // the phone keeps the single scrolling column it shipped with.
    final split = NileBreakpoints.of(context).hasNavRail;

    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: widget.onCancel,
        ),
        title: Text('Create Event', style: NileTextStyles.headingMd()),
      ),
      body: NileMaxWidth(
        // The split caps and centres its own pair, so the 900 pt column
        // ceiling would squeeze it back to one column before it ever got to
        // measure itself.
        maxWidth: split ? double.infinity : null,
        child: AbsorbPointer(
          absorbing: _submitting,
          child: Form(
            key: _formKey,
            child: split
                ? NileDesktopSplit(
                    sideWidth: _kPreviewWidth,
                    maxTotalWidth: _kSplitMaxWidth,
                    // The split centres its pair on both axes. On a display
                    // tall enough to hold the whole form, a column that only
                    // claimed its content height would float off the app bar,
                    // so it claims the window instead and scrolls inside it.
                    content: SizedBox(
                      height: double.infinity,
                      child: _formColumn(inlinePayout: false),
                    ),
                    side: _previewPanel(),
                    // Between the rail breakpoint and the split's own minimum
                    // there is room for one column only.
                    narrow: NileMaxWidth(
                      child: _formColumn(inlinePayout: true),
                    ),
                  )
                : _formColumn(inlinePayout: true),
          ),
        ),
      ),
    );
  }

  /// The sticky desktop panel: the card this draft will become, and — once
  /// there's a price to talk about — the same payout estimate the phone shows
  /// inline. Scrolls itself, so a short window can still reach the bottom.
  Widget _previewPanel() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(0, NileSpacing.s8, NileSpacing.s24, NileSpacing.s40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const NileSectionHeader('Preview', dense: true),
          _EventPreviewCard(
            coverBytes: _draft.coverBytes,
            title: _nameController.text.trim(),
            host: _host,
            scheduledAt: _draft.scheduledAt,
            durationMinutes: _parsedDurationMinutes(),
            priceCents: _typedPriceCents,
            cameraCount: _cameraCount,
          ),
          if (_showPayout) ...[
            const SizedBox(height: NileSpacing.s24),
            const NileSectionHeader('Payout', dense: true),
            _payoutCard(),
          ],
        ],
      ),
    );
  }

  /// The form itself. [inlinePayout] keeps the payout card in the flow of the
  /// column — where it belongs on a phone; the desktop split hands it to the
  /// sticky panel instead, so the estimate stays put while the host scrolls.
  Widget _formColumn({required bool inlinePayout}) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(NileSpacing.s24, NileSpacing.s8, NileSpacing.s24, NileSpacing.s40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CoverPicker(
            bytes: _draft.coverBytes,
            busy: _uploadingCover,
            onPick: _pickCover,
            onClear: () => setState(() => _draft.coverBytes = null),
          ),
          const SizedBox(height: 24),
          _SectionLabel('Event Name'),
          const SizedBox(height: 6),
          TextFormField(
            controller: _nameController,
            textCapitalization: TextCapitalization.words,
            maxLength: 80,
            decoration: const InputDecoration(
              hintText: 'e.g. Friday Night Live',
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
          _SectionLabel('Topics'),
          const SizedBox(height: 6),
          Text(
            'Tag your event so it reaches people into these topics.',
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtTertiary,
            ),
          ),
          const SizedBox(height: 10),
          TopicChips(selected: _draft.topicIds),
          const SizedBox(height: 20),
          _SectionLabel('Scheduled For'),
          const SizedBox(height: 6),
          _DateField(
            value: _draft.scheduledAt,
            onTap: _pickDateTime,
            onClear: () => setState(() => _draft.scheduledAt = null),
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
          if (inlinePayout && _showPayout) ...[
            const SizedBox(height: 16),
            _payoutCard(),
          ],
          const SizedBox(height: 20),
          _SectionLabel('Sponsorship'),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _draft.sponsorshipOpen,
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
            onPressed: _submitting ? null : _next,
            icon: _submitting
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: NileColors.onVolt,
                    ),
                  )
                : const Icon(Icons.arrow_forward),
            label: Text(_submitting ? 'Creating…' : 'Next'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
              textStyle: NileTextStyles.labelLg().copyWith(color: null),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Page 2: Choose Your Crew ──────────────────────────────────────────────────

class ChooseCrewPage extends StatefulWidget {
  final EventDraft draft;
  final VoidCallback onCancel;

  const ChooseCrewPage({
    super.key,
    required this.draft,
    required this.onCancel,
  });

  @override
  State<ChooseCrewPage> createState() => _ChooseCrewPageState();
}

class _ChooseCrewPageState extends State<ChooseCrewPage> {
  bool _committing = false;
  String? _error;

  EventDraft get _draft => widget.draft;
  CrewState get _crew => _draft.crew;

  /// Persist camera count + crew, then either publish the event (Continue →
  /// Page 3) or leave it as a draft and close the flow ([asDraft]). The event
  /// row already exists as a draft from Page 1, so publishing just flips its
  /// status to 'scheduled'.
  Future<void> _commit({required bool asDraft}) async {
    final eventId = _draft.event?.id;
    if (eventId == null) return;

    setState(() {
      _committing = true;
      _error = null;
    });
    try {
      // Persist the camera count; the per-slot rows (labels/master/operator
      // assignment) are filled in later, on the Sound Check page.
      await EventService.update(
        eventId: eventId,
        cameraCount: _crew.cameraCount,
      );
      final saved = await CrewService.saveCameras(
        eventId: eventId,
        count: _crew.cameraCount,
      );
      _draft.savedCameras = saved;

      // Crew members are added without a camera/device slot here.
      for (final pick in _crew.operators.values) {
        await CrewService.assignOperator(
          eventId: eventId,
          operatorId: pick.profile.id,
        );
      }

      if (asDraft) {
        // Leave the event as a draft and exit the flow.
        if (!mounted) return;
        widget.onCancel();
        return;
      }

      // Paid events require an active payout account before going public.
      if ((_draft.priceCents ?? 0) > 0) {
        if (!mounted) return;
        if (!await ensurePaidPublishAllowed(context)) {
          if (mounted) setState(() => _committing = false);
          return;
        }
      }

      // Publish: flip the draft to a scheduled (live-eligible) event.
      final published = await EventService.publishDraft(eventId);
      _draft.event = published;

      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              EventCreatedPage(draft: _draft, onClose: widget.onCancel),
        ),
      );
    } catch (e) {
      // A pre-0078 draft can still be holding free-multicam state; the server
      // trigger catches it here, so show the host what to fix rather than a
      // raw failure.
      if (!mounted) return;
      setState(
        () => _error =
            PricingService.friendlyError(e) ?? 'Couldn\'t save crew: $e',
      );
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: const BackButton(),
        title: Text('Choose Your Crew', style: NileTextStyles.headingMd()),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Cancel',
            onPressed: widget.onCancel,
          ),
        ],
      ),
      body: NileMaxWidth(
        child: AbsorbPointer(
          absorbing: _committing,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(NileSpacing.s24, NileSpacing.s8, NileSpacing.s24, NileSpacing.s40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CrewEditor(
                  state: _crew,
                  showCameras: false,
                  onChanged: () => setState(() {}),
                ),
                const SizedBox(height: 16),
                Text(
                  'Publishing makes your event visible to followers. Not ready? '
                  'Save it as a draft and finish later from your profile.',
                  style: NileTextStyles.bodySm().copyWith(
                    color: NileColors.txtTertiary,
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
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
                const SizedBox(height: 28),
                FilledButton(
                  onPressed: _committing ? null : () => _commit(asDraft: false),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                    textStyle: NileTextStyles.labelLg().copyWith(color: null),
                  ),
                  child: _committing
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: NileColors.onVolt,
                          ),
                        )
                      : Text(
                          _crew.operators.isEmpty
                              ? 'Publish Event'
                              : 'Assign & Publish',
                        ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _committing ? null : () => _commit(asDraft: true),
                  child: Text(
                    'Save event as draft',
                    style: NileTextStyles.bodyMd().copyWith(
                      color: NileColors.txtSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Page 3: Event Created ─────────────────────────────────────────────────────

class EventCreatedPage extends StatelessWidget {
  final EventDraft draft;
  final VoidCallback onClose;

  const EventCreatedPage({
    super.key,
    required this.draft,
    required this.onClose,
  });

  Event? get _event => draft.event;

  String _shareText() {
    final ev = _event;
    return ShareUrls.eventCaption(
      id: ev?.id ?? '',
      title: ev?.title ?? draft.name,
      hostUsername: ev?.hostUsername,
    );
  }

  String _timeRange() {
    final start = draft.scheduledAt;
    if (start == null) {
      return 'Not scheduled · ${_fmtDuration(draft.durationMinutes)}';
    }
    final end = draft.endAt!;
    return '${_fmtDateTime(start)} → ${_fmtClock(end)} · ${_fmtDuration(draft.durationMinutes)}';
  }

  void _postAbout(BuildContext context) {
    final ev = _event;
    context.push(
      NileRoutes.createPost,
      extra: CreatePostArgs(
        initialText: ev == null ? null : 'Going live: ${ev.title} 🎥',
        eventId: ev?.id,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ev = _event;
    final operators = draft.crew.operators.values.toList();

    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Done',
          onPressed: onClose,
        ),
        title: Text('Event Created', style: NileTextStyles.headingMd()),
      ),
      body: NileMaxWidth(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(NileSpacing.s24, NileSpacing.s8, NileSpacing.s24, NileSpacing.s40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              Icon(Icons.check_circle, size: 56, color: NileColors.volt),
              const SizedBox(height: 12),
              Text(
                'You\'re all set',
                textAlign: TextAlign.center,
                style: NileTextStyles.headingLg(),
              ),
              const SizedBox(height: 24),

              // Summary card
              Container(
                padding: const EdgeInsets.all(NileSpacing.s16),
                decoration: BoxDecoration(
                  color: NileColors.bgSurface,
                  border: Border.all(color: NileColors.border),
                  borderRadius: BorderRadius.circular(NileRadius.lg),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(draft.name, style: NileTextStyles.headingSm()),
                    const SizedBox(height: 10),
                    _SummaryLine(icon: Icons.schedule, text: _timeRange()),
                    const SizedBox(height: 6),
                    _SummaryLine(
                      icon: Icons.videocam,
                      text:
                          '${draft.savedCameras.length} ${draft.savedCameras.length == 1 ? 'camera' : 'cameras'}',
                    ),
                    const SizedBox(height: 6),
                    _SummaryLine(
                      icon: Icons.people_outline,
                      text: operators.isEmpty
                          ? 'No operators assigned yet'
                          : '${operators.length} operator${operators.length == 1 ? '' : 's'}: '
                                '${operators.map((o) => '@${o.profile.username}').join(', ')}',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              FilledButton.icon(
                onPressed: () => _postAbout(context),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Post About It'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                  textStyle: NileTextStyles.labelLg().copyWith(color: null),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () =>
                    Share.share(_shareText(), subject: ev?.title ?? draft.name),
                icon: const Icon(Icons.ios_share),
                label: const Text('Share With Friends'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                ),
              ),

              const SizedBox(height: 24),
              // Link to the event page.
              InkWell(
                onTap: ev == null
                    ? null
                    : () => context.push(NileRoutes.event(ev.id), extra: ev),
                borderRadius: BorderRadius.circular(NileRadius.sm),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NileSpacing.s16,
                    vertical: NileSpacing.s12,
                  ),
                  decoration: BoxDecoration(
                    color: NileColors.bgSurface,
                    border: Border.all(color: NileColors.border),
                    borderRadius: BorderRadius.circular(NileRadius.sm),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.open_in_new,
                        size: 18,
                        color: NileColors.txtSecondary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'View event page',
                          style: NileTextStyles.bodyMd(),
                        ),
                      ),
                      Icon(
                        Icons.chevron_right,
                        size: 20,
                        color: NileColors.txtTertiary,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Shared duration / date formatting used by Page 3.
String _fmtDuration(int mins) {
  final h = mins ~/ 60;
  final m = mins % 60;
  if (h > 0 && m > 0) return '${h}h ${m}m';
  if (h > 0) return '${h}h';
  return '${m}m';
}

String _fmtClock(DateTime dt) =>
    '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

String _fmtDateTime(DateTime dt) {
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
  return '${months[dt.month - 1]} ${dt.day} · ${_fmtClock(dt)}';
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: NileTextStyles.labelSm());
}

/// Icon + text line used in the Page 3 summary card.
class _SummaryLine extends StatelessWidget {
  final IconData icon;
  final String text;
  const _SummaryLine({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: NileColors.txtSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: NileTextStyles.bodySm().copyWith(
              color: NileColors.txtPrimary,
            ),
          ),
        ),
      ],
    );
  }
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyState() => Center(
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

/// Desktop-only mirror of the card this draft will become — cover, byline,
/// title, when it runs and what it costs. Display-only: it reads the form's
/// current values and never writes back, so nothing here can change what gets
/// published. Built rather than borrowed because the feed's own event card
/// takes a persisted [Event], and this draft doesn't have one yet.
class _EventPreviewCard extends StatelessWidget {
  final Uint8List? coverBytes;
  final String title;
  final UserProfile? host;
  final DateTime? scheduledAt;
  final int? durationMinutes;
  final int priceCents;
  final int cameraCount;

  const _EventPreviewCard({
    required this.coverBytes,
    required this.title,
    required this.host,
    required this.scheduledAt,
    required this.durationMinutes,
    required this.priceCents,
    required this.cameraCount,
  });

  String get _when {
    final start = scheduledAt;
    final mins = durationMinutes;
    final runs = mins == null ? null : _fmtDuration(mins);
    if (start == null) {
      return runs == null ? 'Not scheduled' : 'Not scheduled · $runs';
    }
    return runs == null
        ? _fmtDateTime(start)
        : '${_fmtDateTime(start)} · $runs';
  }

  @override
  Widget build(BuildContext context) {
    final handle = host?.username ?? 'you';
    final initial = handle.isEmpty ? '?' : handle[0].toUpperCase();
    final avatarUrl = host?.avatarUrl;

    return Material(
      color: NileColors.bgSurface,
      borderRadius: BorderRadius.circular(NileRadius.lg),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: coverBytes == null
                ? ColoredBox(
                    color: NileColors.bgRaised,
                    child: Center(
                      child: Icon(
                        Icons.image_outlined,
                        size: 28,
                        color: NileColors.txtTertiary,
                      ),
                    ),
                  )
                : Image.memory(coverBytes!, fit: BoxFit.cover),
          ),
          Padding(
            padding: const EdgeInsets.all(NileSpacing.s12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: NileColors.bgRaised,
                      backgroundImage: avatarUrl == null
                          ? null
                          : nileAvatarImage(avatarUrl, 14),
                      child: avatarUrl != null
                          ? null
                          : Text(
                              initial,
                              style: NileTextStyles.labelSm().copyWith(
                                color: NileColors.txtPrimary,
                                letterSpacing: 0,
                              ),
                            ),
                    ),
                    const SizedBox(width: NileSpacing.s8),
                    Expanded(
                      child: Text(
                        '@$handle',
                        style: NileTextStyles.bodySm(),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    _PricePill(priceCents: priceCents),
                  ],
                ),
                const SizedBox(height: NileSpacing.s6),
                Text(
                  title.isEmpty ? 'Untitled event' : title,
                  style: NileTextStyles.headingSm(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: NileSpacing.s8),
                Row(
                  children: [
                    Icon(
                      Icons.schedule,
                      size: 14,
                      color: NileColors.txtTertiary,
                    ),
                    const SizedBox(width: NileSpacing.s6),
                    Expanded(
                      child: Text(
                        _when,
                        style: NileTextStyles.caption().copyWith(
                          color: NileColors.txtSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      Icons.videocam,
                      size: 14,
                      color: NileColors.txtTertiary,
                    ),
                    const SizedBox(width: NileSpacing.s4),
                    Text(
                      '$cameraCount',
                      style: NileTextStyles.caption().tabular,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The ticket price as it reads on a card. Free is a neutral chip; a price is
/// volt — the same emphasis the payout card gives the host's cut.
class _PricePill extends StatelessWidget {
  final int priceCents;

  const _PricePill({required this.priceCents});

  @override
  Widget build(BuildContext context) {
    final paid = priceCents > 0;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: NileSpacing.s8,
        vertical: NileSpacing.s2,
      ),
      decoration: BoxDecoration(
        color: paid ? NileColors.volt : NileColors.bgRaised,
        borderRadius: BorderRadius.circular(NileRadius.pill),
      ),
      child: Text(
        paid ? '\$${(priceCents / 100).toStringAsFixed(2)}' : 'Free',
        style: NileTextStyles.caption()
            .copyWith(color: paid ? NileColors.onVolt : NileColors.txtSecondary)
            .tabular,
      ),
    );
  }
}
