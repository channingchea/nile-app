import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/message_service.dart';
import '../theme.dart';
import 'conversation_screen.dart';

class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  List<Conversation>? _convs;
  bool _loading = true;
  String? _error;
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _load();
    _subscribeRealtime();
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }

  void _subscribeRealtime() {
    final myId = Supabase.instance.client.auth.currentUser?.id;
    if (myId == null) return;
    _channel = Supabase.instance.client
        .channel('conversations:$myId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'conversations',
          callback: (_) { if (mounted) _load(); },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          callback: (_) { if (mounted) _load(); },
        )
        .subscribe();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final convs = await MessageService.getConversations();
      if (mounted) setState(() => _convs = convs);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      body: NileMaxWidth(
        child: SafeArea(
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
                  title: Text('Messages', style: NileTextStyles.headingLg()),
                ),
                if (_loading)
                  const SliverFillRemaining(
                    child: Center(child: CircularProgressIndicator(color: NileColors.volt)),
                  )
                else if (_error != null)
                  SliverFillRemaining(
                    child: _ErrorView(message: _error!, onRetry: _load),
                  )
                else if (_convs == null || _convs!.isEmpty)
                  const SliverFillRemaining(child: _EmptyView())
                else
                  SliverList.separated(
                    itemCount: _convs!.length,
                    separatorBuilder: (_, __) => const Divider(
                      height: 1,
                      indent: 72,
                      color: NileColors.border,
                    ),
                    itemBuilder: (_, i) => _ConversationTile(
                      conv: _convs![i],
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                ConversationScreen(conversation: _convs![i]),
                          ),
                        );
                        _load(); // Refresh unread counts on return.
                      },
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

// ── Conversation tile ─────────────────────────────────────────────────────────

class _ConversationTile extends StatelessWidget {
  final Conversation conv;
  final VoidCallback onTap;
  const _ConversationTile({required this.conv, required this.onTap});

  String _timeAgo(DateTime? dt) {
    if (dt == null) return '';
    final d = DateTime.now().difference(dt);
    if (d.inDays > 6) return '${(d.inDays / 7).floor()}w';
    if (d.inDays > 0) return '${d.inDays}d';
    if (d.inHours > 0) return '${d.inHours}h';
    if (d.inMinutes > 0) return '${d.inMinutes}m';
    return 'now';
  }

  @override
  Widget build(BuildContext context) {
    final hasUnread = conv.unreadCount > 0;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            _Avatar(username: conv.otherUsername, avatarUrl: conv.otherAvatarUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '@${conv.otherUsername}',
                          style: NileTextStyles.bodyMd().copyWith(
                            fontWeight:
                                hasUnread ? FontWeight.w600 : FontWeight.w400,
                            color: hasUnread
                                ? NileColors.txtPrimary
                                : NileColors.txtPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        _timeAgo(conv.lastMessageAt),
                        style: NileTextStyles.caption(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          conv.lastMessageContent ?? 'No messages yet',
                          style: NileTextStyles.bodySm().copyWith(
                            color: hasUnread
                                ? NileColors.txtSecondary
                                : NileColors.txtTertiary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (hasUnread)
                        Container(
                          margin: const EdgeInsets.only(left: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: NileColors.volt,
                            borderRadius:
                                BorderRadius.circular(NileRadius.pill),
                          ),
                          child: Text(
                            conv.unreadCount > 9
                                ? '9+'
                                : '${conv.unreadCount}',
                            style: NileTextStyles.caption().copyWith(
                              color: NileColors.bgPage,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Shared avatar widget ──────────────────────────────────────────────────────

class _Avatar extends StatelessWidget {
  final String username;
  final String? avatarUrl;
  final double radius;
  const _Avatar({required this.username, this.avatarUrl, this.radius = 24});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: NileColors.bgRaised,
      backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl!) : null,
      child: avatarUrl == null
          ? Text(
              username.isNotEmpty ? username[0].toUpperCase() : '?',
              style: NileTextStyles.bodyMd().copyWith(
                color: NileColors.txtPrimary,
                fontWeight: FontWeight.w600,
              ),
            )
          : null,
    );
  }
}

// ── Empty / error views ───────────────────────────────────────────────────────

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.send_outlined, size: 56, color: NileColors.border),
            const SizedBox(height: 16),
            Text('No messages yet', style: NileTextStyles.headingMd()),
            const SizedBox(height: 8),
            Text(
              'Send a message by visiting someone\'s profile.',
              textAlign: TextAlign.center,
              style:
                  NileTextStyles.bodyMd().copyWith(color: NileColors.txtSecondary),
            ),
          ],
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
            const Icon(Icons.error_outline, size: 56, color: NileColors.error),
            const SizedBox(height: 16),
            Text('Something went wrong', style: NileTextStyles.headingMd()),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: NileTextStyles.bodyMd()
                  .copyWith(color: NileColors.txtSecondary),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

// ── Public avatar widget for ConversationScreen ───────────────────────────────
// Exported so conversation_screen can reuse without re-importing this file's
// private widgets.
class NileAvatar extends StatelessWidget {
  final String username;
  final String? avatarUrl;
  final double radius;
  const NileAvatar(
      {super.key,
      required this.username,
      this.avatarUrl,
      this.radius = 24});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: NileColors.bgRaised,
      backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl!) : null,
      child: avatarUrl == null
          ? Text(
              username.isNotEmpty ? username[0].toUpperCase() : '?',
              style: NileTextStyles.bodyMd().copyWith(
                color: NileColors.txtPrimary,
                fontWeight: FontWeight.w600,
              ),
            )
          : null,
    );
  }
}
