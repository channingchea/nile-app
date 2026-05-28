import 'package:flutter/material.dart';
import '../services/notification_service.dart';
import '../services/post_service.dart';
import '../theme.dart';
import 'post_detail_screen.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<AppNotification>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _items = null; _error = null; });
    try {
      final items = await NotificationService.list();
      setState(() => _items = items);
      // Mark all read after listing — fire and forget.
      NotificationService.markAllRead();
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _tap(AppNotification n) async {
    switch (n.type) {
      case NotificationType.postLike:
      case NotificationType.postComment:
        if (n.entityId == null) return;
        final post = await PostService.fetchById(n.entityId!);
        if (!mounted || post == null) return;
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => PostDetailScreen(post: post)),
        );
      case NotificationType.follow:
        // No deep-link target yet — could navigate to actor profile in a future phase.
        break;
    }
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
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverAppBar(
                  pinned: true,
                  backgroundColor: NileColors.bgPage,
                  title: Text('Notifications', style: NileTextStyles.headingMd()),
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
        const SliverFillRemaining(
          child: Center(child: CircularProgressIndicator(color: NileColors.volt)),
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
        padding: const EdgeInsets.symmetric(vertical: 8),
        sliver: SliverList.separated(
          itemCount: _items!.length,
          separatorBuilder: (_, __) => const Divider(
            height: 1,
            color: NileColors.border,
            indent: 56,
          ),
          itemBuilder: (_, i) => _NotificationTile(
            notification: _items![i],
            onTap: () => _tap(_items![i]),
          ),
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
      };

  IconData _icon() => switch (notification.type) {
        NotificationType.postLike => Icons.favorite,
        NotificationType.postComment => Icons.mode_comment,
        NotificationType.follow => Icons.person_add,
      };

  Color _iconColor() => switch (notification.type) {
        NotificationType.postLike => NileColors.coral,
        NotificationType.postComment => NileColors.volt,
        NotificationType.follow => NileColors.txtSecondary,
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
            ? NileColors.volt.withOpacity(0.04)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Avatar with type icon badge
            Stack(
              clipBehavior: Clip.none,
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: NileColors.bgRaised,
                  backgroundImage: notification.actorAvatarUrl != null
                      ? NetworkImage(notification.actorAvatarUrl!)
                      : null,
                  child: notification.actorAvatarUrl == null
                      ? Text(
                          notification.actorUsername[0].toUpperCase(),
                          style: NileTextStyles.labelSm()
                              .copyWith(color: NileColors.txtPrimary, letterSpacing: 0),
                        )
                      : null,
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
                  Text(_timeAgo(notification.createdAt),
                      style: NileTextStyles.caption()),
                ],
              ),
            ),
            if (unread) ...[
              const SizedBox(width: 8),
              const CircleAvatar(
                radius: 4,
                backgroundColor: NileColors.volt,
              ),
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
  final Color iconColor;
  final String title;
  final String body;
  const _CenterMessage({
    required this.icon,
    this.iconColor = NileColors.border,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: iconColor),
            const SizedBox(height: 16),
            Text(title, style: NileTextStyles.headingMd()),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: NileTextStyles.bodyMd()
                  .copyWith(color: NileColors.txtSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
