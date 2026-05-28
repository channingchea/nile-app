import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/follow_service.dart';
import '../services/like_service.dart';
import '../services/post_service.dart';
import '../services/profile_service.dart';
import '../services/search_service.dart';
import '../theme.dart';
import 'post_detail_screen.dart';
import 'profile_screen.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;

  List<UserProfile>? _results;
  List<Post>? _latestPosts;
  bool _isSearching = false;
  bool _loading = false;
  String? _error;

  // Track optimistic follow state: userId → isFollowing
  final Map<String, bool> _followState = {};
  final Set<String> _followLoading = {};

  @override
  void initState() {
    super.initState();
    _loadSuggested();
    _controller.addListener(_onQueryChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadSuggested() async {
    setState(() {
      _loading = true;
      _error = null;
      _isSearching = false;
    });
    try {
      final users = await SearchService.suggestedUsers();
      await _loadFollowStates(users);
      // Fetch latest posts in parallel — non-fatal if it fails.
      PostService.getDiscover(limit: 20).then((posts) async {
        final hydrated = await PostService.hydrateLikes(posts);
        if (mounted) setState(() => _latestPosts = hydrated);
      }).catchError((_) {});
      setState(() => _results = users);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  void _onQueryChanged() {
    final q = _controller.text.trim();
    if (q.isEmpty) {
      _debounce?.cancel();
      _loadSuggested();
      return;
    }
    setState(() => _isSearching = true);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(q));
  }

  Future<void> _search(String q) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final users = await SearchService.searchUsers(q);
      await _loadFollowStates(users);
      setState(() => _results = users);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _loadFollowStates(List<UserProfile> users) async {
    final myId = Supabase.instance.client.auth.currentUser?.id;
    if (myId == null) return;
    // Only fetch states we haven't loaded yet
    final unknown = users.where((u) => !_followState.containsKey(u.id)).toList();
    if (unknown.isEmpty) return;
    await Future.wait(unknown.map((u) async {
      final following = await FollowService.isFollowing(u.id);
      if (mounted) _followState[u.id] = following;
    }));
  }

  Future<void> _toggleLike(int index) async {
    if (_latestPosts == null) return;
    final post = _latestPosts![index];
    final wasLiked = post.likedByMe;
    final delta = wasLiked ? -1 : 1;
    setState(() {
      _latestPosts![index] = post.copyWith(
        likedByMe: !wasLiked,
        likeCount: (post.likeCount + delta).clamp(0, 1 << 30),
      );
    });
    try {
      wasLiked
          ? await LikeService.unlikePost(post.id)
          : await LikeService.likePost(post.id);
    } catch (_) {
      if (mounted) setState(() => _latestPosts![index] = post);
    }
  }

  Future<void> _toggleFollow(UserProfile user) async {
    if (_followLoading.contains(user.id)) return;
    setState(() => _followLoading.add(user.id));

    final wasFollowing = _followState[user.id] ?? false;
    setState(() => _followState[user.id] = !wasFollowing);

    try {
      if (wasFollowing) {
        await FollowService.unfollow(user.id);
      } else {
        await FollowService.follow(user.id);
      }
    } catch (_) {
      setState(() => _followState[user.id] = wasFollowing);
    } finally {
      if (mounted) setState(() => _followLoading.remove(user.id));
    }
  }

  void _clearSearch() {
    _controller.clear();
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _buildAppBar(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildAppBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              style: NileTextStyles.bodyMd(),
              decoration: InputDecoration(
                hintText: 'Search people…',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: _clearSearch,
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _results == null) {
      return const Center(
        child: CircularProgressIndicator(color: NileColors.volt),
      );
    }

    if (_error != null) {
      return _ErrorState(message: _error!, onRetry: _isSearching
          ? () => _search(_controller.text.trim())
          : _loadSuggested);
    }

    final users = _results ?? [];

    if (users.isEmpty && !_loading) {
      return _EmptyState(isSearch: _isSearching);
    }

    return RefreshIndicator(
      color: NileColors.volt,
      backgroundColor: NileColors.bgSurface,
      onRefresh: _isSearching
          ? () => _search(_controller.text.trim())
          : _loadSuggested,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.only(top: 4),
            sliver: SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  _isSearching ? 'Results' : 'Suggested creators',
                  style: NileTextStyles.labelSm(),
                ),
              ),
            ),
          ),
          SliverList.separated(
            itemCount: users.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, indent: 72, color: NileColors.border),
            itemBuilder: (_, i) => _UserTile(
              user: users[i],
              isFollowing: _followState[users[i].id] ?? false,
              isLoading: _followLoading.contains(users[i].id),
              onFollowTap: () => _toggleFollow(users[i]),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ProfileScreen(userId: users[i].id),
                ),
              ).then((_) {
                // Refresh follow state when returning from profile
                if (mounted) {
                  _followState.remove(users[i].id);
                  setState(() {});
                  FollowService.isFollowing(users[i].id).then((v) {
                    if (mounted) setState(() => _followState[users[i].id] = v);
                  });
                }
              }),
            ),
          ),
          if (!_isSearching && (_latestPosts?.isNotEmpty ?? false)) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                child: Text('Latest posts',
                    style: NileTextStyles.labelSm()),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              sliver: SliverList.separated(
                itemCount: _latestPosts!.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (_, i) => _DiscoverPostCard(
                  post: _latestPosts![i],
                  onTap: () async {
                    final updated = await Navigator.push<Post>(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            PostDetailScreen(post: _latestPosts![i]),
                      ),
                    );
                    if (updated != null && mounted) {
                      setState(() => _latestPosts![i] = updated);
                    }
                  },
                  onLikeToggle: () => _toggleLike(i),
                ),
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

