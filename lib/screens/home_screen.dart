import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/event_repost_service.dart';
import '../services/share_urls.dart';
import '../services/event_service.dart';
import '../services/follow_service.dart';
import '../services/like_service.dart';
import '../services/notification_service.dart';
import '../services/pagination.dart' show Paged;
import '../services/post_service.dart';
import '../services/repost_service.dart';
import '../services/search_service.dart';
import '../theme.dart';
import '../widgets/event_link_card.dart';
import '../widgets/share_to_sheet.dart';
import 'audio_screen.dart';
import 'camera_screen.dart';
import 'create_event_flow.dart';
import 'create_post_screen.dart';
import 'discover_screen.dart';
import 'edit_event_screen.dart';
import 'edit_post_screen.dart';
import 'event_detail_screen.dart';
import 'messages_screen.dart';
import 'notifications_screen.dart';
import 'post_detail_screen.dart';
import 'profile_screen.dart';
import 'viewer_screen.dart';
import 'widgets/load_more_footer.dart';

// ── Shell ─────────────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;
  int _feedKey = 0;
  int _profileKey = 0;

  List<Widget> get _pages => [
    _FeedTab(key: ValueKey(_feedKey), onContentChanged: _onContentChanged),
    const DiscoverScreen(),
    const MessagesScreen(),
    ProfileScreen(key: ValueKey(_profileKey)),
  ];

  // A repost happened inside the feed. The feed already updated its own card
  // optimistically, so leave it (and its scroll position) untouched — only
  // remount the profile tab so it re-fetches and shows the new reposted item.
  void _onContentChanged() => setState(() => _profileKey++);

  // New post/event created via the FAB. Remount both tabs so each reloads from
  // scratch, and snap to the feed so the user sees their content land.
  void _onContentCreated() => setState(() {
        _feedKey++;
        _profileKey++;
        _selectedIndex = 0;
      });

  void _showActionSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: NileColors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
      ),
      builder: (_) => _ActionSheet(onCreated: _onContentCreated),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NileColors.bgPage,
      body: NileMaxWidth(child: IndexedStack(index: _selectedIndex, children: _pages)),
      floatingActionButton: _selectedIndex == 0
          ? FloatingActionButton(
              onPressed: _showActionSheet,
              backgroundColor: NileColors.volt,
              foregroundColor: NileColors.bgPage,
              child: const Icon(Icons.add),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        backgroundColor: NileColors.bgSurface,
        indicatorColor: NileColors.volt.withValues(alpha: 0.15),
        selectedIndex: _selectedIndex,
        onDestinationSelected: (i) => setState(() => _selectedIndex = i),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home, color: NileColors.volt),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search, color: NileColors.volt),
            label: 'Discover',
          ),
          NavigationDestination(
            icon: Icon(Icons.send_outlined),
            selectedIcon: Icon(Icons.send, color: NileColors.volt),
            label: 'Messages',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person, color: NileColors.volt),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}

// ── Action sheet (FAB → bottom sheet) ────────────────────────────────────────

