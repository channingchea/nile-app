import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/event_service.dart';
import '../services/featured_service.dart';
import '../services/follow_service.dart';
import '../services/like_service.dart';
import '../services/pagination.dart' show Paged;
import '../services/post_service.dart';
import '../services/profile_service.dart';
import '../services/search_service.dart';
import '../router.dart';
import '../theme.dart';
import '../widgets/event_cover_pill.dart';
import '../widgets/event_link_card.dart';
import '../widgets/like_button.dart';
import '../widgets/post_image_carousel.dart';
import '../widgets/nile_glass_nav_bar.dart';
import '../widgets/nile_skeleton.dart';
import '../widgets/official_badge.dart';
import '../widgets/pressable.dart';
import 'like_list_screen.dart';
import 'widgets/load_more_footer.dart';

enum _Tab { posts, events, people }

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key, this.initialTab = 0});

  /// Tab to open on: 0 posts, 1 events, 2 people. Home's empty-state CTAs
  /// remount Discover with this set so the user lands where they intended.
  final int initialTab;

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

  // Editorially-curated "Featured" rails + the "Coming up" upcoming-shows rail
  // (Phase 4). Platform-wide, loaded once on open; only shown when not searching.
  List<Event> _featuredEvents = [];
  List<UserProfile> _featuredCreators = [];
  List<Event> _upcoming = [];

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
    _tabs = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 2),
    )..addListener(_onTabChanged);
    for (final t in _Tab.values) {
      _scroll[t] = ScrollController()..addListener(() => _onScroll(t));
    }
    _controller.addListener(_onQueryChanged);
    _loadActive();
    _loadFeatured();
    _loadUpcoming();
  }

  /// Curated Featured rails (events + creators). Best-effort; hidden when empty.
  Future<void> _loadFeatured() async {
    try {
      final f = await FeaturedService.getFeatured();
      await _loadFollowStates(f.creators); // for the creator cards' follow button
      if (!mounted) return;
      setState(() {
        _featuredEvents = f.events;
        _featuredCreators = f.creators;
      });
    } catch (_) {}
  }

  /// "Coming up on Nile" — upcoming scheduled shows across the platform.
  Future<void> _loadUpcoming() async {
    try {
      final up = await EventService.getUpcoming();
      if (!mounted) return;
      setState(() => _upcoming = up);
    } catch (_) {}
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

  void _openEvent(Event ev) => context.push(
    NileRoutes.eventOrWatch(
      isLive: ev.isLive,
      eventId: ev.id,
      liveKitEventId: ev.liveKitEventId,
    ),
    extra: ev,
  );

  Future<void> _openRecPost(int j) async {
    final updated = await context.push<Post>(
      NileRoutes.post(_recPosts[j].id),
      extra: _recPosts[j],
    );
    if (updated != null && mounted) setState(() => _recPosts[j] = updated);
  }

  void _clearSearch() {
    _controller.clear();
    _focusNode.unfocus();
  }

  /// Empty-state CTAs: create content, then reload the active tab so the new
  /// item shows without a manual refresh.
  Future<void> _createEvent() async {
    await context.push(NileRoutes.createEvent);
    if (mounted) _loadActive();
  }

  Future<void> _createPost() async {
    await context.push(NileRoutes.createPost);
    if (mounted) _loadActive();
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
        subtitle: _isSearching
            ? 'Try a different search.'
            : 'Be the first to share something.',
        actionLabel: _isSearching ? null : 'Create a post',
        onAction: _isSearching ? null : _createPost,
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
              final updated = await context.push<Post>(
                NileRoutes.post(posts[idx].id),
                extra: posts[idx],
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
        actionLabel: _isSearching ? null : 'Host a show',
        onAction: _isSearching ? null : _createEvent,
      );
    }
    final searching = _isSearching;
    // Stacked rails above the list: Featured → Coming up → From your network.
    // Rail event cards never own the Hero, so the vertical list's cards below
    // always do — that keeps a featured/upcoming event that also appears in the
    // list from creating two Heroes with the same tag.
    final headers = <Widget>[
      if (!searching && _featuredEvents.isNotEmpty)
        _RailShelf(
          icon: Icons.star,
          iconColor: NileColors.amber,
          title: 'Featured',
          subtitle: 'Picked by the Nile team',
          children: [
            for (final ev in _featuredEvents)
              _RecEventCard(event: ev, onTap: () => _openEvent(ev)),
          ],
        ),
      if (!searching && _upcoming.isNotEmpty)
        _RailShelf(
          icon: Icons.event_outlined,
          iconColor: NileColors.volt,
          title: 'Coming up on Nile',
          subtitle: 'Scheduled shows, soonest first',
          children: [
            for (final ev in _upcoming)
              _UpcomingEventCard(event: ev, onTap: () => _openEvent(ev)),
          ],
        ),
      if (!searching && _recEvents.isNotEmpty)
        _NetworkRail(
          children: [
            for (final ev in _recEvents)
              _RecEventCard(event: ev, onTap: () => _openEvent(ev)),
          ],
        ),
    ];
    final featuredIds = {for (final e in _featuredEvents) e.id};
    return RefreshIndicator(
      color: NileColors.volt,
      backgroundColor: NileColors.bgSurface,
      onRefresh: _loadEvents,
      child: ListView.separated(
        controller: _scroll[_Tab.events],
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s12, NileSpacing.s16, NileGlassNavBar.reservedHeight + NileSpacing.s24),
        itemCount:
            headers.length + events.length + (_hasMore[_Tab.events]! ? 1 : 0),
        separatorBuilder: (_, i) =>
            SizedBox(height: i < headers.length ? 20 : 12),
        itemBuilder: (_, i) {
          if (i < headers.length) return headers[i];
          final idx = i - headers.length;
          if (idx >= events.length) return const LoadMoreFooter();
          return _DiscoverEventCard(
            event: events[idx],
            featured: featuredIds.contains(events[idx].id),
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
        actionLabel: _isSearching ? null : 'Host a show',
        onAction: _isSearching ? null : _createEvent,
      );
    }
    // Featured creators rail pinned above the suggested list (index 0).
    final showFeatured = !_isSearching && _featuredCreators.isNotEmpty;
    final header = showFeatured ? 1 : 0;
    return RefreshIndicator(
      color: NileColors.volt,
      backgroundColor: NileColors.bgSurface,
      onRefresh: _loadPeople,
      child: ListView.separated(
        controller: _scroll[_Tab.people],
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(top: NileSpacing.s4, bottom: NileGlassNavBar.reservedHeight + NileSpacing.s24),
        itemCount: header + users.length + (_hasMore[_Tab.people]! ? 1 : 0),
        separatorBuilder: (_, i) {
          if (showFeatured && i == 0) return const SizedBox(height: 8);
          final idx = i - header;
          return idx >= users.length - 1
              ? const SizedBox.shrink()
              : Divider(height: 1, indent: 72, color: NileColors.border);
        },
        itemBuilder: (_, i) {
          if (showFeatured && i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(
                NileSpacing.s16, NileSpacing.s12, NileSpacing.s16, NileSpacing.s4,
              ),
              child: _RailShelf(
                icon: Icons.star,
                iconColor: NileColors.amber,
                title: 'Featured creators',
                subtitle: 'Picked by the Nile team',
                children: [
                  for (final u in _featuredCreators)
                    _FeaturedCreatorCard(
                      user: u,
                      isFollowing: _followState[u.id] ?? false,
                      isLoading: _followLoading.contains(u.id),
                      onFollowTap: () => _toggleFollow(u),
                      onTap: () => context.push(NileRoutes.profile(u.id)),
                    ),
                ],
              ),
            );
          }
          final idx = i - header;
          if (idx >= users.length) return const LoadMoreFooter();
          return _UserTile(
            user: users[idx],
            isFollowing: _followState[users[idx].id] ?? false,
            isLoading: _followLoading.contains(users[idx].id),
            onFollowTap: () => _toggleFollow(users[idx]),
            onTap: () =>
                context.push(NileRoutes.profile(users[idx].id)).then((_) {
                  if (!mounted) return;
                  _followState.remove(users[idx].id);
                  setState(() {});
                  FollowService.isFollowing(users[idx].id).then((v) {
                    if (mounted) setState(() => _followState[users[idx].id] = v);
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
          ? SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: NileColors.onVolt,
              ),
            )
          : Text(
              'Follow',
              style: NileTextStyles.labelSm().copyWith(
                color: NileColors.onVolt,
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
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            '@${post.authorUsername}',
                            style: NileTextStyles.bodySm(),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (post.authorIsOfficial) ...[
                          const SizedBox(width: 4),
                          const OfficialBadge(size: 13),
                        ],
                      ],
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
                PostImageCarousel(imageUrls: post.images),
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
                      onCountTap: () =>
                          LikeListScreen.openPost(context, post.id),
                    ),
                    const SizedBox(width: 14),
                    Icon(
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
  final bool featured; // shows a "Featured" chip when this event is also curated
  final VoidCallback onTap;
  final VoidCallback? onLikeToggle;
  const _DiscoverEventCard({
    required this.event,
    this.featured = false,
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
              _EventThumbnail(event: event),
              Padding(
                padding: const EdgeInsets.all(NileSpacing.s12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (featured) ...[
                      const _FeaturedTag(),
                      const SizedBox(height: 6),
                    ],
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
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  '@${event.hostUsername}',
                                  style: NileTextStyles.bodySm(),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (event.hostIsOfficial) ...[
                                const SizedBox(width: 4),
                                const OfficialBadge(size: 13),
                              ],
                            ],
                          ),
                        ),
                        if (event.isLive) ...[
                          Icon(
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
                        onCountTap: () =>
                            LikeListScreen.openEvent(context, event.id),
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
            Icon(Icons.bolt, size: 16, color: NileColors.volt),
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
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            '@${post.authorUsername}',
                            style: NileTextStyles.bodySm(),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (post.authorIsOfficial) ...[
                          const SizedBox(width: 4),
                          const OfficialBadge(size: 12),
                        ],
                      ],
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
            Expanded(
              child: _EventThumbnail(event: event, flexible: true, hero: false),
            ),
            Padding(
              padding: const EdgeInsets.all(NileSpacing.s12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          '@${event.hostUsername}',
                          style: NileTextStyles.bodySm(),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (event.hostIsOfficial) ...[
                        const SizedBox(width: 4),
                        const OfficialBadge(size: 13),
                      ],
                    ],
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

// ── Featured / Coming-up rails (Phase 4) ──────────────────────────────────────

/// Generic horizontal rail shelf: header (icon + title + subtitle) over a row
/// of 220-wide cards. Mirrors [_NetworkRail] but with a caller-supplied label,
/// so Featured / Coming up / network rails all read as one pattern.
class _RailShelf extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final List<Widget> children;
  const _RailShelf({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: iconColor),
            const SizedBox(width: 6),
            Text(title, style: NileTextStyles.labelMd()),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
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

/// Small "Featured" chip on a main-list event card that's also curated (same
/// visual weight as the feed's Sponsored / network tags).
class _FeaturedTag extends StatelessWidget {
  const _FeaturedTag();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.star, size: 14, color: NileColors.amber),
        const SizedBox(width: 4),
        Text(
          'Featured',
          style: NileTextStyles.caption().copyWith(
            color: NileColors.txtTertiary,
          ),
        ),
      ],
    );
  }
}

/// Rail card for "Coming up on Nile": cover (its pill already shows the
/// scheduled date·time), title, host, and ticket price if set.
class _UpcomingEventCard extends StatelessWidget {
  final Event event;
  final VoidCallback onTap;
  const _UpcomingEventCard({required this.event, required this.onTap});

  String? get _price {
    final p = event.price;
    if (p == null || p <= 0) return null;
    final dollars = p / 100;
    return dollars == dollars.roundToDouble()
        ? '\$${dollars.toStringAsFixed(0)}'
        : '\$${dollars.toStringAsFixed(2)}';
  }

  @override
  Widget build(BuildContext context) {
    final price = _price;
    return Material(
      color: NileColors.bgSurface,
      borderRadius: BorderRadius.circular(NileRadius.lg),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _EventThumbnail(event: event, flexible: true, hero: false),
            ),
            Padding(
              padding: const EdgeInsets.all(NileSpacing.s12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    style: NileTextStyles.labelMd(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      // Expanded (not Flexible + Spacer) so the price stays
                      // flush right regardless of username length.
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                '@${event.hostUsername}',
                                style: NileTextStyles.bodySm(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (event.hostIsOfficial) ...[
                              const SizedBox(width: 4),
                              const OfficialBadge(size: 13),
                            ],
                          ],
                        ),
                      ),
                      if (price != null)
                        Text(
                          price,
                          style: NileTextStyles.labelSm().copyWith(
                            color: NileColors.volt,
                            letterSpacing: 0,
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

/// Rail card for a featured creator: avatar, name, follower count, follow button.
class _FeaturedCreatorCard extends StatelessWidget {
  final UserProfile user;
  final bool isFollowing;
  final bool isLoading;
  final VoidCallback onFollowTap;
  final VoidCallback onTap;
  const _FeaturedCreatorCard({
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
    return Material(
      color: NileColors.bgSurface,
      borderRadius: BorderRadius.circular(NileRadius.lg),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(NileSpacing.s12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: NileColors.bgRaised,
                backgroundImage: user.avatarUrl != null
                    ? nileAvatarImage(user.avatarUrl!, 28)
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
              const SizedBox(height: 8),
              Text(
                user.displayName,
                style: NileTextStyles.labelMd(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                user.followerCount > 0
                    ? '${_fmt(user.followerCount)} followers'
                    : '@${user.username}',
                style: NileTextStyles.caption(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              _FollowButton(
                isFollowing: isFollowing,
                isLoading: isLoading,
                onTap: onFollowTap,
              ),
            ],
          ),
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
  final String? actionLabel;
  final VoidCallback? onAction;
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
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
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 24),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
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