// ── User tile ─────────────────────────────────────────────────────────────────

class _UserTile extends StatelessWidget {
  final UserProfile user;
  final bool isFollowing;
  final bool isLoading;
  final VoidCallback onFollowTap;
  final VoidCallback onTap;

  const _UserTile({
    required this.user,
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
            // Avatar
            CircleAvatar(
              radius: 24,
              backgroundColor: NileColors.bgRaised,
              backgroundImage: user.avatarUrl != null
                  ? NetworkImage(user.avatarUrl!)
                  : null,
              child: user.avatarUrl == null
                  ? Text(
                      user.username[0].toUpperCase(),
                      style: NileTextStyles.headingSm()
                          .copyWith(color: NileColors.txtSecondary),
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            // Name + stats
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(user.displayName, style: NileTextStyles.labelMd()),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text('@${user.username}',
                          style: NileTextStyles.bodySm()),
                      if (user.followerCount > 0) ...[
                        Text(' · ',
                            style: NileTextStyles.bodySm()
                                .copyWith(color: NileColors.txtTertiary)),
                        Text(
                          '${_fmt(user.followerCount)} followers',
                          style: NileTextStyles.caption(),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Follow / Following button
            _FollowButton(
              isFollowing: isFollowing,
              isLoading: isLoading,
              onTap: onFollowTap,
            ),
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
    const spinnerSize = SizedBox(
      width: 14,
      height: 14,
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
            ? spinnerSize
            : Text('Following', style: NileTextStyles.labelSm().copyWith(
                color: NileColors.txtPrimary, letterSpacing: 0)),
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
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: NileColors.bgPage),
            )
          : Text('Follow', style: NileTextStyles.labelSm()
              .copyWith(color: NileColors.bgPage, letterSpacing: 0)),
    );
  }
}

// ── Discover post card ────────────────────────────────────────────────────────

class _DiscoverPostCard extends StatelessWidget {
  final Post post;
  final VoidCallback onTap;
  final VoidCallback? onLikeToggle;
  const _DiscoverPostCard(
      {required this.post, required this.onTap, this.onLikeToggle});

  String _timeAgo(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inDays > 0) return '${d.inDays}d ago';
    if (d.inHours > 0) return '${d.inHours}h ago';
    if (d.inMinutes > 0) return '${d.inMinutes}m ago';
    return 'just now';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: NileColors.bgSurface,
      borderRadius: BorderRadius.circular(NileRadius.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: NileColors.bgRaised,
                    backgroundImage: post.authorAvatarUrl != null
                        ? NetworkImage(post.authorAvatarUrl!)
                        : null,
                    child: post.authorAvatarUrl == null
                        ? Text(
                            post.authorUsername[0].toUpperCase(),
                            style: NileTextStyles.caption(),
                          )
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('@${post.authorUsername}',
                        style: NileTextStyles.bodySm(),
                        overflow: TextOverflow.ellipsis),
                  ),
                  Text(_timeAgo(post.createdAt),
                      style: NileTextStyles.caption()),
                ],
              ),
              if (post.hasCaption) ...[
                const SizedBox(height: 8),
                Text(
                  post.caption!.trim(),
                  style: NileTextStyles.bodyMd(),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (post.hasImage) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(NileRadius.sm),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Image.network(
                      post.imageUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: NileColors.bgRaised,
                        child: const Center(
                          child: Icon(Icons.broken_image,
                              color: NileColors.border),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              if (onLikeToggle != null) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    InkWell(
                      onTap: onLikeToggle,
                      borderRadius: BorderRadius.circular(NileRadius.sm),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                                post.likedByMe
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                size: 18,
                                color: post.likedByMe
                                    ? NileColors.coral
                                    : NileColors.txtSecondary),
                            const SizedBox(width: 5),
                            Text('${post.likeCount}',
                                style: NileTextStyles.bodySm().copyWith(
                                    color: post.likedByMe
                                        ? NileColors.coral
                                        : NileColors.txtSecondary)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    const Icon(Icons.mode_comment_outlined,
                        size: 18, color: NileColors.txtSecondary),
                    const SizedBox(width: 5),
                    Text('${post.commentCount}',
                        style: NileTextStyles.bodySm()
                            .copyWith(color: NileColors.txtSecondary)),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Empty / error states ──────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final bool isSearch;
  const _EmptyState({required this.isSearch});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSearch ? Icons.search_off : Icons.people_outline,
              size: 56,
              color: NileColors.border,
            ),
            const SizedBox(height: 16),
            Text(
              isSearch ? 'No results' : 'No creators yet',
              style: NileTextStyles.headingMd(),
            ),
            const SizedBox(height: 8),
            Text(
              isSearch
                  ? 'Try a different username or name.'
                  : 'Be the first to go live.',
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

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

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
              style:
                  NileTextStyles.bodyMd().copyWith(color: NileColors.txtSecondary),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
