import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/event_service.dart';
import '../services/follow_service.dart';
import '../services/like_service.dart';
import '../services/pagination.dart' show Paged;
import '../services/post_service.dart';
import '../services/profile_service.dart';
import '../services/search_service.dart';
import '../theme.dart';
import '../widgets/event_cover_pill.dart';
import '../widgets/event_link_card.dart';
import '../widgets/like_button.dart';
import '../widgets/nile_glass_nav_bar.dart';
import '../widgets/nile_skeleton.dart';
import '../widgets/pressable.dart';
import 'event_detail_screen.dart';
import 'post_detail_screen.dart';
import 'profile_screen.dart';
import 'viewer_screen.dart';
import 'widgets/load_more_footer.dart';

enum _Tab { posts, events, people }

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen>
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  late final TabController _tabs;
  Timer? _debounce;

  // Per-tab results. null = not loaded yet.
  List<Post>? _posts;
  List<Event>? _events;
  List<UserProfile>? _people;

  // "From your network" rails (follow-graph recs). Only shown when not searching.
  List<Post> _recPosts = [];
  List<Event> _recEvents = [];

  bool _isSearching = false;
  final Map<_Tab, bool> _loading = {
    _Tab.posts: false,
    _Tab.events: false,
    _Tab.people: false,
  };
  final Map<_Tab, String?> _error = {};

  // Pagination state, per tab.
  final Map<_Tab, String?> _cursor = {};
  final Map<_Tab, bool> _hasMore = {
    _Tab.posts: false,
    _Tab.events: false,
    _Tab.people: false,
  };
  final Map<_Tab, bool> _loadingMore = {
    _Tab.posts: false,
    _Tab.events: false,
    _Tab.people: false,
  };
  final Map<_Tab, ScrollController> _scroll = {};

  // Optimistic follow + like state.
  final Map<String, bool> _followState = {};
  final Set<String> _followLoading = {};

  _Tab get _active => _Tab.values[_tabs.index];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this)..addListener(_onTabChanged);
    for (final t in _Tab.values) {
      _scroll[t] = ScrollController()..addListener(() => _onScroll(t));
    }
    _controller.addListener(_onQueryChanged);
    _loadActive();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tabs.dispose();
    _controller.dispose();
    _focusNode.dispose();
    for (final c in _scroll.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onScroll(_Tab tab) {
    final c = _scroll[tab]!;
    if (!c.hasClients) return;
    if (c.position.pixels < c.position.maxScrollExtent - 400) return;
    if (_hasMore[tab]! && !_loadingMore[tab]! && !_loading[tab]!) {
      _loadMore(tab);
    }
  }

  void _onTabChanged() {
    if (_tabs.indexIsChanging) return;
    setState(() {});
    _loadActive();
  }

  void _onQueryChanged() {
    final q = _controller.text.trim();
    setState(() => _isSearching = q.isNotEmpty);
    _debounce?.cancel();
    if (q.isEmpty) {
      // Reset search results; reload suggested for the active tab.
      _posts = _events = null;
      _people = null;
      _loadActive();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), _loadActive);
  }

  /// Loads (or searches) content for the current tab based on query state.
  Future<void> _loadActive() {
    switch (_active) {
      case _Tab.posts:
        return _loadPosts();
      case _Tab.events:
        return _loadEvents();
      case _Tab.people:
        return _loadPeople();
    }
  }

  Future<Paged<Post>> _fetchPosts(String q, String? cursor) => q.isEmpty
      ? PostService.getDiscover(cursor: cursor)
      : SearchService.searchPosts(q, cursor: cursor);

  Future<Paged<Event>> _fetchEvents(String q, String? cursor) => q.isEmpty
      ? SearchService.discoverEvents(cursor: cursor)
      : SearchService.searchEvents(q, cursor: cursor);

  Future<Paged<UserProfile>> _fetchPeople(String q, String? cursor) => q.isEmpty
      ? SearchService.suggestedUsers(cursor: cursor)
      : SearchService.searchUsers(q, cursor: cursor);

  Future<void> _loadPosts() async {
    final q = _controller.text.trim();
    setState(() {
      _loading[_Tab.posts] = true;
      _error[_Tab.posts] = null;
    });
    try {
      final results = await Future.wait([
        _fetchPosts(q, null),
        q.isEmpty ? SearchService.recommendedPosts() : Future.value(<Post>[]),
      ]);
      final page = results[0] as Paged<Post>;
      final posts = await PostService.hydrateLikes(page.items);
      final recs = await PostService.hydrateLikes(results[1] as List<Post>);
      if (mounted) {
        setState(() {
          _posts = posts;
          _recPosts = recs;
          _cursor[_Tab.posts] = page.nextCursor;
          _hasMore[_Tab.posts] = page.hasMore;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error[_Tab.posts] = e.toString());
    } finally {
      if (mounted) setState(() => _loading[_Tab.posts] = false);
    }
  }

  Future<void> _loadEvents() async {
    final q = _controller.text.trim();
    setState(() {
      _loading[_Tab.events] = true;
      _error[_Tab.events] = null;
    });
    try {
      final results = await Future.wait([
        _fetchEvents(q, null),
        q.isEmpty ? SearchService.recommendedEvents() : Future.value(<Event>[]),
      ]);
      final page = results[0] as Paged<Event>;
      final events = await EventService.hydrateLikes(page.items);
      final recs = await EventService.hydrateLikes(results[1] as List<Event>);
      if (mounted) {
        setState(() {
          _events = events;
          _recEvents = recs;
          _cursor[_Tab.events] = page.nextCursor;
          _hasMore[_Tab.events] = page.hasMore;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error[_Tab.events] = e.toString());
    } finally {
      if (mounted) setState(() => _loading[_Tab.events] = false);
    }
  }

  Future<void> _loadPeople() async {
    final q = _controller.text.trim();
    setState(() {
      _loading[_Tab.people] = true;
      _error[_Tab.people] = null;
    });
    try {
      final page = await _fetchPeople(q, null);
      await _loadFollowStates(page.items);
      if (mounted) {
        setState(() {
          _people = page.items;
          _cursor[_Tab.people] = page.nextCursor;
          _hasMore[_Tab.people] = page.hasMore;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error[_Tab.people] = e.toString());
    } finally {
      if (mounted) setState(() => _loading[_Tab.people] = false);
    }
  }

  Future<void> _loadMore(_Tab tab) async {
    final cursor = _cursor[tab];
    if (cursor == null) return;
    setState(() => _loadingMore[tab] = true);
    final q = _controller.text.trim();
    try {
      switch (tab) {
        case _Tab.posts:
          final page = await _fetchPosts(q, cursor);
          final more = await PostService.hydrateLikes(page.items);
          if (mounted) {
            setState(() {
              _posts = [...?_posts, ...more];
              _cursor[tab] = page.nextCursor;
              _hasMore[tab] = page.hasMore;
            });
          }
        case _Tab.events:
          final page = await _fetchEvents(q, cursor);
          final more = await EventService.hydrateLikes(page.items);
          if (mounted) {
            setState(() {
              _events = [...?_events, ...more];
              _cursor[tab] = page.nextCursor;
              _hasMore[tab] = page.hasMore;
            });
          }
        case _Tab.people:
          final page = await _fetchPeople(q, cursor);
          await _loadFollowStates(page.items);
          if (mounted) {
            setState(() {
              _people = [...?_people, ...page.items];
              _cursor[tab] = page.nextCursor;
              _hasMore[tab] = page.hasMore;
            });
          }
      }
    } catch (_) {
      // Leave existing items; user can scroll again to retry.
    } finally {
      if (mounted) setState(() => _loadingMore[tab] = false);
    }
  }

  Future<void> _loadFollowStates(List<UserProfile> users) async {
    final myId = Supabase.instance.client.auth.currentUser?.id;
    if (myId == null) return;
    final unknown = users
        .where((u) => !_followState.containsKey(u.id))
        .toList();
    if (unknown.isEmpty) return;
    await Future.wait(
      unknown.map((u) async {
        final following = await FollowService.isFollowing(u.id);
        if (mounted) _followState[u.id] = following;
      }),
    );
  }

  Future<void> _togglePostLike(int index) async {
    if (_posts == null) return;
    final post = _posts![index];
    final wasLiked = post.likedByMe;
    setState(
      () => _posts![index] = post.copyWith(
        likedByMe: !wasLiked,
        likeCount: (post.likeCount + (wasLiked ? -1 : 1)).clamp(0, 1 << 30),
      ),
    );
    try {
      wasLiked
          ? await LikeService.unlikePost(post.id)
          : await LikeService.likePost(post.id);
    } catch (_) {
      if (mounted) setState(() => _posts![index] = post);
    }
  }

  Future<void> _toggleEventLike(int index) async {
    if (_events == null) return;
    final ev = _events![index];
    final wasLiked = ev.likedByMe;
    setState(
      () => _events![index] = ev.copyWith(
        likedByMe: !wasLiked,
        likeCount: (ev.likeCount + (wasLiked ? -1 : 1)).clamp(0, 1 << 30),
      ),
    );
    try {
      wasLiked
          ? await LikeService.unlikeEvent(ev.id)
          : await LikeService.likeEvent(ev.id);
    } catch (_) {
      if (mounted) setState(() => _events![index] = ev);
    }
  }

  Future<void> _toggleFollow(UserProfile user) async {
    if (_followLoading.contains(user.id)) return;
    setState(() => _followLoading.add(user.id));
    final wasFollowing = _followState[user.id] ?? false;
    setState(() => _followState[user.id] = !wasFollowing);
    try {
      wasFollowing
          ? await FollowService.unfollow(user.id)
          : await FollowService.follow(user.id);
    } catch (_) {
      setState(() => _followState[user.id] = wasFollowing);
    } finally {
      if (mounted) setState(() => _followLoading.remove(user.id));
    }
  }

  void _openEvent(Event ev) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ev.isLive
          ? ViewerScreen(initialEventId: ev.liveKitEventId)
          : EventDetailScreen(event: ev),
    ),
  );

  Future<void> _openRecPost(int j) async {
    final updated = await Navigator.push<Post>(
      context,
      MaterialPageRoute(builder: (_) => PostDetailScreen(post: _recPosts[j])),
    );
    if (updated != null && mounted) setState(() => _recPosts[j] = updated);
  }

  void _clearSearch() {
    _controller.clear();
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    // bottom:false lets content scroll behind the translucent glass nav bar.
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          _buildSearchBar(),
          _buildTabBar(),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _fade(_buildPostsTab()),
                _fade(_buildEventsTab()),
                _fade(_buildPeopleTab()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s12, NileSpacing.s16, NileSpacing.s8),
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        style: NileTextStyles.bodyMd(),
        decoration: InputDecoration(
          hintText: 'Search posts, events, people…',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _controller.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: _clearSearch,
                )
              : null,
          contentPadding: const EdgeInsets.symmetric(vertical: NileSpacing.s12),
        ),
      ),
    );
  }

  Widget _buildTabBar() {
    return TabBar(
      controller: _tabs,
      indicatorColor: NileColors.volt,
      indicatorSize: TabBarIndicatorSize.label,
      labelColor: NileColors.txtPrimary,
      unselectedLabelColor: NileColors.txtTertiary,
      labelStyle: NileTextStyles.labelSm().copyWith(letterSpacing: 0),
      unselectedLabelStyle: NileTextStyles.labelSm().copyWith(letterSpacing: 0),
      dividerColor: NileColors.border,
      tabs: const [
        Tab(text: 'Posts'),
        Tab(text: 'Events'),
        Tab(text: 'People'),
      ],
    );
  }

  // ── Tabs ──────────────────────────────────────────────────────────────────

  /// Cross-fades tab body state changes (skeleton → content → empty/error).
  Widget _fade(Widget child) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 250),
    child: child,
  );

  Widget _buildPostsTab() {
    if (_error[_Tab.posts] != null) {
      return _ErrorState(message: _error[_Tab.posts]!, onRetry: _loadPosts);
    }
    if (_posts == null && _loading[_Tab.posts]!) return const _Loading();
    final posts = _posts ?? [];
    if (posts.isEmpty) {
      return _EmptyState(
        icon: _isSearching ? Icons.search_off : Icons.article_outlined,
        title: _isSearching ? 'No posts found' : 'No posts yet',
        subtitle: _isSearching ? 'Try a different search.' : 'Check back soon.',
      );
    }
    final showRail = !_isSearching && _recPosts.isNotEmpty;
    final header = showRail ? 1 : 0;
    return RefreshIndicator(
      color: NileColors.volt,
      backgroundColor: NileColors.bgSurface,
      onRefresh: _loadPosts,
      child: ListView.separated(
        controller: _scroll[_Tab.posts],
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s12, NileSpacing.s16, NileGlassNavBar.reservedHeight + NileSpacing.s24),
        itemCount: header + posts.length + (_hasMore[_Tab.posts]! ? 1 : 0),
        separatorBuilder: (_, i) =>
            SizedBox(height: showRail && i == 0 ? 20 : 12),
        itemBuilder: (_, i) {
          if (showRail && i == 0) {
            return _NetworkRail(
              children: [
                for (var j = 0; j < _recPosts.length; j++)
                  _RecPostCard(
                    post: _recPosts[j],
                    onTap: () => _openRecPost(j),
                  ),
              ],
            );
          }
          final idx = i - header;
          if (idx >= posts.length) return const LoadMoreFooter();
          return _DiscoverPostCard(
            post: posts[idx],
            onLikeToggle: () => _togglePostLike(idx),
            onTap: () async {
              final updated = await Navigator.push<Post>(
                context,
                MaterialPageRoute(
                  builder: (_) => PostDetailScreen(post: posts[idx]),
                ),
              );
              if (updated != null && mounted) {
                setState(() => _posts![idx] = updated);
              }
            },
          );
        },
      ),
    );
  }

  Widget _buildEventsTab() {
    if (_error[_Tab.events] != null) {
      return _ErrorState(message: _error[_Tab.events]!, onRetry: _loadEvents);
    }
    if (_events == null && _loading[_Tab.events]!) return const _Loading();
    final events = _events ?? [];
    if (events.isEmpty) {
      return _EmptyState(
        icon: _isSearching ? Icons.search_off : Icons.event_outlined,
        title: _isSearching ? 'No events found' : 'No events yet',
        subtitle: _isSearching
            ? 'Try a different search.'
            : 'Be the first to go live.',
      );
    }
    final showRail = !_isSearching && _recEvents.isNotEmpty;
    final header = showRail ? 1 : 0;
    // Rail cards own the Hero for their events; main-list duplicates disable
    // theirs (two live Heroes with one tag abort every flight).
    final railIds = showRail ? {for (final e in _recEvents) e.id} : <String>{};
    return RefreshIndicator(
      color: NileColors.volt,
      backgroundColor: NileColors.bgSurface,
      onRefresh: _loadEvents,
      child: ListView.separated(
        controller: _scroll[_Tab.events],
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s12, NileSpacing.s16, NileGlassNavBar.reservedHeight + NileSpacing.s24),
        itemCount: header + events.length + (_hasMore[_Tab.events]! ? 1 : 0),
        separatorBuilder: (_, i) =>
            SizedBox(height: showRail && i == 0 ? 20 : 12),
        itemBuilder: (_, i) {
          if (showRail && i == 0) {
            return _NetworkRail(
              children: [
                for (final ev in _recEvents)
                  _RecEventCard(event: ev, onTap: () => _openEvent(ev)),
              ],
            );
          }
          final idx = i - header;
          if (idx >= events.length) return const LoadMoreFooter();
          return _DiscoverEventCard(
            event: events[idx],
            hero: !railIds.contains(events[idx].id),
            onLikeToggle: () => _toggleEventLike(idx),
            onTap: () => _openEvent(events[idx]),
          );
        },
      ),
    );
  }

  Widget _buildPeopleTab() {
    if (_error[_Tab.people] != null) {
      return _ErrorState(message: _error[_Tab.people]!, onRetry: _loadPeople);
    }
    if (_people == null && _loading[_Tab.people]!) return const _Loading();
    final users = _people ?? [];
    if (users.isEmpty) {
      return _EmptyState(
        icon: _isSearching ? Icons.search_off : Icons.people_outline,
        title: _isSearching ? 'No people found' : 'No creators yet',
        subtitle: _isSearching
            ? 'Try a different name.'
            : 'Be the first to go live.',
      );
    }
    return RefreshIndicator(
      color: NileColors.volt,
      backgroundColor: NileColors.bgSurface,
      onRefresh: _loadPeople,
      child: ListView.separated(
        controller: _scroll[_Tab.people],
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(top: NileSpacing.s4, bottom: NileGlassNavBar.reservedHeight + NileSpacing.s24),
        itemCount: users.length + (_hasMore[_Tab.people]! ? 1 : 0),
        separatorBuilder: (_, i) => i >= users.length - 1
            ? const SizedBox.shrink()
            : const Divider(height: 1, indent: 72, color: NileColors.border),
        itemBuilder: (_, i) {
          if (i >= users.length) return const LoadMoreFooter();
          return _UserTile(
            user: users[i],
            isFollowing: _followState[users[i].id] ?? false,
            isLoading: _followLoading.contains(users[i].id),
            onFollowTap: () => _toggleFollow(users[i]),
            onTap: () =>
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ProfileScreen(userId: users[i].id),
                  ),
                ).then((_) {
                  if (!mounted) return;
                  _followState.remove(users[i].id);
                  setState(() {});
                  FollowService.isFollowing(users[i].id).then((v) {
                    if (mounted) setState(() => _followState[users[i].id] = v);
                  });
                }),
          );
        },
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
        padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16, vertical: NileSpacing.s12),
        child: Row(
          children: [
            Hero(
              tag: 'avatar-${user.id}',
              child: CircleAvatar(
                radius: 24,
                backgroundColor: NileColors.bgRaised,
                backgroundImage: user.avatarUrl != null
                    ? nileAvatarImage(user.avatarUrl!, 24)
                    : null,
                child: user.avatarUrl == null
                    ? Text(
                        user.username[0].toUpperCase(),
                        style: NileTextStyles.headingSm().copyWith(
                          color: NileColors.txtSecondary,
                        ),
                      )
                    : null,
              ),
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
                        Text(
                          ' · ',
                          style: NileTextStyles.bodySm().copyWith(
                            color: NileColors.txtTertiary,
                          ),
                        ),
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
          padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16, vertical: NileSpacing.s8),
          minimumSize: const Size(90, 34),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: isLoading
            ? spinnerSize
            : Text(
                'Following',
                style: NileTextStyles.labelSm().copyWith(
                  color: NileColors.txtPrimary,
                  letterSpacing: 0,
                ),
              ),
      );
    }

    return FilledButton(
      onPressed: isLoading ? null : onTap,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16, vertical: NileSpacing.s8),
        minimumSize: const Size(90, 34),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: isLoading
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: NileColors.bgPage,
              ),
            )
          : Text(
              'Follow',
              style: NileTextStyles.labelSm().copyWith(
                color: NileColors.bgPage,
                letterSpacing: 0,
              ),
            ),
    );
  }
}

