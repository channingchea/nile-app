import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/ad_service.dart';
import '../services/calendar_ics.dart';
import '../services/crew_service.dart';
import '../services/share_urls.dart';
import '../services/event_service.dart';
import '../services/follow_service.dart';
import '../services/livekit_service.dart';
import '../services/report_service.dart';
import '../services/supabase_client.dart';
import '../services/ticket_service.dart';
import '../theme.dart';
import '../widgets/live_badge.dart';
import '../widgets/official_badge.dart';
import '../widgets/photo_viewer.dart';
import '../widgets/rolling_number.dart';
import 'attendee_list_screen.dart';
import 'audio_screen.dart';
import 'boost_performance_screen.dart';
import 'camera_screen.dart';
import 'crew_setup_screen.dart';
import 'widgets/moderation_menu.dart';
import 'edit_event_screen.dart';
import 'profile_screen.dart';
import 'replay_pricing_screen.dart';
import 'replay_screen.dart';
import 'viewer_screen.dart';

/// Detail screen for a single event (scheduled, live, or ended).
///
/// Supply either [event] (when navigating from the feed) or [eventId] (when
/// arriving via deep link / shared id). Subscribes to realtime updates so a
/// scheduled event flips to live without a manual refresh.
class EventDetailScreen extends StatefulWidget {
  final Event? event;
  final String? eventId;

  /// Id of the profile this screen was pushed from, if any. Tapping the host
  /// row pops back to that profile instead of pushing a duplicate copy, so
  /// profile → event → profile → … chains can't grow the stack unbounded.
  final String? fromProfileId;

  const EventDetailScreen({
    super.key,
    this.event,
    this.eventId,
    this.fromProfileId,
  })
    : assert(
        event != null || eventId != null,
        'EventDetailScreen needs either event or eventId',
      );

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen>
    with WidgetsBindingObserver {
  Event? _event;
  String? _error;
  bool _loading = true;

  // Follow state
  bool _isFollowing = false;
  bool _followBusy = false;

  // Ticket state
  bool _hasTicket = false;
  bool _ticketBusy = false;
  int? _ticketsRemaining; // null = unlimited

  // Crew: assigned camera operators get free access to the event.
  bool _isOperator = false;
  MyOperatorAssignment? _assignment;

  // Replay/VOD. _replayWatchable: a ready replay this user may watch now (→
  // "Watch Replay"). _replayLockedByTicket: a ready replay exists but the user
  // lacks a ticket on a paid event (→ "buy a ticket to watch the replay").
  bool _replayWatchable = false;
  bool _replayLockedByTicket = false;
  bool _replayHasReplay = false;
  bool _replayPublished = false;
  int? _replayPrice; // cents, from replay-exists (server-authoritative)

  // Countdown
  Timer? _ticker;
  Duration _remaining = Duration.zero;

  // Active sponsorship (0079): advertiser name for the "Sponsored by" line.
  String? _sponsorName;

  // Realtime
  RealtimeChannel? _channel;

  bool get _isOwnEvent {
    final uid = supabase.auth.currentUser?.id;
    return uid != null && _event?.hostId == uid;
  }

  bool get _countdownExpired =>
      _event?.isScheduled == true &&
      _event?.scheduledAt != null &&
      _remaining <= Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _event = widget.event;
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _channel?.unsubscribe();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from the Stripe browser flow — re-check ticket status.
    if (state == AppLifecycleState.resumed) _refreshTicketStatus();
  }

