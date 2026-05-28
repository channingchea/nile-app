import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/event_service.dart';
import '../services/follow_service.dart';
import '../services/supabase_client.dart';
import '../theme.dart';
import 'edit_event_screen.dart';
import 'profile_screen.dart';
import 'viewer_screen.dart';

/// Detail screen for a single event (scheduled, live, or ended).
///
/// Supply either [event] (when navigating from the feed) or [eventId] (when
/// arriving via deep link / shared id). Subscribes to realtime updates so a
/// scheduled event flips to live without a manual refresh.
class EventDetailScreen extends StatefulWidget {
  final Event? event;
  final String? eventId;

  const EventDetailScreen({super.key, this.event, this.eventId})
      : assert(event != null || eventId != null,
            'EventDetailScreen needs either event or eventId');

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  Event? _event;
  String? _error;
  bool _loading = true;

  // Follow state
  bool _isFollowing = false;
  bool _followBusy = false;

  // Countdown
  Timer? _ticker;
  Duration _remaining = Duration.zero;

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
    _event = widget.event;
    _load();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _channel?.unsubscribe();
    super.dispose();
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

      if (!mounted) return;
      setState(() {
        _isFollowing = following;
        _loading = false;
      });

      _initCountdown();
      _initRealtime();
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
          'cover_image_url':
              record['cover_image_url'] ?? _event!.coverImageUrl,
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Couldn\'t update follow: $e')),
      );
    } finally {
      if (mounted) setState(() => _followBusy = false);
    }
  }

  Future<void> _share() async {
    if (_event == null) return;
    final text =
        '${_event!.title} on Nile — @${_event!.hostUsername}\nnile://event/${_event!.id}';
    await Share.share(text, subject: _event!.title);
  }

  Future<void> _copyId() async {
    if (_event == null) return;
    await Clipboard.setData(ClipboardData(text: _event!.id));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Event ID copied')),
    );
  }

  void _watch() {
    if (_event == null || !_event!.isLive) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ViewerScreen(initialEventId: _event!.liveKitEventId),
      ),
    );
  }

  void _openHost() {
    if (_event == null) return;
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

  // ── UI ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      body: NileMaxWidth(child: SafeArea(child: _buildBody())),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: NileColors.volt));
    }
    if (_error != null || _event == null) {
      return _ErrorView(message: _error ?? 'Event not found', onRetry: _load);
    }
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          backgroundColor: NileColors.bgPage,
          expandedHeight: 240,
          actions: [
            if (_isOwnEvent)
              IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.edit_outlined,
                    color: NileColors.txtPrimary),
                onPressed: _edit,
              ),
            IconButton(
              tooltip: 'Share',
              icon: const Icon(Icons.ios_share, color: NileColors.txtPrimary),
              onPressed: _share,
            ),
            IconButton(
              tooltip: 'Copy ID',
              icon: const Icon(Icons.link, color: NileColors.txtPrimary),
              onPressed: _copyId,
            ),
            const SizedBox(width: 4),
          ],
          flexibleSpace: FlexibleSpaceBar(
            background: _CoverImage(event: _event!),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          sliver: SliverList.list(
            children: [
              _StatusChip(event: _event!),
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
                onWatch: _watch,
              ),
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
    final placeholder = const DecoratedBox(
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
        if (event.thumbnailUrl != null)
          Image.network(
            event.thumbnailUrl!,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => placeholder,
          )
        else
          placeholder,
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, NileColors.bgPage],
              stops: [0.5, 1.0],
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
    late final Color bg;
    late final Color fg;
    late final String label;
    if (event.isLive) {
      bg = NileColors.coral;
      fg = Colors.white;
      label = 'LIVE NOW';
    } else if (event.isEnded) {
      bg = NileColors.bgRaised;
      fg = NileColors.txtSecondary;
      label = 'ENDED';
    } else {
      bg = NileColors.bgRaised;
      fg = NileColors.volt;
      label = 'SCHEDULED';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(NileRadius.xs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (event.isLive) ...[
            const CircleAvatar(radius: 3.5, backgroundColor: Colors.white),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: NileTextStyles.caption().copyWith(
              color: fg,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ],
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
          child: CircleAvatar(
            radius: 22,
            backgroundColor: NileColors.bgRaised,
            backgroundImage: event.hostAvatarUrl != null
                ? NetworkImage(event.hostAvatarUrl!)
                : null,
            child: event.hostAvatarUrl == null
                ? Text(
                    event.hostUsername[0].toUpperCase(),
                    style: NileTextStyles.headingSm(),
                  )
                : null,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: InkWell(
            onTap: onTapHost,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('@${event.hostUsername}', style: NileTextStyles.labelMd()),
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
    final sameDay = local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
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
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: NileColors.bgSurface,
          borderRadius: BorderRadius.circular(NileRadius.md),
          border: Border.all(color: NileColors.border),
        ),
        child: Row(
          children: [
            const SizedBox(
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.md),
        border: Border.all(color: NileColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.calendar_today,
                  size: 14, color: NileColors.txtSecondary),
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
        Text(
          value.toString().padLeft(2, '0'),
          style: NileTextStyles.displayMd().copyWith(color: NileColors.volt),
        ),
        Text(label, style: NileTextStyles.caption()),
      ],
    );
  }
}

class _PrimaryCta extends StatelessWidget {
  final Event event;
  final bool countdownExpired;
  final VoidCallback onWatch;

  const _PrimaryCta({
    required this.event,
    required this.countdownExpired,
    required this.onWatch,
  });

  @override
  Widget build(BuildContext context) {
    if (event.isLive) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: onWatch,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(NileRadius.xs),
                ),
                child: Text('${event.viewerCount}',
                    style: NileTextStyles.caption()
                        .copyWith(color: Colors.white)),
              ),
            ],
          ),
        ),
      );
    }
    if (event.isEnded) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: null,
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text('Stream Ended'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      );
    }
    // scheduled
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: null,
        icon: const Icon(Icons.access_time),
        label: Text(countdownExpired ? 'Waiting for host' : 'Not started yet'),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
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
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                size: 48, color: NileColors.error),
            const SizedBox(height: 16),
            Text(message,
                textAlign: TextAlign.center,
                style: NileTextStyles.bodyMd()
                    .copyWith(color: NileColors.txtSecondary)),
            const SizedBox(height: 24),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
