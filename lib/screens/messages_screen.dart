import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/app_error.dart';
import '../services/app_lifecycle.dart';
import '../services/message_service.dart';
import '../services/realtime.dart';
import '../router.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/live_badge.dart';
import '../widgets/nile_desktop.dart';
import '../widgets/nile_glass_nav_bar.dart';
import '../widgets/offline_banner.dart';
import '../widgets/official_badge.dart';
import 'conversation_screen.dart' show ConversationView;

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

  /// Desktop only: the thread the middle pane is showing. Held as an id rather
  /// than the model, so the panes always read the freshest copy of the row —
  /// [_load] runs on every incoming message and replaces every [Conversation].
  String? _selectedId;

  Conversation? get _selected {
    final id = _selectedId;
    if (id == null) return null;
    for (final c in _convs ?? const <Conversation>[]) {
      if (c.id == id) return c;
    }
    return null;
  }

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
    // The chrome hands this route the whole width left of the nav rail
    // (NileAppShell.wantsFullWidth), which is what the panes are for — but a
    // nav rail starts at the iPad mini, and that window has nothing like the
    // width for them. So the split is decided on measured width, not on window
    // class, and everything below it keeps the layout that shipped to beta.
    if (NileBreakpoints.of(context).isCompact) return _buildCompactBody();
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth >= _splitsAt
          ? _buildDesktopBody(constraints.maxWidth)
          : _buildCompactBody(),
    );
  }

  Widget _buildCompactBody() {
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
                          final conv = _filtered[i];
                          await context.push(
                            NileRoutes.dm(conv.otherUserId),
                            extra: conv,
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

  // ── Desktop: list | thread | details ───────────────────────────────────────

  /// Left pane. Wide enough for an avatar, a name and a one-line preview.
  static const double _listWidth = 320;

  /// Right pane. Narrow on purpose — it identifies the person, it isn't a
  /// second copy of their profile.
  static const double _detailsWidth = 300;

  /// Narrower than this and the bubbles stop reading as a conversation.
  static const double _minThreadWidth = 420;

  /// List + thread. Below it the phone layout — list, push to thread — is a
  /// better use of the space than two squeezed columns.
  static const double _splitsAt = _listWidth + 1 + _minThreadWidth;

  /// …plus the details pane. An 11" iPad in landscape lands between the two and
  /// gets the middle layout, which is the point of measuring.
  static const double _detailsAt = _splitsAt + 1 + _detailsWidth;

  Widget _buildDesktopBody(double width) {
    final selected = _selected;
    // Held as a nullable model rather than a bool so the pane below can read it
    // without a second null check.
    final details = selected != null && width >= _detailsAt ? selected : null;
    return SafeArea(
      // The chrome's top bar already sits above this.
      top: false,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: _listWidth, child: _buildListPane()),
          const VerticalDivider(width: 1),
          Expanded(
            child: selected == null
                ? const NileEmptyState(
                    icon: Icons.forum_outlined,
                    title: 'Pick a conversation',
                    body: 'Choose a thread on the left to start reading.',
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Identity lives in the details pane when there's room
                      // for one. This is the fallback for when there isn't,
                      // not a second copy of it.
                      if (details == null) _ThreadHeader(conv: selected),
                      // Keyed on the thread. Switching selection disposes the
                      // old ConversationView — with its three realtime
                      // channels and two timers — and mounts a clean one,
                      // instead of handing a State wired to the previous
                      // conversation a new model.
                      Expanded(
                        child: ConversationView(
                          key: ValueKey(selected.id),
                          conversation: selected,
                        ),
                      ),
                    ],
                  ),
          ),
          // Nothing selected means nothing to detail, so the pane goes rather
          // than standing empty.
          if (details != null) ...[
            const VerticalDivider(width: 1),
            SizedBox(width: _detailsWidth, child: _DetailsPane(conv: details)),
          ],
        ],
      ),
    );
  }

  Widget _buildListPane() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(
          NileSpacing.s16,
          NileSpacing.s16,
          NileSpacing.s16,
          NileSpacing.s8,
        ),
        child: Text('Messages', style: NileTextStyles.headingLg()),
      ),
      if (_convs != null && _convs!.isNotEmpty)
        _SearchField(
          controller: _searchCtrl,
          onChanged: (v) => setState(() => _query = v),
        ),
      const OfflineBanner(),
      Expanded(child: _buildListPaneContent()),
    ],
  );

  Widget _buildListPaneContent() {
    // Unlike compact, a refresh doesn't replace the list with a spinner: here
    // the pane is on screen permanently and _load runs on every incoming
    // message, so it would flicker on each one.
    if (_convs == null) {
      if (_error != null) return NileErrorState(error: _error!, onRetry: _load);
      return Center(child: CircularProgressIndicator(color: NileColors.volt));
    }
    if (_convs!.isEmpty) return const _EmptyView();
    if (_filtered.isEmpty) return const _NoMatchesView();
    return ListView.separated(
      itemCount: _filtered.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, indent: 72, color: NileColors.border),
      itemBuilder: (_, i) {
        final conv = _filtered[i];
        return _ConversationTile(
          conv: conv,
          selected: conv.id == _selectedId,
          // In place, not a push: the thread it would push to is already
          // beside the list.
          onTap: () => setState(() => _selectedId = conv.id),
        );
      },
    );
  }
}