class _ActionSheet extends StatelessWidget {
  const _ActionSheet({required this.onCreated});
  final VoidCallback onCreated;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: NileColors.border,
                  borderRadius: BorderRadius.circular(NileRadius.pill),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text('Create', style: NileTextStyles.headingMd()),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const CreatePostScreen()))
                  .then((_) => onCreated());
              },
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Create Post'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const CreateEventFlow()))
                  .then((_) => onCreated());
              },
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Create Event'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const CameraScreen()));
              },
              icon: const Icon(Icons.videocam),
              label: const Text('Stream as Camera'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const ViewerScreen()));
              },
              icon: const Icon(Icons.tv),
              label: const Text('Watch as Viewer'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const AudioScreen()));
              },
              icon: const Icon(Icons.album, color: NileColors.volt),
              label: Text(
                'Stream Audio',
                style: NileTextStyles.labelLg().copyWith(color: NileColors.volt),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: NileColors.volt,
                side: const BorderSide(color: NileColors.volt),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(NileRadius.sm),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Feed tab ──────────────────────────────────────────────────────────────────

class _FeedTab extends StatefulWidget {
  const _FeedTab({super.key, this.onContentChanged});

  /// Called after a repost/unrepost succeeds so the host can refresh the
  /// profile tab (where the reposted item appears).
  final VoidCallback? onContentChanged;

  @override
  State<_FeedTab> createState() => _FeedTabState();
}

/// Unified feed entry — either an [Event] or a [Post].
/// [fromNetwork] marks a follow-graph recommendation (liked by people you
/// follow but not authored by someone you follow), surfaced with a tag.
sealed class _FeedItem {
  DateTime get sortKey;
  bool get fromNetwork;
}

class _EventFeedItem extends _FeedItem {
  final Event event;
  @override
  final bool fromNetwork;
  /// When set (reposts), sorts by repost time instead of scheduled/created.
  final DateTime? sortOverride;
  _EventFeedItem(this.event, {this.fromNetwork = false, this.sortOverride});
  @override
  DateTime get sortKey => sortOverride ?? event.scheduledAt ?? event.createdAt;
}

class _PostFeedItem extends _FeedItem {
  final Post post;
  @override
  final bool fromNetwork;
  /// When set (reposts), the item sorts by repost time instead of the original
  /// post's createdAt, so a fresh repost surfaces near the top of the feed.
  final DateTime? sortOverride;
  _PostFeedItem(this.post, {this.fromNetwork = false, this.sortOverride});
  @override
  DateTime get sortKey => sortOverride ?? post.createdAt;
}

class _FeedTabState extends State<_FeedTab> {
  List<_FeedItem>? _items;
  bool _noFollows = false;
  String? _error;
  int _unreadCount = 0;

  // Follow-graph recommendations, interleaved into the followed feed every
  // [_recInterval] items. Loaded once per [_load]; not part of pagination.
  List<_FeedItem> _recs = [];
  static const _recInterval = 6;

  // Pagination — independent cursors per source, merged into [_items].
  final _scroll = ScrollController();
  List<String> _followingIds = [];
  String? _postCursor;
  String? _eventCursor;
  bool _postsHasMore = false;
  bool _eventsHasMore = false;
  bool _loadingMore = false;

  bool get _hasMore => _postsHasMore || _eventsHasMore;

  /// Applies [update] to whichever list (followed [_items] or [_recs]) holds the
  /// matching item, preserving its `fromNetwork` flag. Used by all mutations so
  /// liking/editing an interleaved rec card works the same as a followed one.
  void _mutate(bool Function(_FeedItem) match,
      _FeedItem Function(_FeedItem) update) {
    setState(() {
      for (final list in [_items, _recs]) {
        if (list == null) continue;
        final i = list.indexWhere(match);
        if (i >= 0) list[i] = update(list[i]);
      }
    });
  }

  void _remove(bool Function(_FeedItem) match) {
    setState(() {
      _items?.removeWhere(match);
      _recs.removeWhere(match);
    });
  }

  void _replacePost(Post updated) => _mutate(
        (it) => it is _PostFeedItem && it.post.id == updated.id,
        (it) => _PostFeedItem(updated, fromNetwork: it.fromNetwork),
      );

  void _removePost(String postId) =>
      _remove((it) => it is _PostFeedItem && it.post.id == postId);

  void _replaceEvent(Event updated) => _mutate(
        (it) => it is _EventFeedItem && it.event.id == updated.id,
        (it) => _EventFeedItem(updated, fromNetwork: it.fromNetwork),
      );

  void _removeEvent(String eventId) =>
      _remove((it) => it is _EventFeedItem && it.event.id == eventId);

  Future<void> _togglePostLike(Post post) async {
    final wasLiked = post.likedByMe;
    final delta = wasLiked ? -1 : 1;
    final optimistic = post.copyWith(
      likedByMe: !wasLiked,
      likeCount: (post.likeCount + delta).clamp(0, 1 << 30),
    );
    _replacePost(optimistic);
    try {
      if (wasLiked) {
        await LikeService.unlikePost(post.id);
      } else {
        await LikeService.likePost(post.id);
      }
    } catch (_) {
      _replacePost(post); // Revert.
    }
  }

  Future<void> _togglePostRepost(Post post) async {
    final was = post.repostedByMe;
    final delta = was ? -1 : 1;
    _replacePost(post.copyWith(
      repostedByMe: !was,
      repostCount: (post.repostCount + delta).clamp(0, 1 << 30),
    ));
    try {
      if (was) {
        await RepostService.unrepost(post.id);
      } else {
        await RepostService.repost(post.id);
      }
      widget.onContentChanged?.call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(was ? 'Removed repost' : 'Reposted to your profile'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      _replacePost(post); // Revert.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to repost')),
      );
    }
  }

  Future<void> _toggleEventRepost(Event event) async {
    final was = event.repostedByMe;
    final delta = was ? -1 : 1;
    _replaceEvent(event.copyWith(
      repostedByMe: !was,
      repostCount: (event.repostCount + delta).clamp(0, 1 << 30),
    ));
    try {
      if (was) {
        await EventRepostService.unrepost(event.id);
      } else {
        await EventRepostService.repost(event.id);
      }
      widget.onContentChanged?.call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(was ? 'Removed repost' : 'Reposted to your profile'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      _replaceEvent(event);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to repost')),
      );
    }
  }

  Future<void> _toggleEventLike(Event event) async {
    final wasLiked = event.likedByMe;
    final delta = wasLiked ? -1 : 1;
    final optimistic = event.copyWith(
      likedByMe: !wasLiked,
      likeCount: (event.likeCount + delta).clamp(0, 1 << 30),
    );
    _replaceEvent(optimistic);
    try {
      if (wasLiked) {
        await LikeService.unlikeEvent(event.id);
      } else {
        await LikeService.likeEvent(event.id);
      }
    } catch (_) {
      _replaceEvent(event);
    }
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
    _loadUnread();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels <
        _scroll.position.maxScrollExtent - 400) {
      return;
    }
    if (_hasMore && !_loadingMore && _items != null) _loadMore();
  }

  String _idOf(_FeedItem it) => switch (it) {
        _EventFeedItem(:final event) => 'e:${event.id}',
        _PostFeedItem(:final post) => 'p:${post.id}',
      };

  /// Interleaves [_recs] into the sorted [followed] feed: one rec after every
  /// [_recInterval] followed items. Recs whose content already appears in the
  /// followed feed are skipped. Recs keep their ranking order. Returns a new
  /// list; followed ordering is untouched.
  List<_FeedItem> _interleaveRecs(List<_FeedItem> followed) {
    if (_recs.isEmpty) return followed;
    final seen = followed.map(_idOf).toSet();
    final recs = _recs.where((r) => seen.add(_idOf(r))).toList();
    if (recs.isEmpty) return followed;

    final out = <_FeedItem>[];
    var r = 0;
    for (var i = 0; i < followed.length; i++) {
      out.add(followed[i]);
      if ((i + 1) % _recInterval == 0 && r < recs.length) {
        out.add(recs[r++]);
      }
    }
    // Append any remaining recs (short feed) so they aren't lost.
    out.addAll(recs.sublist(r));
    return out;
  }

  /// Sorts the unified feed: live events pinned, then by recency.
  void _sortItems(List<_FeedItem> items) {
    items.sort((a, b) {
      final aLive = a is _EventFeedItem && a.event.isLive;
      final bLive = b is _EventFeedItem && b.event.isLive;
      if (aLive != bLive) return aLive ? -1 : 1;
      return b.sortKey.compareTo(a.sortKey);
    });
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      final results = await (
        _eventsHasMore
            ? EventService.getFeed(_followingIds, cursor: _eventCursor)
            : Future.value(Paged.empty<Event>()),
        _postsHasMore
            ? PostService.getFeed(_followingIds, cursor: _postCursor)
            : Future.value(Paged.empty<Post>()),
      ).wait;
      final (eventPage, postPage) = results;
      final (hEvents, hPosts) = await (
        EventService.hydrateLikes(eventPage.items),
        PostService.hydrateLikes(postPage.items),
      ).wait;
      if (!mounted) return;
      setState(() {
        _items = [
          ...?_items,
          ...hEvents.map((e) => _EventFeedItem(e)),
          ...hPosts.map((p) => _PostFeedItem(p)),
        ];
        _sortItems(_items!);
        if (_eventsHasMore) {
          _eventCursor = eventPage.nextCursor;
          _eventsHasMore = eventPage.hasMore;
        }
        if (_postsHasMore) {
          _postCursor = postPage.nextCursor;
          _postsHasMore = postPage.hasMore;
        }
      });
    } catch (_) {
      // Keep existing items; scrolling again retries.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _loadUnread() async {
    try {
      final count = await NotificationService.unreadCount();
      if (mounted) setState(() => _unreadCount = count);
    } catch (_) {}
  }

  Future<void> _openNotifications() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const NotificationsScreen()),
    );
    // Refresh badge after returning (all were marked read in the screen).
    _loadUnread();
  }

  Future<void> _load() async {
    setState(() {
      _items = null;
      _noFollows = false;
      _error = null;
    });
    try {
      final ids = await FollowService.getFollowingIds();
      _followingIds = ids;
      if (ids.isEmpty) {
        setState(() => _noFollows = true);
        return;
      }
      final (eventPage, postPage) = await (
        EventService.getFeed(ids),
        PostService.getFeed(ids),
      ).wait;
      // Reposts by followed users + your own — best-effort, loaded once
      // (not paged). Including self so you see your repost land in-feed.
      final myId = Supabase.instance.client.auth.currentUser?.id;
      final reposterIds = [...ids, ?myId];
      List<({Post post, DateTime repostedAt})> repostRows = [];
      List<({Event event, DateTime repostedAt})> eventRepostRows = [];
      try {
        (repostRows, eventRepostRows) = await (
          PostService.getRepostsFeed(reposterIds),
          EventService.getRepostsFeed(reposterIds),
        ).wait;
      } catch (_) {}
      // Hydrate likedByMe + repostedByMe flags in parallel (non-fatal).
      final (hEvents, lPosts, lReposts, lEventReposts) = await (
        EventService.hydrateLikes(eventPage.items),
        PostService.hydrateLikes(postPage.items),
        PostService.hydrateLikes(repostRows.map((r) => r.post).toList()),
        EventService.hydrateLikes(
            eventRepostRows.map((r) => r.event).toList()),
      ).wait;
      final (hPosts, hReposts, hEventReposts) = await (
        PostService.hydrateReposts(lPosts),
        PostService.hydrateReposts(lReposts),
        EventService.hydrateReposts(lEventReposts),
      ).wait;
      // A repost is its own distinct feed entry (shown with a "reposted by"
      // header), sorted by repost time — not deduped against the original.
      final repostAt = {for (final r in repostRows) r.post.id: r.repostedAt};
      final eventRepostAt = {
        for (final r in eventRepostRows) r.event.id: r.repostedAt
      };
      final items = <_FeedItem>[
        ...hEvents.map((e) => _EventFeedItem(e)),
        ...hPosts.map((p) => _PostFeedItem(p)),
        ...hReposts.map((p) =>
            _PostFeedItem(p, sortOverride: repostAt[p.id])),
        ...hEventReposts.map((e) =>
            _EventFeedItem(e, sortOverride: eventRepostAt[e.id])),
      ];
      _sortItems(items);
      // Recs are best-effort: a failure here must not break the feed.
      List<_FeedItem> recs = [];
      try {
        final (rEvents, rPosts) = await (
          SearchService.recommendedEvents(),
          SearchService.recommendedPosts(),
        ).wait;
        recs = [
          ...rEvents.map((e) => _EventFeedItem(e, fromNetwork: true)),
          ...rPosts.map((p) => _PostFeedItem(p, fromNetwork: true)),
        ];
      } catch (_) {}
      setState(() {
        _items = items;
        _recs = recs;
        _eventCursor = eventPage.nextCursor;
        _postCursor = postPage.nextCursor;
        _eventsHasMore = eventPage.hasMore;
        _postsHasMore = postPage.hasMore;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
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
              title: Text('Nile', style: NileTextStyles.displayLg().copyWith(fontSize: 32, color: NileColors.volt)),
              actions: [
                IconButton(
                  onPressed: _load,
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  onPressed: _openNotifications,
                  icon: Badge(
                    isLabelVisible: _unreadCount > 0,
                    label: _unreadCount > 9
                        ? const Text('9+')
                        : Text('$_unreadCount'),
                    backgroundColor: NileColors.coral,
                    child: const Icon(Icons.notifications_outlined),
                  ),
                ),
              ],
            ),
            if (_error != null)
              SliverFillRemaining(
                child: _ErrorState(message: _error!, onRetry: _load),
              )
            else if (_noFollows)
              const SliverFillRemaining(child: _EmptyFollows())
            else if (_items == null)
              const SliverFillRemaining(
                child: Center(
                  child: CircularProgressIndicator(color: NileColors.volt),
                ),
              )
            else if (_items!.isEmpty)
              const SliverFillRemaining(child: _EmptyFeed())
            else
              Builder(builder: (_) {
                final display = _interleaveRecs(_items!);
                return SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                  sliver: SliverList.separated(
                    itemCount: display.length + (_hasMore ? 1 : 0),
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (_, i) {
                      if (i >= display.length) return const LoadMoreFooter();
                      final it = display[i];
                      final myId =
                          Supabase.instance.client.auth.currentUser?.id;
                      return switch (it) {
                        _EventFeedItem(:final event) => _EventCard(
                            event: event,
                            fromNetwork: it.fromNetwork,
                            onEdited: myId == event.hostId
                                ? (e) => _replaceEvent(e)
                                : null,
                            onDeleted: myId == event.hostId
                                ? () => _removeEvent(event.id)
                                : null,
                            onLikeToggle: () => _toggleEventLike(event),
                            onRepostToggle: () => _toggleEventRepost(event),
                          ),
                        _PostFeedItem(:final post) => _PostCard(
                            post: post,
                            fromNetwork: it.fromNetwork,
                            onEdited: myId == post.authorId
                                ? (p) => _replacePost(p)
                                : null,
                            onDeleted: myId == post.authorId
                                ? () => _removePost(post.id)
                                : null,
                            onLikeToggle: () => _togglePostLike(post),
                            onRepostToggle: () => _togglePostRepost(post),
                            onUpdated: (updated) => _replacePost(updated),
                          ),
                      };
                    },
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

// ── Event card ────────────────────────────────────────────────────────────────

class _EventCard extends StatelessWidget {
  final Event event;
  final bool fromNetwork;
  final void Function(Event)? onEdited;
  final VoidCallback? onDeleted;
  final VoidCallback? onLikeToggle;
  final VoidCallback? onRepostToggle;
  const _EventCard(
      {required this.event,
      this.fromNetwork = false,
      this.onEdited,
      this.onDeleted,
      this.onLikeToggle,
      this.onRepostToggle});

  String _shareText() => ShareUrls.eventCaption(
        id: event.id,
        title: event.title,
        hostUsername: event.hostUsername,
      );

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
        onTap: () async {
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => event.isLive
                  ? ViewerScreen(initialEventId: event.liveKitEventId)
                  : EventDetailScreen(event: event),
            ),
          );
          if (result == true) onDeleted?.call();
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (fromNetwork) const _NetworkTag(padded: true),
            if (event.repostedByUsername != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: _RepostHeader(username: event.repostedByUsername!),
              ),
            _Thumbnail(event: event),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 14,
                        backgroundColor: NileColors.bgRaised,
                        backgroundImage: event.hostAvatarUrl != null
                            ? NetworkImage(event.hostAvatarUrl!)
                            : null,
                        child: event.hostAvatarUrl == null
                            ? Text(
                                event.hostUsername[0].toUpperCase(),
                                style: NileTextStyles.labelSm().copyWith(
                                  color: NileColors.txtPrimary,
                                  letterSpacing: 0,
                                ),
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
                        const Icon(Icons.visibility,
                            size: 13, color: NileColors.txtTertiary),
                        const SizedBox(width: 4),
                        Text('${event.viewerCount}',
                            style: NileTextStyles.caption()),
                      ] else
                        Text(_timeAgo(event.createdAt),
                            style: NileTextStyles.caption()),
                      if (onEdited != null)
                        _ContentMenu(
                          onEdit: () async {
                            final updated = await Navigator.push<Event>(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      EditEventScreen(event: event)),
                            );
                            if (updated != null) onEdited!(updated);
                          },
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
                  if (event.isScheduled) ...[
                    const SizedBox(height: 4),
                    Text('Scheduled', style: NileTextStyles.caption()),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (onLikeToggle != null)
                        _LikeButton(
                          liked: event.likedByMe,
                          count: event.likeCount,
                          onTap: onLikeToggle!,
                        ),
                      if (onRepostToggle != null) ...[
                        const SizedBox(width: 16),
                        _RepostButton(
                          reposted: event.repostedByMe,
                          count: event.repostCount,
                          onTap: onRepostToggle!,
                        ),
                      ],
                      const Spacer(),
                      InkWell(
                        onTap: () => ShareToSheet.showEvent(context,
                            eventId: event.id, shareText: _shareText()),
                        borderRadius: BorderRadius.circular(NileRadius.sm),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: 4, vertical: 4),
                          child: Icon(Icons.send_outlined,
                              size: 18, color: NileColors.txtSecondary),
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

// ── "From your network" tag ──────────────────────────────────────────────────

/// Small inline label marking a follow-graph recommendation in the feed.
/// [padded] adds card padding for use above a full-bleed element (event
/// thumbnail); omit it when already inside a padded column (post body).
class _NetworkTag extends StatelessWidget {
  final bool padded;
  const _NetworkTag({this.padded = false});

  @override
  Widget build(BuildContext context) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.bolt, size: 14, color: NileColors.volt),
        const SizedBox(width: 4),
        Text(
          'From your network',
          style:
              NileTextStyles.caption().copyWith(color: NileColors.txtTertiary),
        ),
      ],
    );
    return padded
        ? Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 0), child: row)
        : row;
  }
}

// ── Like button (shared) ─────────────────────────────────────────────────────

class _LikeButton extends StatelessWidget {
  final bool liked;
  final int count;
  final VoidCallback onTap;
  const _LikeButton({
    required this.liked,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = liked ? NileColors.coral : NileColors.txtSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NileRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(liked ? Icons.favorite : Icons.favorite_border,
                size: 18, color: color),
            const SizedBox(width: 5),
            Text('$count',
                style: NileTextStyles.bodySm().copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}

// ── Post card ─────────────────────────────────────────────────────────────────

class _PostCard extends StatelessWidget {
  final Post post;
  final bool fromNetwork;
  final void Function(Post)? onEdited;
  final VoidCallback? onDeleted;
  final VoidCallback? onLikeToggle;
  final VoidCallback? onRepostToggle;
  final void Function(Post)? onUpdated;
  const _PostCard({
    required this.post,
    this.fromNetwork = false,
    this.onEdited,
    this.onDeleted,
    this.onLikeToggle,
    this.onRepostToggle,
    this.onUpdated,
  });

  String _shareText() =>
      ShareUrls.postCaption(id: post.id, authorUsername: post.authorUsername);

  Future<void> _openDetail(BuildContext context) async {
    final updated = await Navigator.push<Post>(
      context,
      MaterialPageRoute(builder: (_) => PostDetailScreen(post: post)),
    );
    if (updated != null) onUpdated?.call(updated);
  }

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
        onTap: () => _openDetail(context),
        child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (fromNetwork) ...[
              const _NetworkTag(),
              const SizedBox(height: 8),
            ],
            if (post.repostedByUsername != null) ...[
              _RepostHeader(username: post.repostedByUsername!),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: NileColors.bgRaised,
                  backgroundImage: post.authorAvatarUrl != null
                      ? NetworkImage(post.authorAvatarUrl!)
                      : null,
                  child: post.authorAvatarUrl == null
                      ? Text(
                          post.authorUsername[0].toUpperCase(),
                          style: NileTextStyles.labelSm().copyWith(
                            color: NileColors.txtPrimary,
                            letterSpacing: 0,
                          ),
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
                Text(_timeAgo(post.createdAt), style: NileTextStyles.caption()),
                if (onEdited != null || onDeleted != null)
                  _ContentMenu(
                    onEdit: onEdited == null
                        ? null
                        : () async {
                            final updated = await Navigator.push<Post>(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => EditPostScreen(post: post)),
                            );
                            if (updated != null) onEdited!(updated);
                          },
                    onDelete: onDeleted == null
                        ? null
                        : () async {
                            final ok = await _confirmDelete(context, 'post');
                            if (ok) {
                              try {
                                await PostService.delete(post.id);
                                onDeleted!();
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content: Text('Failed to delete: $e')),
                                  );
                                }
                              }
                            }
                          },
                  ),
              ],
            ),
            if (post.hasCaption) ...[
              const SizedBox(height: 10),
              Text(
                post.caption!.trim(),
                style: NileTextStyles.bodyMd(),
              ),
            ],
            if (post.hasImage) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(NileRadius.sm),
                child: Image.network(
                  post.imageUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    height: 200,
                    color: NileColors.bgRaised,
                    child: const Center(
                      child: Icon(Icons.broken_image,
                          color: NileColors.border),
                    ),
                  ),
                ),
              ),
            ],
            if (post.eventId != null) ...[
              const SizedBox(height: 10),
              EventLinkCard(eventId: post.eventId!),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                if (onLikeToggle != null)
                  _LikeButton(
                    liked: post.likedByMe,
                    count: post.likeCount,
                    onTap: onLikeToggle!,
                  ),
                const SizedBox(width: 16),
                InkWell(
                  onTap: () => _openDetail(context),
                  borderRadius: BorderRadius.circular(NileRadius.sm),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.mode_comment_outlined,
                            size: 18, color: NileColors.txtSecondary),
                        const SizedBox(width: 5),
                        Text('${post.commentCount}',
                            style: NileTextStyles.bodySm().copyWith(
                                color: NileColors.txtSecondary)),
                      ],
                    ),
                  ),
                ),
                if (onRepostToggle != null) ...[
                  const SizedBox(width: 16),
                  _RepostButton(
                    reposted: post.repostedByMe,
                    count: post.repostCount,
                    onTap: onRepostToggle!,
                  ),
                ],
                const Spacer(),
                InkWell(
                  onTap: () => ShareToSheet.show(context,
                      postId: post.id, shareText: _shareText()),
                  borderRadius: BorderRadius.circular(NileRadius.sm),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    child: Icon(Icons.send_outlined,
                        size: 18, color: NileColors.txtSecondary),
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

// ── Repost header + button ──────────────────────────────────────────────────────

class _RepostHeader extends StatelessWidget {
  final String username;
  const _RepostHeader({required this.username});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.repeat, size: 14, color: NileColors.txtTertiary),
        const SizedBox(width: 6),
        Flexible(
          child: Text('reposted by @$username',
              style: NileTextStyles.caption(),
              overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}

class _RepostButton extends StatelessWidget {
  final bool reposted;
  final int count;
  final VoidCallback onTap;
  const _RepostButton({
    required this.reposted,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = reposted ? NileColors.volt : NileColors.txtSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NileRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.repeat, size: 18, color: color),
            const SizedBox(width: 5),
            Text('$count',
                style: NileTextStyles.bodySm().copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}

// ── Thumbnail ─────────────────────────────────────────────────────────────────

class _Thumbnail extends StatelessWidget {
  final Event event;
  const _Thumbnail({required this.event});

  Widget _placeholder() => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [NileColors.bgRaised, NileColors.bgSurface],
          ),
        ),
        child: Center(
          child: Icon(Icons.live_tv, size: 40, color: NileColors.border),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (event.thumbnailUrl != null)
            Image.network(
              event.thumbnailUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _placeholder(),
            )
          else
            _placeholder(),
          if (event.isLive)
            const Positioned(top: 10, right: 10, child: _LiveBadge()),
        ],
      ),
    );
  }
}