// ── Discover post card ────────────────────────────────────────────────────────

class _DiscoverPostCard extends StatelessWidget {
  final Post post;
  final VoidCallback onTap;
  final VoidCallback? onLikeToggle;
  const _DiscoverPostCard({
    required this.post,
    required this.onTap,
    this.onLikeToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: NileColors.bgSurface,
      borderRadius: BorderRadius.circular(NileRadius.lg),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(NileSpacing.s12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: NileColors.bgRaised,
                    backgroundImage: post.authorAvatarUrl != null
                        ? nileAvatarImage(post.authorAvatarUrl!, 12)
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
                    child: Text(
                      '@${post.authorUsername}',
                      style: NileTextStyles.bodySm(),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    _timeAgo(post.createdAt),
                    style: NileTextStyles.caption(),
                  ),
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
                    aspectRatio: 4 / 3,
                    child: Image.network(
                      post.imageUrl!,
                      cacheWidth: nileDecodeWidth(600),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        color: NileColors.bgRaised,
                        child: const Center(
                          child: Icon(
                            Icons.broken_image,
                            color: NileColors.border,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              if (post.eventId != null) ...[
                const SizedBox(height: 8),
                EventLinkCard(eventId: post.eventId!),
              ],
              if (onLikeToggle != null) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    LikeButton(
                      liked: post.likedByMe,
                      count: post.likeCount,
                      onTap: onLikeToggle!,
                    ),
                    const SizedBox(width: 14),
                    const Icon(
                      Icons.mode_comment_outlined,
                      size: 18,
                      color: NileColors.txtSecondary,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '${post.commentCount}',
                      style: NileTextStyles.bodySm().copyWith(
                        color: NileColors.txtSecondary,
                      ),
                    ),
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

// ── Discover event card ───────────────────────────────────────────────────────

class _DiscoverEventCard extends StatelessWidget {
  final Event event;
  final bool hero;
  final VoidCallback onTap;
  final VoidCallback? onLikeToggle;
  const _DiscoverEventCard({
    required this.event,
    this.hero = true,
    required this.onTap,
    this.onLikeToggle,
  });

  @override
  Widget build(BuildContext context) {
    return NilePressable(
      child: Material(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.lg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _EventThumbnail(event: event, hero: hero),
              Padding(
                padding: const EdgeInsets.all(NileSpacing.s12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 12,
                          backgroundColor: NileColors.bgRaised,
                          backgroundImage: event.hostAvatarUrl != null
                              ? nileAvatarImage(event.hostAvatarUrl!, 12)
                              : null,
                          child: event.hostAvatarUrl == null
                              ? Text(
                                  event.hostUsername[0].toUpperCase(),
                                  style: NileTextStyles.caption(),
                                )
                              : null,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '@${event.hostUsername}',
                            style: NileTextStyles.bodySm(),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (event.isLive) ...[
                          const Icon(
                            Icons.visibility,
                            size: 13,
                            color: NileColors.txtTertiary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${event.viewerCount}',
                            style: NileTextStyles.caption().tabular,
                          ),
                        ] else
                          Text(
                            _timeAgo(event.createdAt),
                            style: NileTextStyles.caption(),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      event.title,
                      style: NileTextStyles.headingSm(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (onLikeToggle != null) ...[
                      const SizedBox(height: 8),
                      LikeButton(
                        liked: event.likedByMe,
                        count: event.likeCount,
                        onTap: onLikeToggle!,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EventThumbnail extends StatelessWidget {
  final Event event;

  /// Disable when this event already holds a live Hero elsewhere on screen
  /// (e.g. it's in the network rail) — duplicate tags abort hero flights.
  final bool hero;

  /// Fill the parent's constraints instead of forcing 16:9 — used inside
  /// fixed-height cards (network rail) where 16:9 would overflow.
  final bool flexible;
  const _EventThumbnail({
    required this.event,
    this.hero = true,
    this.flexible = false,
  });

  @override
  Widget build(BuildContext context) {
    final placeholder = EventCoverPlaceholder(seed: event.id);
    final image = event.coverImageUrl != null
        ? Image.network(
            event.coverImageUrl!,
            cacheWidth: nileDecodeWidth(600),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => placeholder,
          )
        : placeholder;
    final stack = Stack(
      fit: StackFit.expand,
      children: [
        if (hero)
          Hero(tag: 'event-cover-${event.id}', child: image)
        else
          image,
        const DecoratedBox(decoration: NileEffects.coverScrim),
        Positioned(top: 8, left: 8, child: EventCoverPill(event: event)),
      ],
    );
    return flexible
        ? stack
        : AspectRatio(aspectRatio: 16 / 9, child: stack);
  }
}

// ── "From your network" rail ──────────────────────────────────────────────────

/// Horizontal carousel of follow-graph recommendations with a section header.
class _NetworkRail extends StatelessWidget {
  final List<Widget> children;
  const _NetworkRail({required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.bolt, size: 16, color: NileColors.volt),
            const SizedBox(width: 6),
            Text('From your network', style: NileTextStyles.labelMd()),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Liked by people you follow',
          style: NileTextStyles.caption().copyWith(
            color: NileColors.txtTertiary,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 184,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            itemCount: children.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (_, i) => SizedBox(width: 220, child: children[i]),
          ),
        ),
      ],
    );
  }
}

class _RecPostCard extends StatelessWidget {
  final Post post;
  final VoidCallback onTap;
  const _RecPostCard({required this.post, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: NileColors.bgSurface,
      borderRadius: BorderRadius.circular(NileRadius.lg),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(NileSpacing.s12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 11,
                    backgroundColor: NileColors.bgRaised,
                    backgroundImage: post.authorAvatarUrl != null
                        ? nileAvatarImage(post.authorAvatarUrl!, 11)
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
                    child: Text(
                      '@${post.authorUsername}',
                      style: NileTextStyles.bodySm(),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Text(
                  post.hasCaption ? post.caption!.trim() : '',
                  style: NileTextStyles.bodyMd(),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    post.likedByMe ? Icons.favorite : Icons.favorite_border,
                    size: 16,
                    color: post.likedByMe
                        ? NileColors.coral
                        : NileColors.txtSecondary,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '${post.likeCount}',
                    style: NileTextStyles.bodySm().copyWith(
                      color: NileColors.txtSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecEventCard extends StatelessWidget {
  final Event event;
  final VoidCallback onTap;
  const _RecEventCard({required this.event, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: NileColors.bgSurface,
      borderRadius: BorderRadius.circular(NileRadius.lg),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _EventThumbnail(event: event, flexible: true)),
            Padding(
              padding: const EdgeInsets.all(NileSpacing.s12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '@${event.hostUsername}',
                    style: NileTextStyles.bodySm(),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    event.title,
                    style: NileTextStyles.labelMd(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

// ── Shared helpers ──────────────────────────────────────────────────────────

String _timeAgo(DateTime dt) {
  final d = DateTime.now().difference(dt);
  if (d.inDays > 0) return '${d.inDays}d ago';
  if (d.inHours > 0) return '${d.inHours}h ago';
  if (d.inMinutes > 0) return '${d.inMinutes}m ago';
  return 'just now';
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) =>
      const SingleChildScrollView(child: NileSkeletonList());
}

// ── Empty / error states ──────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(NileSpacing.s40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: NileColors.border),
            const SizedBox(height: 16),
            Text(title, style: NileTextStyles.headingMd()),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: NileTextStyles.bodyMd().copyWith(
                color: NileColors.txtSecondary,
              ),
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
        padding: const EdgeInsets.all(NileSpacing.s40),
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