  /// Poll ticket status a few times to absorb Stripe webhook latency.
  Future<void> _refreshTicketStatus() async {
    final event = _event;
    if (event == null ||
        _hasTicket ||
        _isOwnEvent ||
        event.price == null ||
        event.price! <= 0) {
      return;
    }
    for (var attempt = 0; attempt < 5; attempt++) {
      final purchased = await TicketService.hasPurchased(event.id);
      if (!mounted) return;
      if (purchased) {
        setState(() => _hasTicket = true);
        _offerAddToCalendar(event);
        return;
      }
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  /// Post-purchase prompt to save the event to the user's calendar.
  void _offerAddToCalendar(Event event) {
    if (!mounted || !CalendarIcs.canAdd(event)) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Ticket confirmed!'),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Add to calendar',
          textColor: NileColors.volt,
          onPressed: () => CalendarIcs.share(event),
        ),
      ),
    );
  }

  // ── Data ────────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _event ??= await EventService.fetchById(widget.eventId!);
      if (_event == null) throw Exception('Event not found');

      // Follow state (skip for own events)
      bool following = false;
      if (!_isOwnEvent) {
        following = await FollowService.isFollowing(_event!.hostId);
      }

      // Crew assignment: free access for assigned operators, and (for the host)
      // the slot/audio role they assigned themselves so routing is correct.
      final assignment = await CrewService.myAssignment(_event!.id);

      // Ticket state (only relevant for paid events the user can't already
      // access as host or operator).
      bool hasTicket = false;
      int? remaining;
      if (_event!.price != null &&
          _event!.price! > 0 &&
          !_isOwnEvent &&
          assignment == null) {
        final results = await Future.wait([
          TicketService.hasPurchased(_event!.id),
          TicketService.ticketsRemaining(_event!.id),
        ]);
        hasTicket = results[0] as bool;
        remaining = results[1] as int?;
      }

      if (!mounted) return;
      setState(() {
        _isFollowing = following;
        _hasTicket = hasTicket;
        _ticketsRemaining = remaining;
        _isOperator = assignment != null;
        _assignment = assignment;
        _loading = false;
      });

      _initCountdown();
      _initRealtime();
      _checkReplay();

      // Best-effort "Sponsored by" line (0079) — only set for an active,
      // approved sponsorship; never blocks or fails the screen.
      AdService.lobbySponsorship(_event!.id).then((s) {
        if (mounted && s != null) {
          setState(() => _sponsorName = s.advertiserName);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _initCountdown() {
    _ticker?.cancel();
    final target = _event?.scheduledAt;
    if (_event?.isScheduled != true || target == null) return;
    _tick(target);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick(target));
  }

  void _tick(DateTime target) {
    final diff = target.difference(DateTime.now());
    if (!mounted) return;
    setState(() => _remaining = diff.isNegative ? Duration.zero : diff);
  }

  /// For ended events, probe whether a ready replay exists and whether this user
  /// may watch it. We key off `replay-exists` (not `replay-url`) so a paid-event
  /// viewer WITHOUT a ticket is distinguished from "no replay at all" — the
  /// former still gets a buy-ticket CTA. (fix 1)
  Future<void> _checkReplay() async {
    final event = _event;
    if (event == null || !event.isEnded) return;
    final slug = event.liveKitEventId ?? event.id;
    final r = await LivekitService.replayExists(eventId: slug);
    if (!mounted) return;
    setState(() {
      _replayWatchable = r.available;
      _replayLockedByTicket = r.hasReplay && !r.authorized;
      _replayHasReplay = r.hasReplay;
      _replayPublished = r.published;
      _replayPrice = r.replayPrice;
    });
  }

  /// Host: open the pricing screen; refresh the replay probe on return so the
  /// CTA flips from "Set replay price" once published.
  Future<void> _priceReplay() async {
    final event = _event;
    if (event == null) return;
    final published = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => ReplayPricingScreen(event: event)),
    );
    if (published == true && mounted) {
      await _load();
    }
  }

  void _watchReplay() {
    final event = _event;
    if (event == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ReplayScreen(event: event)),
    );
  }

  void _initRealtime() {
    _channel?.unsubscribe();
    _channel = EventService.subscribeToEventById(
      eventId: _event!.id,
      onUpdate: (record) {
        if (!mounted) return;
        // Merge incoming columns onto current state so we keep the joined
        // host profile we already have.
        final merged = {
          'id': _event!.id,
          'host_id': _event!.hostId,
          'title': record['title'] ?? _event!.title,
          'description': record['description'] ?? _event!.description,
          'status': record['status'] ?? _event!.status,
          'livekit_room': record['livekit_room'] ?? _event!.liveKitEventId,
          'cover_image_url': record['cover_image_url'] ?? _event!.coverImageUrl,
          'viewer_count': record['viewer_count'] ?? _event!.viewerCount,
          'price': record['price'] ?? _event!.price,
          'ticket_limit': record['ticket_limit'] ?? _event!.ticketLimit,
          'created_at': _event!.createdAt.toIso8601String(),
          'started_at':
              record['started_at'] ?? _event!.startedAt?.toIso8601String(),
          'scheduled_at':
              record['scheduled_at'] ?? _event!.scheduledAt?.toIso8601String(),
          'profiles': {
            'username': _event!.hostUsername,
            'avatar_url': _event!.hostAvatarUrl,
            'is_official': _event!.hostIsOfficial,
          },
        };
        setState(() => _event = Event.fromJson(merged));
        if (_event!.isLive || _event!.isEnded) _ticker?.cancel();
      },
    );
  }

  // ── Actions ─────────────────────────────────────────────────────────────────

  Future<void> _toggleFollow() async {
    if (_event == null || _isOwnEvent) return;
    setState(() => _followBusy = true);
    final wasFollowing = _isFollowing;
    setState(() => _isFollowing = !wasFollowing);
    try {
      wasFollowing
          ? await FollowService.unfollow(_event!.hostId)
          : await FollowService.follow(_event!.hostId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isFollowing = wasFollowing);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Couldn\'t update follow: $e')));
    } finally {
      if (mounted) setState(() => _followBusy = false);
    }
  }

  Future<void> _share() async {
    if (_event == null) return;
    final text = ShareUrls.eventCaption(
      id: _event!.id,
      title: _event!.title,
      hostUsername: _event!.hostUsername,
    );
    await Share.share(text, subject: _event!.title);
  }

  Future<void> _copyId() async {
    if (_event == null) return;
    await Clipboard.setData(ClipboardData(text: _event!.id));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Event ID copied')));
  }

  /// [kind] 'live' buys a ticket to the show; 'replay' buys the published VOD.
  /// Price is read server-side from the event either way.
  Future<void> _buyTicket({String kind = 'live'}) async {
    if (_event == null) return;
    setState(() => _ticketBusy = true);
    try {
      final url = await TicketService.createCheckoutUrl(
        eventId: _event!.id,
        kind: kind,
      );
      final uri = Uri.parse(url);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw Exception('Could not open checkout');
      }
      // Poll for ticket confirmation after returning from browser
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Complete payment in your browser. Ticket status updates automatically.',
          ),
          duration: Duration(seconds: 5),
        ),
      );
      // Poll for webhook confirmation (also re-checked on app resume).
      await _refreshTicketStatus();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Couldn\'t start checkout: $e')));
    } finally {
      if (mounted) setState(() => _ticketBusy = false);
    }
  }

  /// Opens the web ad portal's boost flow for this event in the EXTERNAL
  /// browser (not an in-app webview). All checkout happens on the web, so there
  /// is no in-app purchase path — this CTA is just a link out, never a buy button.
  Future<void> _boost() async {
    if (_event == null || !_isOwnEvent || _event!.isEnded) return;
    final uri = Uri.parse(ShareUrls.boost(_event!.id));
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open the boost page')));
    }
  }

  /// Host-only (Phase A-3): the host's boost campaigns with impressions,
  /// clicks, CTR, and spend.
  void _openBoostPerformance() {
    if (!_isOwnEvent) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const BoostPerformanceScreen()),
    );
  }

  void _watch() {
    // Allow entry once the show is live OR while the host is in Sound Check
    // (the viewer lands in the Lobby until Start Show).
    if (_event == null || !(_event!.isLive || _event!.isSoundCheck)) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ViewerScreen(initialEventId: _event!.liveKitEventId),
      ),
    );
  }

  /// Host/operator entry. The host kicking off a not-yet-started show first
  /// passes through the Sound Check screen to assign crew → cameras and the
  /// stream audio device; Continue there hands off to the streaming flow.
  /// Operators (and the host re-entering a show already in Sound Check or live)
  /// go straight to streaming.
  void _enterAsCamera() {
    if (_event == null || !(_isOwnEvent || _isOperator)) return;
    final needsSetup = _isOwnEvent && !_event!.isSoundCheck && !_event!.isLive;
    if (needsSetup) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CrewSetupScreen(
            eventId: _event!.id,
            onContinue: () {
              if (!mounted) return;
              // Replace the setup screen with the streaming screen so Back
              // from streaming returns to event detail, not the setup list.
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => _streamScreen()),
              );
            },
          ),
        ),
      );
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => _streamScreen()));
  }

  /// The streaming screen for this user on this event: audio operators run the
  /// audio feed; everyone else runs a camera. Operators get their assigned slot
  /// label pre-filled; the host defaults to their own handle.
  Widget _streamScreen() {
    if (_assignment?.isAudioOperator == true) {
      return AudioScreen(
        initialEventId: _event!.liveKitEventId,
        isHost: _isOwnEvent,
      );
    }
    final cameraName =
        _assignment?.cameraLabel ??
        (_isOwnEvent ? '@${_event!.hostUsername}' : null);
    return CameraScreen(
      initialEventId: _event!.liveKitEventId,
      initialCameraName: cameraName,
      isHost: _isOwnEvent,
    );
  }

  void _openHost() {
    if (_event == null) return;
    // Came here from the host's profile? Pop back to it instead of stacking
    // a duplicate.
    if (widget.fromProfileId == _event!.hostId) {
      Navigator.pop(context);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ProfileScreen(userId: _event!.hostId)),
    );
  }

  Future<void> _edit() async {
    if (_event == null || !_isOwnEvent) return;
    final updated = await Navigator.push<Event>(
      context,
      MaterialPageRoute(builder: (_) => EditEventScreen(event: _event!)),
    );
    if (updated != null && mounted) {
      setState(() => _event = updated);
      _initCountdown();
    }
  }

  Future<void> _delete() async {
    if (_event == null || !_isOwnEvent) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: const Text('Delete event?'),
        content: Text(
          'This permanently deletes "${_event!.title}" and all its tickets. '
          'This can\'t be undone.',
          style: NileTextStyles.bodySm().copyWith(
            color: NileColors.txtSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: NileColors.coral),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await EventService.deleteEvent(
        _event!.id,
        liveKitEventId: _event!.liveKitEventId,
      );
      if (!mounted) return;
      Navigator.pop(context, true); // signal deletion to the previous screen
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Event deleted')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Couldn\'t delete: $e')));
    }
  }

  void _openAttendees() {
    if (_event == null || !_isOwnEvent) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            AttendeeListScreen(eventId: _event!.id, eventTitle: _event!.title),
      ),
    );
  }

  // ── UI ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      body: NileMaxWidth(child: SafeArea(child: _buildBody())),
    );
  }

  Widget _buildBody() {
    // Render immediately when an event was passed in so the Hero flight from
    // the previous screen can run; follow/ticket state hydrates in place.
    // Back lives on the SliverAppBar below, which only exists once the event
    // has loaded — so these two branches carry their own, or a slow/failed
    // fetch strands the user (this screen is often opened by id alone).
    if (_event == null) {
      return Stack(
        children: [
          if (_loading)
            Center(child: CircularProgressIndicator(color: NileColors.volt))
          else
            _ErrorView(message: _error ?? 'Event not found', onRetry: _load),
          const Align(alignment: Alignment.topLeft, child: BackButton()),
        ],
      );
    }
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          backgroundColor: NileColors.bgPage,
          expandedHeight: 240,
          actions: [
            if (_isOwnEvent) ...[
              IconButton(
                tooltip: 'Attendees',
                icon: Icon(
                  Icons.people_outline,
                  color: NileColors.txtPrimary,
                ),
                onPressed: _openAttendees,
              ),
              IconButton(
                tooltip: 'Edit',
                icon: Icon(
                  Icons.edit_outlined,
                  color: NileColors.txtPrimary,
                ),
                onPressed: _edit,
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline, color: NileColors.coral),
                onPressed: _delete,
              ),
            ],
            IconButton(
              tooltip: 'Share',
              icon: Icon(Icons.ios_share, color: NileColors.txtPrimary),
              onPressed: _share,
            ),
            IconButton(
              tooltip: 'Copy ID',
              icon: Icon(Icons.link, color: NileColors.txtPrimary),
              onPressed: _copyId,
            ),
            if (!_isOwnEvent)
              IconButton(
                tooltip: 'Report event',
                icon: Icon(
                  Icons.flag_outlined,
                  color: NileColors.txtPrimary,
                ),
                onPressed: () => Moderation.showReportSheet(
                  context,
                  targetType: ReportTargetType.event,
                  targetId: _event!.id,
                ),
              ),
            const SizedBox(width: 4),
          ],
          flexibleSpace: FlexibleSpaceBar(
            background: _CoverImage(event: _event!),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s16, NileSpacing.s16, NileSpacing.s32),
          sliver: SliverList.list(
            children: [
              Row(
                children: [
                  _StatusChip(event: _event!),
                  if (_event!.price != null && _event!.price! > 0) ...[
                    const SizedBox(width: 8),
                    _PriceChip(
                      priceCents: _event!.price!,
                      ticketsRemaining: _ticketsRemaining,
                      hasTicket: _hasTicket,
                      isOperator: _isOperator,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Text(_event!.title, style: NileTextStyles.headingLg()),
              const SizedBox(height: 16),
              _HostRow(
                event: _event!,
                isOwn: _isOwnEvent,
                isFollowing: _isFollowing,
                busy: _followBusy,
                onTapHost: _openHost,
                onToggleFollow: _toggleFollow,
              ),
              const SizedBox(height: 20),
              // Active sponsorship disclosure (0079) — mirrors the lobby's
              // "Sponsored" tag so viewers aren't surprised at showtime.
              if (_sponsorName != null) ...[
                Row(
                  children: [
                    Icon(Icons.workspace_premium,
                        size: 16, color: NileColors.volt),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Sponsored by $_sponsorName',
                        style: NileTextStyles.bodySm().copyWith(
                          color: NileColors.txtSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              if (_event!.isScheduled) ...[
                _CountdownBlock(
                  scheduledAt: _event!.scheduledAt,
                  remaining: _remaining,
                  expired: _countdownExpired,
                ),
                const SizedBox(height: 20),
              ],
              if (_event!.description != null &&
                  _event!.description!.trim().isNotEmpty) ...[
                Text('About', style: NileTextStyles.labelSm()),
                const SizedBox(height: 6),
                Text(_event!.description!, style: NileTextStyles.bodyMd()),
                const SizedBox(height: 24),
              ],
              _PrimaryCta(
                event: _event!,
                countdownExpired: _countdownExpired,
                isOwn: _isOwnEvent,
                hasTicket: _hasTicket,
                isOperator: _isOperator,
                isAudioOperator: _assignment?.isAudioOperator ?? false,
                ticketBusy: _ticketBusy,
                ticketsRemaining: _ticketsRemaining,
                replayWatchable: _replayWatchable,
                replayLockedByTicket: _replayLockedByTicket,
                replayExistsForEvent: _replayHasReplay,
                replayPublished: _replayPublished,
                replayPriceCents: _replayPrice,
                onWatch: _watch,
                onBuyTicket: _buyTicket,
                onBuyReplay: () => _buyTicket(kind: 'replay'),
                onEnterAsCamera: _enterAsCamera,
                onWatchReplay: _watchReplay,
                onPriceReplay: _priceReplay,
              ),
              // Host-only: promote this event via the web ad portal. Opens in
              // the external browser — a link out, not an in-app purchase.
              if (_isOwnEvent && !_event!.isEnded) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _boost,
                    icon: const Icon(Icons.campaign_outlined),
                    label: const Text('Boost this event'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: NileColors.txtPrimary,
                      side: BorderSide(color: NileColors.border),
                      padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                      shape: const StadiumBorder(),
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _openBoostPerformance,
                  icon: const Icon(Icons.insights_outlined, size: 18),
                  label: const Text('View boost performance'),
                  style: TextButton.styleFrom(
                    foregroundColor: NileColors.txtSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _CoverImage extends StatelessWidget {
  final Event event;
  const _CoverImage({required this.event});

  @override
  Widget build(BuildContext context) {
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [NileColors.bgRaised, NileColors.bgSurface],
        ),
      ),
      child: Center(
        child: Icon(Icons.live_tv, size: 56, color: NileColors.border),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          // Tap the cover to view it full-screen (no-op when there's none).
          onTap: event.thumbnailUrl == null
              ? null
              : () => PhotoViewerScreen.open(
                    context,
                    image: NetworkImage(event.thumbnailUrl!),
                  ),
          child: Hero(
            tag: 'event-cover-${event.id}',
            child: event.thumbnailUrl != null
                ? Image.network(
                    event.thumbnailUrl!,
                    cacheWidth: nileDecodeWidth(600),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => placeholder,
                  )
                : placeholder,
          ),
        ),
        // IgnorePointer so the scrim doesn't swallow the tap-to-expand hit.
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, NileColors.bgPage],
                stops: [0.5, 1.0],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  final Event event;
  const _StatusChip({required this.event});

  @override
  Widget build(BuildContext context) {
    if (event.isLive) return const LiveBadge(label: 'LIVE NOW');

    late final Color bg;
    late final Color fg;
    late final String label;
    if (event.isSoundCheck) {
      bg = NileColors.bgRaised;
      fg = NileColors.volt;
      label = 'STARTING SOON';
    } else if (event.isEnded) {
      bg = NileColors.bgRaised;
      fg = NileColors.txtSecondary;
      label = 'ENDED';
    } else {
      // Neutral — volt is reserved for the Get Ticket CTA on this screen.
      bg = NileColors.bgRaised;
      fg = NileColors.txtSecondary;
      label = 'SCHEDULED';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s8, vertical: NileSpacing.s4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(NileRadius.xs),
      ),
      child: Text(
        label,
        style: NileTextStyles.caption().copyWith(
          color: fg,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _HostRow extends StatelessWidget {
  final Event event;
  final bool isOwn;
  final bool isFollowing;
  final bool busy;
  final VoidCallback onTapHost;
  final VoidCallback onToggleFollow;

  const _HostRow({
    required this.event,
    required this.isOwn,
    required this.isFollowing,
    required this.busy,
    required this.onTapHost,
    required this.onToggleFollow,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        InkWell(
          onTap: onTapHost,
          borderRadius: BorderRadius.circular(NileRadius.pill),
          child: Hero(
            tag: 'avatar-${event.hostId}',
            child: CircleAvatar(
              radius: 22,
              backgroundColor: NileColors.bgRaised,
              backgroundImage: event.hostAvatarUrl != null
                  ? nileAvatarImage(event.hostAvatarUrl!, 22)
                  : null,
              child: event.hostAvatarUrl == null
                  ? Text(
                      event.hostUsername[0].toUpperCase(),
                      style: NileTextStyles.headingSm(),
                    )
                  : null,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: InkWell(
            onTap: onTapHost,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        '@${event.hostUsername}',
                        style: NileTextStyles.labelMd(),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (event.hostIsOfficial) ...[
                      const SizedBox(width: 4),
                      const OfficialBadge(size: 15),
                    ],
                  ],
                ),
                Text('Host', style: NileTextStyles.caption()),
              ],
            ),
          ),
        ),
        if (!isOwn)
          isFollowing
              ? OutlinedButton(
                  onPressed: busy ? null : onToggleFollow,
                  child: const Text('Following'),
                )
              : FilledButton(
                  onPressed: busy ? null : onToggleFollow,
                  child: const Text('Follow'),
                ),
      ],
    );
  }
}

class _CountdownBlock extends StatelessWidget {
  final DateTime? scheduledAt;
  final Duration remaining;
  final bool expired;

  const _CountdownBlock({
    required this.scheduledAt,
    required this.remaining,
    required this.expired,
  });

  String _fmtScheduled(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    final sameDay =
        local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
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
    final time =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    if (sameDay) return 'Today at $time';
    return '${months[local.month - 1]} ${local.day} · $time';
  }

  @override
  Widget build(BuildContext context) {
    if (scheduledAt == null) return const SizedBox.shrink();

    if (expired) {
      return Container(
        padding: const EdgeInsets.all(NileSpacing.s16),
        decoration: BoxDecoration(
          color: NileColors.bgSurface,
          borderRadius: BorderRadius.circular(NileRadius.lg),
          border: Border.all(color: NileColors.border),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: NileColors.volt,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Waiting for host to start the stream…',
                style: NileTextStyles.bodyMd(),
              ),
            ),
          ],
        ),
      );
    }

    final d = remaining;
    final days = d.inDays;
    final hours = d.inHours.remainder(24);
    final mins = d.inMinutes.remainder(60);
    final secs = d.inSeconds.remainder(60);

    return Container(
      padding: const EdgeInsets.all(NileSpacing.s16),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.lg),
        border: Border.all(color: NileColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.calendar_today,
                size: 14,
                color: NileColors.txtSecondary,
              ),
              const SizedBox(width: 6),
              Text(_fmtScheduled(scheduledAt!), style: NileTextStyles.bodySm()),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (days > 0) _CountUnit(value: days, label: 'days'),
              _CountUnit(value: hours, label: 'hrs'),
              _CountUnit(value: mins, label: 'min'),
              _CountUnit(value: secs, label: 'sec'),
            ],
          ),
        ],
      ),
    );
  }
}

class _CountUnit extends StatelessWidget {
  final int value;
  final String label;
  const _CountUnit({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Fixed width + tabular figures stop the two digits from reflowing
        // each tick (the display font's glyphs are variable-width).
        SizedBox(
          width: 52,
          child: Text(
            value.toString().padLeft(2, '0'),
            textAlign: TextAlign.center,
            style: NileTextStyles.displayMd().copyWith(
              color: NileColors.txtPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        Text(label, style: NileTextStyles.caption()),
      ],
    );
  }
}

class _PriceChip extends StatelessWidget {
  final int priceCents;
  final int? ticketsRemaining;
  final bool hasTicket;
  final bool isOperator;

  const _PriceChip({
    required this.priceCents,
    required this.ticketsRemaining,
    required this.hasTicket,
    this.isOperator = false,
  });

  @override
  Widget build(BuildContext context) {
    final soldOut = ticketsRemaining != null && ticketsRemaining == 0;
    // Operators have free access; show a crew badge instead of a price.
    final hasAccess = hasTicket || isOperator;
    final label = isOperator
        ? '✓ Crew'
        : hasTicket
        ? '✓ Ticket'
        : soldOut
        ? 'Sold Out'
        : '\$${(priceCents / 100).toStringAsFixed(priceCents % 100 == 0 ? 0 : 2)}';

    final bg = hasAccess ? NileColors.volt.withAlpha(30) : NileColors.bgRaised;
    final fg = hasAccess
        ? NileColors.volt
        : soldOut
        ? NileColors.txtSecondary
        : NileColors.txtPrimary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s8, vertical: NileSpacing.s4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(NileRadius.xs),
        border: Border.all(
          color: hasAccess ? NileColors.volt : NileColors.border,
        ),
      ),
      child: Text(
        label,
        style: NileTextStyles.caption().copyWith(
          color: fg,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _PrimaryCta extends StatelessWidget {
  final Event event;
  final bool countdownExpired;
  final bool isOwn;
  final bool hasTicket;
  final bool isOperator;
  final bool isAudioOperator;
  final bool ticketBusy;
  final int? ticketsRemaining;
  final bool replayWatchable;
  final bool replayLockedByTicket;
  final bool replayExistsForEvent;
  final bool replayPublished;
  final int? replayPriceCents;
  final VoidCallback onWatch;
  final VoidCallback onBuyTicket;
  final VoidCallback onBuyReplay;
  final VoidCallback onEnterAsCamera;
  final VoidCallback onWatchReplay;
  final VoidCallback onPriceReplay;

  const _PrimaryCta({
    required this.event,
    required this.countdownExpired,
    required this.isOwn,
    required this.hasTicket,
    required this.isOperator,
    this.isAudioOperator = false,
    required this.ticketBusy,
    required this.ticketsRemaining,
    required this.replayWatchable,
    required this.replayLockedByTicket,
    required this.replayExistsForEvent,
    required this.replayPublished,
    required this.replayPriceCents,
    required this.onWatch,
    required this.onBuyTicket,
    required this.onBuyReplay,
    required this.onEnterAsCamera,
    required this.onWatchReplay,
    required this.onPriceReplay,
  });

  bool get _isPaid => event.price != null && event.price! > 0;
  bool get _soldOut => ticketsRemaining != null && ticketsRemaining == 0;
  // Operators have free access just like the host and ticket holders.
  bool get _canWatch => !_isPaid || isOwn || hasTicket || isOperator;

  @override
  Widget build(BuildContext context) {
    // The host and assigned operators get a dedicated entry that streams their
    // camera, available on scheduled/soundcheck/live events (so they can enter
    // Sound Check, set up, and press Start Show). The host runs the show, so the
    // host always gets this entry even without an event_operators row.
    if ((isOwn || isOperator) && !event.isEnded) {
      return Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onEnterAsCamera,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                backgroundColor: NileColors.coral,
                foregroundColor: Colors.white,
              ),
              icon: Icon(isAudioOperator ? Icons.graphic_eq : Icons.videocam),
              label: Text(
                event.isSoundCheck || event.isLive
                    ? (isAudioOperator ? 'Enter as Audio' : 'Enter as Camera')
                    : 'Start Sound Check',
              ),
            ),
          ),
          if (event.isLive || event.isSoundCheck) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onWatch,
                icon: const Icon(Icons.play_arrow),
                label: Text(event.isLive ? 'Watch instead' : 'View Lobby'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                ),
              ),
            ),
          ],
        ],
      );
    }

    if (event.isLive || event.isSoundCheck) {
      // Paid event — user needs a ticket (gate applies in the Lobby too)
      if (_isPaid && !_canWatch) {
        return _GetTicketButton(
          priceCents: event.price!,
          soldOut: _soldOut,
          busy: ticketBusy,
          onBuy: onBuyTicket,
        );
      }
      // Sound Check → "Join Lobby" (volt), no viewer count yet.
      if (event.isSoundCheck) {
        return SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onWatch,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
              backgroundColor: NileColors.volt,
              foregroundColor: NileColors.onVolt,
            ),
            icon: const Icon(Icons.meeting_room_outlined),
            label: const Text('Join Lobby'),
          ),
        );
      }
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: onWatch,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
            backgroundColor: NileColors.coral,
            foregroundColor: Colors.white,
          ),
          icon: const Icon(Icons.play_arrow),
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Watch Now'),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s6, vertical: NileSpacing.s2),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(NileRadius.xs),
                ),
                child: NileRollingNumber(
                  value: event.viewerCount,
                  style: NileTextStyles.caption().copyWith(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (event.isEnded) {
      final children = <Widget>[];

      // A ready replay this user may watch → primary "Watch Replay" CTA.
      // (Crew always pass the gate, so the host/operators can preview before
      // publishing.)
      if (replayWatchable) {
        children.add(
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onWatchReplay,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
                backgroundColor: NileColors.volt,
                foregroundColor: NileColors.onVolt,
              ),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Watch Replay'),
            ),
          ),
        );
      }

      // Host with an unpublished replay → set a price to publish it (Phase 2).
      // The 48h cron publishes at the live price if they never do.
      if (isOwn && replayExistsForEvent && !replayPublished) {
        children.add(
          Padding(
            padding: EdgeInsets.only(top: children.isEmpty ? 0 : 10),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onPriceReplay,
                icon: const Icon(Icons.sell_outlined),
                label: const Text('Set replay price'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: NileColors.txtPrimary,
                  side: BorderSide(color: NileColors.border),
                  padding: const EdgeInsets.symmetric(
                    vertical: NileSpacing.s16,
                  ),
                ),
              ),
            ),
          ),
        );
      }

      if (children.isNotEmpty) return Column(children: children);

      // A published, priced replay this user hasn't bought → buy the VOD.
      // Live-ticket holders never land here (their ticket authorizes them).
      if (replayLockedByTicket && replayPublished) {
        return _GetTicketButton(
          priceCents: replayPriceCents ?? event.price ?? 0,
          soldOut: false,
          busy: ticketBusy,
          onBuy: onBuyReplay,
          labelPrefix: 'Get Replay',
        );
      }
      // A replay exists but the host hasn't published it yet.
      if (replayLockedByTicket && !replayPublished) {
        return SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: null,
            icon: const Icon(Icons.hourglass_top),
            label: const Text('Replay coming soon'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
            ),
          ),
        );
      }
      // No replay (or none yet) → inert ended state.
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: null,
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text('Stream Ended'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
          ),
        ),
      );
    }

    // Scheduled — show Get Ticket CTA for paid events where user hasn't purchased
    if (_isPaid && !_canWatch) {
      return _GetTicketButton(
        priceCents: event.price!,
        soldOut: _soldOut,
        busy: ticketBusy,
        onBuy: onBuyTicket,
      );
    }

    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: null,
        icon: const Icon(Icons.access_time),
        label: Text(countdownExpired ? 'Waiting for host' : 'Not started yet'),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
        ),
      ),
    );
  }
}

