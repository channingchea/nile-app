import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/destinations.dart';
import '../services/notification_service.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';
import 'profile_screen.dart';
import 'widgets/load_more_footer.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<AppNotification>? _items;
  String? _error;

  final _scroll = ScrollController();
  String? _cursor;
  bool _hasMore = false;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 400) {
      return;
    }
    if (_hasMore && !_loadingMore && _items != null) _loadMore();
  }

  Future<void> _load() async {
    setState(() {
      _items = null;
      _error = null;
    });
    try {
      final page = await NotificationService.list();
      setState(() {
        _items = page.items;
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
      });
      // Mark all read after listing — fire and forget.
      NotificationService.markAllRead();
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _loadMore() async {
    if (_cursor == null) return;
    setState(() => _loadingMore = true);
    try {
      final page = await NotificationService.list(cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _items = [...?_items, ...page.items];
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
      });
    } catch (_) {
      // Keep existing; scrolling retries.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _tap(AppNotification n) async {
    final destination = await Destinations.forNotification(
      n.type,
      entityId: n.entityId,
      actorId: n.actorId,
    );
    if (!mounted || destination == null) return;
    // Already inside the app, so this pushes: back returns to this list.
    context.push(destination.location, extra: destination.extra);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      body: SafeArea(
        child: NileMaxWidth(
          child: RefreshIndicator(
            color: NileColors.volt,
            backgroundColor: NileColors.bgSurface,
            onRefresh: _load,
            child: CustomScrollView(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverAppBar(
                  pinned: true,
                  backgroundColor: NileColors.bgPage,
                  title: Text(
                    'Notifications',
                    style: NileTextStyles.headingMd(),
                  ),
                ),
                ..._buildSlivers(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSlivers() {
    if (_error != null) {
      return [
        SliverFillRemaining(
          child: _CenterMessage(
            icon: Icons.error_outline,
            iconColor: NileColors.error,
            title: 'Something went wrong',
            body: _error!,
          ),
        ),
      ];
    }
    if (_items == null) {
      return [
        SliverFillRemaining(
          child: Center(
            child: CircularProgressIndicator(color: NileColors.volt),
          ),
        ),
      ];
    }
    if (_items!.isEmpty) {
      return [
        const SliverFillRemaining(
          child: _CenterMessage(
            icon: Icons.notifications_none,
            title: 'No notifications yet',
            body: 'Likes, comments, and new followers will appear here.',
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(vertical: NileSpacing.s8),
        sliver: SliverList.separated(
          itemCount: _items!.length + (_hasMore ? 1 : 0),
          separatorBuilder: (_, i) => i >= _items!.length - 1
              ? const SizedBox.shrink()
              : Divider(height: 1, color: NileColors.border, indent: 56),
          itemBuilder: (_, i) {
            if (i >= _items!.length) return const LoadMoreFooter();
            return _NotificationTile(
              notification: _items![i],
              onTap: () => _tap(_items![i]),
            );
          },
        ),
      ),
    ];
  }
}

// ── Tile ──────────────────────────────────────────────────────────────────────

class _NotificationTile extends StatelessWidget {
  final AppNotification notification;
  final VoidCallback onTap;
  const _NotificationTile({required this.notification, required this.onTap});

  String _message() => switch (notification.type) {
    NotificationType.postLike =>
      '@${notification.actorUsername} liked your post',
    NotificationType.postComment =>
      '@${notification.actorUsername} commented on your post',
    NotificationType.follow =>
      '@${notification.actorUsername} started following you',
    NotificationType.eventStarting =>
      '@${notification.actorUsername}’s event starts in 15 minutes',
    NotificationType.eventLive => '@${notification.actorUsername} is live now',
    NotificationType.eventEnded =>
      '@${notification.actorUsername}’s event ended',
    NotificationType.operatorAssigned =>
      '@${notification.actorUsername} added you as a camera operator',
    NotificationType.newMessage =>
      '@${notification.actorUsername} sent you a message',
    NotificationType.messageReaction =>
      '@${notification.actorUsername} reacted to your message',
    NotificationType.replayReady =>
      '@${notification.actorUsername}’s replay is ready to watch',
    NotificationType.soundcheckOpen =>
      '@${notification.actorUsername} opened sound check — join to get ready',
    NotificationType.replayPricePrompt =>
      'Your replay is ready — set a price to publish it',
    NotificationType.feedbackResolved =>
      'Your report has an update — tap to read it',
  };

  IconData _icon() => switch (notification.type) {
    NotificationType.postLike => Icons.favorite,
    NotificationType.postComment => Icons.mode_comment,
    NotificationType.follow => Icons.person_add,
    NotificationType.eventStarting => Icons.live_tv,
    NotificationType.eventLive => Icons.sensors,
    NotificationType.eventEnded => Icons.replay,
    NotificationType.operatorAssigned => Icons.videocam,
    NotificationType.newMessage => Icons.send_rounded,
    NotificationType.messageReaction => Icons.favorite,
    NotificationType.replayReady => Icons.play_circle_fill,
    NotificationType.soundcheckOpen => Icons.tune,
    NotificationType.replayPricePrompt => Icons.sell,
    NotificationType.feedbackResolved => Icons.bug_report,
  };

  Color _iconColor() => switch (notification.type) {
    NotificationType.postLike => NileColors.coral,
    NotificationType.postComment => NileColors.volt,
    NotificationType.follow => NileColors.volt,
    NotificationType.eventStarting => NileColors.coral,
    NotificationType.eventLive => NileColors.coral,
    NotificationType.eventEnded => NileColors.txtSecondary,
    NotificationType.operatorAssigned => NileColors.azure,
    NotificationType.newMessage => NileColors.volt,
    NotificationType.messageReaction => NileColors.coral,
    NotificationType.replayReady => NileColors.volt,
    NotificationType.soundcheckOpen => NileColors.azure,
    NotificationType.replayPricePrompt => NileColors.volt,
    NotificationType.feedbackResolved => NileColors.azure,
  };

  String _timeAgo(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inDays >= 1) return '${d.inDays}d';
    if (d.inHours >= 1) return '${d.inHours}h';
    if (d.inMinutes >= 1) return '${d.inMinutes}m';
    return 'now';
  }

  @override
  Widget build(BuildContext context) {
    final unread = !notification.isRead;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: unread
            ? NileColors.volt.withValues(alpha: 0.04)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16, vertical: NileSpacing.s12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Avatar with type icon badge
            Stack(
              clipBehavior: Clip.none,
              children: [
                GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ProfileScreen(userId: notification.actorId),
                    ),
                  ),
                  child: Hero(
                    tag: 'avatar-${notification.actorId}',
                    child: CircleAvatar(
                      radius: 20,
                      backgroundColor: NileColors.bgRaised,
                      backgroundImage: notification.actorAvatarUrl != null
                          ? nileAvatarImage(notification.actorAvatarUrl!, 20)
                          : null,
                      child: notification.actorAvatarUrl == null
                          ? Text(
                              notification.actorUsername[0].toUpperCase(),
                              style: NileTextStyles.labelSm().copyWith(
                                color: NileColors.txtPrimary,
                                letterSpacing: 0,
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
                Positioned(
                  bottom: -2,
                  right: -2,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: NileColors.bgSurface,
                      shape: BoxShape.circle,
                      border: Border.all(color: NileColors.bgPage, width: 1.5),
                    ),
                    child: Icon(_icon(), size: 10, color: _iconColor()),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            // Message + timestamp
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _message(),
                    style: NileTextStyles.bodyMd().copyWith(
                      color: unread
                          ? NileColors.txtPrimary
                          : NileColors.txtSecondary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _timeAgo(notification.createdAt),
                    style: NileTextStyles.caption(),
                  ),
                ],
              ),
            ),
            if (unread) ...[
              const SizedBox(width: 8),
              CircleAvatar(radius: 4, backgroundColor: NileColors.volt),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Empty / error ─────────────────────────────────────────────────────────────

class _CenterMessage extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String body;
  const _CenterMessage({
    required this.icon,
    this.iconColor,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) =>
      NileEmptyState(icon: icon, iconColor: iconColor, title: title, body: body);
}
