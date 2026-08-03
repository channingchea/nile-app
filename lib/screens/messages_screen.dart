import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/app_error.dart';
import '../services/app_lifecycle.dart';
import '../services/message_service.dart';
import '../services/realtime.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/nile_glass_nav_bar.dart';
import '../widgets/offline_banner.dart';
import '../widgets/official_badge.dart';
import 'conversation_screen.dart';

class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  List<Conversation>? _convs;
  bool _loading = true;
  Object? _error;
  ResilientChannel? _conn;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
    _subscribeRealtime();
    AppLifecycle.instance.state.addListener(_onLifecycle);
  }

  @override
  void dispose() {
    AppLifecycle.instance.state.removeListener(_onLifecycle);
    _conn?.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // Refresh the list when the app returns to the foreground — realtime may have
  // missed changes while suspended.
  void _onLifecycle() {
    if (AppLifecycle.instance.state.value == AppLifecycleState.resumed &&
        mounted) {
      _load();
    }
  }

  /// Conversations filtered by the current search query (by username).
  List<Conversation> get _filtered {
    final all = _convs ?? const [];
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all
        .where((c) => c.otherUsername.toLowerCase().contains(q))
        .toList();
  }

  void _subscribeRealtime() {
    final myId = Supabase.instance.client.auth.currentUser?.id;
    if (myId == null) return;
    _conn = ResilientChannel(
      build: (onStatus) => Supabase.instance.client
          .channel('conversations:$myId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'conversations',
            callback: (_) {
              if (mounted) _load();
            },
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'messages',
            callback: (_) {
              if (mounted) _load();
            },
          )
          // Refresh live-presence dots when any event goes live/ends.
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'events',
            callback: (_) {
              if (mounted) _load();
            },
          )
          .subscribe(onStatus),
      // Backfill anything missed while the channel was dropped.
      onResync: () {
        if (mounted) _load();
      },
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final convs = await MessageService.getConversations();
      if (mounted) setState(() => _convs = convs);
    } catch (e) {
      if (mounted) setState(() => _error = e);
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
          // bottom:false lets the list scroll behind the translucent glass bar.
          bottom: false,
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
                  // Search bar appears only once there are conversations.
                  bottom: (_convs != null && _convs!.isNotEmpty)
                      ? PreferredSize(
                          preferredSize: const Size.fromHeight(56),
                          child: _SearchField(
                            controller: _searchCtrl,
                            onChanged: (v) => setState(() => _query = v),
                          ),
                        )
                      : null,
                ),
                const SliverToBoxAdapter(child: OfflineBanner()),
                if (_loading)
                  SliverFillRemaining(
                    child: Center(
                      child: CircularProgressIndicator(color: NileColors.volt),
                    ),
                  )
                else if (_error != null)
                  SliverFillRemaining(
                    child: NileErrorState(error: _error!, onRetry: _load),
                  )
                else if (_convs == null || _convs!.isEmpty)
                  const SliverFillRemaining(child: _EmptyView())
                else if (_filtered.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: _NoMatchesView(),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.only(
                      bottom: NileGlassNavBar.reservedHeight,
                    ),
                    sliver: SliverList.separated(
                      itemCount: _filtered.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 1,
                        indent: 72,
                        color: NileColors.border,
                      ),
                      itemBuilder: (_, i) => _ConversationTile(
                        conv: _filtered[i],
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  ConversationScreen(conversation: _filtered[i]),
                            ),
                          );
                          _load(); // Refresh unread counts on return.
                        },
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
        padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16, vertical: NileSpacing.s12),
        child: Row(
          children: [
            _Avatar(
              username: conv.otherUsername,
              avatarUrl: conv.otherAvatarUrl,
              isLive: conv.isLive,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // Expanded (not Flexible + Spacer) so the timestamp
                      // sits flush against the right edge of the row.
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                '@${conv.otherUsername}',
                                style: NileTextStyles.bodyMd().copyWith(
                                  fontWeight: hasUnread
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: NileColors.txtPrimary,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (conv.otherIsOfficial) ...[
                              const SizedBox(width: 4),
                              const OfficialBadge(size: 13),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: NileSpacing.s8),
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
                          margin: const EdgeInsets.only(left: NileSpacing.s8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: NileSpacing.s6,
                            vertical: NileSpacing.s2,
                          ),
                          decoration: BoxDecoration(
                            color: NileColors.volt,
                            borderRadius: BorderRadius.circular(
                              NileRadius.pill,
                            ),
                          ),
                          child: Text(
                            conv.unreadCount > 9 ? '9+' : '${conv.unreadCount}',
                            style: NileTextStyles.caption().copyWith(
                              color: NileColors.onVolt,
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
  final bool isLive;
  final double radius;
  const _Avatar({required this.username, this.avatarUrl, this.isLive = false})
    : radius = 24;

  @override
  Widget build(BuildContext context) {
    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: NileColors.bgRaised,
      backgroundImage: avatarUrl != null ? nileAvatarImage(avatarUrl!, radius) : null,
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
    if (!isLive) return avatar;
    // Coral presence dot, ringed in the page color to read against the avatar.
    return Stack(
      children: [
        avatar,
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: NileColors.coral,
              shape: BoxShape.circle,
              border: Border.all(color: NileColors.bgPage, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Search field ──────────────────────────────────────────────────────────────

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const _SearchField({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NileSpacing.s16,
        NileSpacing.s4,
        NileSpacing.s16,
        NileSpacing.s8,
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: NileTextStyles.bodyMd(),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search messages',
          prefixIcon: Icon(
            Icons.search,
            size: 20,
            color: NileColors.txtTertiary,
          ),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  icon: Icon(
                    Icons.close,
                    size: 18,
                    color: NileColors.txtTertiary,
                  ),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: NileSpacing.s12,
            vertical: NileSpacing.s8,
          ),
          fillColor: NileColors.bgRaised,
          filled: true,
          border: OutlineInputBorder(
            borderSide: BorderSide.none,
            borderRadius: BorderRadius.circular(NileRadius.pill),
          ),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide.none,
            borderRadius: BorderRadius.circular(NileRadius.pill),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide.none,
            borderRadius: BorderRadius.circular(NileRadius.pill),
          ),
        ),
      ),
    );
  }
}

// ── Empty / error views ───────────────────────────────────────────────────────

class _NoMatchesView extends StatelessWidget {
  const _NoMatchesView();

  @override
  Widget build(BuildContext context) => const NileEmptyState(
    icon: Icons.search_off,
    title: 'No matches',
    body: 'No conversations match your search.',
  );
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) => const NileEmptyState(
    icon: Icons.send_outlined,
    title: 'No messages yet',
    body: 'Send a message by visiting someone\'s profile.',
  );
}

// ── Public avatar widget for ConversationScreen ───────────────────────────────
// Exported so conversation_screen can reuse without re-importing this file's
// private widgets.
class NileAvatar extends StatelessWidget {
  final String username;
  final String? avatarUrl;
  final double radius;
  const NileAvatar({
    super.key,
    required this.username,
    this.avatarUrl,
    this.radius = 24,
  });

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: NileColors.bgRaised,
      backgroundImage: avatarUrl != null ? nileAvatarImage(avatarUrl!, radius) : null,
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