// ── LIVE badge (pulsing dot) ──────────────────────────────────────────────────

class _LiveBadge extends StatefulWidget {
  const _LiveBadge();

  @override
  State<_LiveBadge> createState() => _LiveBadgeState();
}

class _LiveBadgeState extends State<_LiveBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.35, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: NileColors.coral,
        borderRadius: BorderRadius.circular(NileRadius.xs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (_, _) => Opacity(
              opacity: _pulse.value,
              child: const CircleAvatar(radius: 3.5, backgroundColor: Colors.white),
            ),
          ),
          const SizedBox(width: 5),
          Text(
            'LIVE',
            style: NileTextStyles.caption().copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Empty / error states ──────────────────────────────────────────────────────

class _StateView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _StateView({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: NileColors.border),
            const SizedBox(height: 16),
            Text(title, style: NileTextStyles.headingMd()),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: NileTextStyles.bodyMd().copyWith(color: NileColors.txtSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyFollows extends StatelessWidget {
  const _EmptyFollows();

  @override
  Widget build(BuildContext context) => const _StateView(
        icon: Icons.person_add_outlined,
        title: 'Follow creators',
        body: 'Events from people you follow will appear here.',
      );
}

class _EmptyFeed extends StatelessWidget {
  const _EmptyFeed();

  @override
  Widget build(BuildContext context) => const _StateView(
        icon: Icons.live_tv,
        title: 'No events right now',
        body: 'Check back later when the people you follow go live.',
      );
}

// ── Shared edit/delete helpers ────────────────────────────────────────────────

Future<bool> _confirmDelete(BuildContext context, String itemType) async {
  return await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: NileColors.bgSurface,
          title: Text('Delete $itemType?', style: NileTextStyles.headingSm()),
          content: Text('This cannot be undone.',
              style: NileTextStyles.bodyMd()
                  .copyWith(color: NileColors.txtSecondary)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Delete',
                  style: TextStyle(color: NileColors.error)),
            ),
          ],
        ),
      ) ==
      true;
}

/// Three-dot popup menu used on owned content cards.
class _ContentMenu extends StatelessWidget {
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  const _ContentMenu({this.onEdit, this.onDelete});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_horiz, size: 18, color: NileColors.txtTertiary),
      color: NileColors.bgRaised,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NileRadius.sm)),
      onSelected: (v) {
        if (v == 'edit') onEdit?.call();
        if (v == 'delete') onDelete?.call();
      },
      itemBuilder: (_) => [
        if (onEdit != null)
          const PopupMenuItem(value: 'edit', child: Text('Edit')),
        if (onDelete != null)
          PopupMenuItem(
            value: 'delete',
            child: Text('Delete',
                style: TextStyle(color: NileColors.error)),
          ),
      ],
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
              style: NileTextStyles.bodyMd().copyWith(color: NileColors.txtSecondary),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