class _GetTicketButton extends StatelessWidget {
  final int priceCents;
  final bool soldOut;
  final bool busy;
  final VoidCallback onBuy;
  final String labelPrefix; // 'Get Ticket' (live) or 'Get Replay' (VOD)

  const _GetTicketButton({
    required this.priceCents,
    required this.soldOut,
    required this.busy,
    required this.onBuy,
    this.labelPrefix = 'Get Ticket',
  });

  @override
  Widget build(BuildContext context) {
    final priceLabel =
        '\$${(priceCents / 100).toStringAsFixed(priceCents % 100 == 0 ? 0 : 2)}';
    final enabled = !soldOut && !busy;
    final button = SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: (soldOut || busy) ? null : onBuy,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: NileSpacing.s16),
          backgroundColor: NileColors.volt,
          foregroundColor: Colors.black,
          disabledBackgroundColor: NileColors.bgRaised,
        ),
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.black,
                ),
              )
            : const Icon(Icons.confirmation_number_outlined),
        label: Text(soldOut ? 'Sold Out' : '$labelPrefix — $priceLabel'),
      ),
    );
    // Faint volt glow on the screen's single primary CTA.
    return enabled
        ? DecoratedBox(decoration: NileEffects.voltGlow, child: button)
        : button;
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(NileSpacing.s40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: NileColors.error),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: NileTextStyles.bodyMd().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
