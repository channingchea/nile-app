import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/follow_service.dart';
import '../services/pagination.dart' show Paged;
import '../services/profile_service.dart';
import '../theme.dart';
import 'profile_screen.dart';
import 'widgets/load_more_footer.dart';

enum FollowListMode { followers, following }

class FollowListScreen extends StatefulWidget {
  final String userId;
  final String displayName;
  final FollowListMode mode;

  const FollowListScreen({
    super.key,
    required this.userId,
    required this.displayName,
    required this.mode,
  });

  @override
  State<FollowListScreen> createState() => _FollowListScreenState();
}

class _FollowListScreenState extends State<FollowListScreen> {
  List<UserProfile>? _users;
  String? _error;

  final _scroll = ScrollController();
  String? _cursor;
  bool _hasMore = false;
  bool _loadingMore = false;

  final Map<String, bool> _followState = {};
  final Set<String> _followLoading = {};

  String get _myId => Supabase.instance.client.auth.currentUser?.id ?? '';

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
    if (_hasMore && !_loadingMore && _users != null) _loadMore();
  }

  Future<Paged<UserProfile>> _fetch(String? cursor) =>
      widget.mode == FollowListMode.followers
          ? FollowService.getFollowers(widget.userId, cursor: cursor)
          : FollowService.getFollowing(widget.userId, cursor: cursor);

  Future<void> _load() async {
    setState(() { _users = null; _error = null; });
    try {
      final page = await _fetch(null);
      await _loadFollowStates(page.items);
      setState(() {
        _users = page.items;
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _loadMore() async {
    if (_cursor == null) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _fetch(_cursor);
      await _loadFollowStates(page.items);
      if (!mounted) return;
      setState(() {
        _users = [...?_users, ...page.items];
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
      });
    } catch (_) {
      // Keep existing; scrolling retries.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _loadFollowStates(List<UserProfile> users) async {
    if (_myId.isEmpty) return;
    await Future.wait(
      users
          .where((u) => u.id != _myId && !_followState.containsKey(u.id))
          .map((u) async {
        final v = await FollowService.isFollowing(u.id);
        if (mounted) _followState[u.id] = v;
      }),
    );
  }

  Future<void> _toggleFollow(UserProfile user) async {
    if (_followLoading.contains(user.id)) return;
    setState(() => _followLoading.add(user.id));

    final was = _followState[user.id] ?? false;
    setState(() => _followState[user.id] = !was);

    try {
      was
          ? await FollowService.unfollow(user.id)
          : await FollowService.follow(user.id);
    } catch (_) {
      setState(() => _followState[user.id] = was);
    } finally {
      if (mounted) setState(() => _followLoading.remove(user.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.mode == FollowListMode.followers
        ? 'Followers'
        : 'Following';

    return Scaffold(
      backgroundColor: NileColors.bgPage,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: NileTextStyles.headingSm()),
            Text('@${widget.displayName}',
                style: NileTextStyles.caption()),
          ],
        ),
      ),
      body: NileMaxWidth(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  size: 48, color: NileColors.error),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: NileTextStyles.bodyMd()
                      .copyWith(color: NileColors.txtSecondary)),
              const SizedBox(height: 20),
              FilledButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    if (_users == null) {
      return const Center(
          child: CircularProgressIndicator(color: NileColors.volt));
    }

    if (_users!.isEmpty) {
      final emptyText = widget.mode == FollowListMode.followers
          ? 'No followers yet.'
          : 'Not following anyone yet.';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.people_outline, size: 56, color: NileColors.border),
              const SizedBox(height: 16),
              Text(emptyText,
                  style: NileTextStyles.bodyMd()
                      .copyWith(color: NileColors.txtSecondary)),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      color: NileColors.volt,
      backgroundColor: NileColors.bgSurface,
      onRefresh: _load,
      child: ListView.separated(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _users!.length + (_hasMore ? 1 : 0),
        separatorBuilder: (_, i) => i >= _users!.length - 1
            ? const SizedBox.shrink()
            : const Divider(height: 1, indent: 72, color: NileColors.border),
        itemBuilder: (_, i) {
          if (i >= _users!.length) return const LoadMoreFooter();
          final user = _users![i];
          final isMe = user.id == _myId;
          return _UserTile(
            user: user,
            isMe: isMe,
            isFollowing: _followState[user.id] ?? false,
            isLoading: _followLoading.contains(user.id),
            onFollowTap: isMe ? null : () => _toggleFollow(user),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ProfileScreen(userId: user.id),
              ),
            ).then((_) {
              if (mounted && !isMe) {
                _followState.remove(user.id);
                FollowService.isFollowing(user.id)
                    .then((v) { if (mounted) setState(() => _followState[user.id] = v); });
              }
            }),
          );
        },
      ),
    );
  }
}

// ── Tile ──────────────────────────────────────────────────────────────────────

class _UserTile extends StatelessWidget {
  final UserProfile user;
  final bool isMe;
  final bool isFollowing;
  final bool isLoading;
  final VoidCallback? onFollowTap;
  final VoidCallback onTap;

  const _UserTile({
    required this.user,
    required this.isMe,
    required this.isFollowing,
    required this.isLoading,
    required this.onFollowTap,
    required this.onTap,
  });

  String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return n.toString();
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: NileColors.bgRaised,
              backgroundImage:
                  user.avatarUrl != null ? NetworkImage(user.avatarUrl!) : null,
              child: user.avatarUrl == null
                  ? Text(user.username[0].toUpperCase(),
                      style: NileTextStyles.headingSm()
                          .copyWith(color: NileColors.txtSecondary))
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(user.displayName, style: NileTextStyles.labelMd()),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text('@${user.username}', style: NileTextStyles.bodySm()),
                      if (user.followerCount > 0) ...[
                        Text(' · ',
                            style: NileTextStyles.bodySm()
                                .copyWith(color: NileColors.txtTertiary)),
                        Text('${_fmt(user.followerCount)} followers',
                            style: NileTextStyles.caption()),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (!isMe) ...[
              const SizedBox(width: 12),
              _FollowButton(
                isFollowing: isFollowing,
                isLoading: isLoading,
                onTap: onFollowTap!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Follow button ─────────────────────────────────────────────────────────────

class _FollowButton extends StatelessWidget {
  final bool isFollowing;
  final bool isLoading;
  final VoidCallback onTap;

  const _FollowButton({
    required this.isFollowing,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const spinner = SizedBox(
      width: 14, height: 14,
      child: CircularProgressIndicator(strokeWidth: 2),
    );

    if (isFollowing) {
      return OutlinedButton(
        onPressed: isLoading ? null : onTap,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          minimumSize: const Size(90, 34),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: isLoading
            ? spinner
            : Text('Following',
                style: NileTextStyles.labelSm()
                    .copyWith(color: NileColors.txtPrimary, letterSpacing: 0)),
      );
    }

    return FilledButton(
      onPressed: isLoading ? null : onTap,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        minimumSize: const Size(90, 34),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: isLoading
          ? const SizedBox(
              width: 14, height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: NileColors.bgPage))
          : Text('Follow',
              style: NileTextStyles.labelSm()
                  .copyWith(color: NileColors.bgPage, letterSpacing: 0)),
    );
  }
}