// ── Thread header (desktop, narrow) ───────────────────────────────────────────

/// Who the open thread is with, for the widths where the details pane didn't
/// fit. No back button: the thread is beside the list, not on top of it.
class _ThreadHeader extends StatelessWidget {
  final Conversation conv;
  const _ThreadHeader({required this.conv});

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: NileColors.border)),
    ),
    child: InkWell(
      onTap: () => context.push(NileRoutes.profile(conv.otherUserId)),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NileSpacing.s16,
          vertical: NileSpacing.s8,
        ),
        child: Row(
          children: [
            NileAvatar(
              username: conv.otherUsername,
              avatarUrl: conv.otherAvatarUrl,
              radius: 18,
            ),
            const SizedBox(width: NileSpacing.s8),
            Flexible(
              child: Text(
                '@${conv.otherUsername}',
                style: NileTextStyles.headingSm(),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (conv.otherIsOfficial) ...[
              const SizedBox(width: NileSpacing.s4),
              const OfficialBadge(size: 15),
            ],
            if (conv.isLive) ...[
              const SizedBox(width: NileSpacing.s8),
              const LiveBadge(),
            ],
          ],
        ),
      ),
    ),
  );
}

// ── Details pane (desktop) ────────────────────────────────────────────────────

/// Who you're talking to. Everything shown here already rides along on the
/// conversation row from `get_conversations_for_user`, so opening a thread
/// costs no extra round trip.
class _DetailsPane extends StatelessWidget {
  final Conversation conv;
  const _DetailsPane({required this.conv});

  @override
  Widget build(BuildContext context) {
    final lastAt = conv.lastMessageAt;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(NileSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: NileAvatar(
              username: conv.otherUsername,
              avatarUrl: conv.otherAvatarUrl,
              radius: 40,
            ),
          ),
          const SizedBox(height: NileSpacing.s12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  '@${conv.otherUsername}',
                  style: NileTextStyles.headingSm(),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (conv.otherIsOfficial) ...[
                const SizedBox(width: NileSpacing.s4),
                const OfficialBadge(size: 15),
              ],
            ],
          ),
          if (conv.isLive) ...[
            const SizedBox(height: NileSpacing.s12),
            const Center(child: LiveBadge()),
          ],
          const SizedBox(height: NileSpacing.s16),
          OutlinedButton(
            onPressed: () => context.push(NileRoutes.profile(conv.otherUserId)),
            child: const Text('View profile'),
          ),
          const SizedBox(height: NileSpacing.s24),
          const NileSectionHeader('Details', dense: true),
          _DetailRow(
            label: 'Last message',
            value: lastAt == null ? 'None yet' : _stamp(lastAt.toLocal()),
          ),
          _DetailRow(
            label: 'Conversation started',
            value: _stamp(conv.createdAt.toLocal()),
          ),
          if (conv.unreadCount > 0)
            _DetailRow(label: 'Unread', value: '${conv.unreadCount}'),
        ],
      ),
    );
  }
}

/// "Today · 7:04 PM", else "Aug 3 · 7:04 PM". Takes an already-local DateTime —
/// conversion stays at the call site, as everywhere else on desktop.
String _stamp(DateTime local) {
  final day = nileDayKey(local) == nileDayKey(DateTime.now())
      ? 'Today'
      : '${nileMonthAbbr(local.month)} ${local.day}';
  return '$day · ${nileClock(local)}';
}

/// Label over value — stacked rather than side by side, because a 300 px pane
/// can't fit "Conversation started" and a timestamp on one line.
class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: NileSpacing.s12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: NileTextStyles.caption()),
        const SizedBox(height: NileSpacing.s2),
        Text(value, style: NileTextStyles.bodySm()),
      ],
    ),
  );
}

// ── Conversation tile ─────────────────────────────────────────────────────────

class _ConversationTile extends StatelessWidget {
  final Conversation conv;
  final VoidCallback onTap;

  /// Desktop only: this row is the thread showing in the middle pane. Always
  /// false on compact, where the tile renders exactly as it shipped.
  final bool selected;

  const _ConversationTile({
    required this.conv,
    required this.onTap,
    this.selected = false,
  });

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
    // The open thread is being read, so it never carries an unread treatment —
    // the server-side count only clears on the next list refresh.
    final hasUnread = conv.unreadCount > 0 && !selected;
    final row = InkWell(
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
    // Behind the InkWell, so the tap ripple still reads on the selected row.
    return selected ? ColoredBox(color: NileColors.bgRaised, child: row) : row;
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
