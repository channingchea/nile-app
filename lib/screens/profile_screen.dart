import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/block_service.dart';
import '../services/share_urls.dart';
import '../services/event_service.dart';
import '../services/follow_service.dart';
import '../services/message_service.dart';
import '../services/like_service.dart';
import '../services/post_service.dart';
import '../services/profile_service.dart';
import '../services/report_service.dart';
import '../services/repost_service.dart';
import '../router.dart';
import '../theme.dart';
import '../widgets/event_cover_pill.dart';
import '../widgets/event_link_card.dart';
import '../widgets/nile_cover_action.dart';
import '../widgets/nile_desktop.dart';
import '../widgets/nile_glass_nav_bar.dart';
import '../widgets/official_badge.dart';
import '../widgets/nile_skeleton.dart';
import '../widgets/photo_viewer.dart';
import '../widgets/post_image_carousel.dart';
import '../widgets/share_to_sheet.dart';
import 'widgets/moderation_menu.dart';
import 'follow_list_screen.dart';
import 'widgets/load_more_footer.dart';
import '../services/pagination.dart' show Paged;

class ProfileScreen extends StatefulWidget {
  /// Pass [userId] to view another user's profile.
  /// Omit (or pass null) to view the signed-in user's own profile.
  final String? userId;

  const ProfileScreen({super.key, this.userId});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

// Profile merges posts + events into one list, capped at 12 items per page.
// Sources are fetched a page at a time and the merged list is revealed in
// 12-item slices.
const int _kProfilePageSize = 12;

enum _ProfileTab { posts, events, drafts }

class _ProfileScreenState extends State<ProfileScreen> {
  UserProfile? _profile;
  bool _loading = true;
  String? _error;

  // ── Events + posts created by this profile ────────────────────────────────
  List<Event>? _events;
  List<Post>? _posts;
  // Reposts made by this profile (post/event + repost time), loaded once.
  List<({Post post, DateTime repostedAt})> _reposts = [];
  List<({Event event, DateTime repostedAt})> _eventReposts = [];
  String? _eventsError;

  // ── Active tab (Posts / Events for everyone; Drafts owner-only) ───────────
  _ProfileTab _tab = _ProfileTab.posts;

  // ── Drafts (owner-only third tab) ─────────────────────────────────────────
  List<Event>? _drafts;
  String? _draftsError;
  String? _draftsCursor;
  bool _draftsHasMore = false;
  bool _draftsLoading = false;

  // Pagination — independent cursors per source, but a single combined
  // display window. _visibleCount items of the merged list are shown; each
  // Load More grows it by _kProfilePageSize, topping up sources as needed.
  final _scroll = ScrollController();
  String? _uid;
  String? _postCursor;
  String? _eventCursor;
  bool _postsHasMore = false;
  bool _eventsHasMore = false;
  bool _loadingMore = false;
  int _visibleCount = _kProfilePageSize;

  // More to show if the active tab's source has un-fetched rows, or its
  // filtered list already holds more than the current display window.
  bool get _hasMore {
    if (_tab == _ProfileTab.posts && _postsHasMore) return true;
    if (_tab == _ProfileTab.events && _eventsHasMore) return true;
    final all = _allItems;
    return all != null && all.length > _visibleCount;
  }

  // ── Follow state ──────────────────────────────────────────────────────────
  bool _isFollowing = false;
  bool _followLoading = false;

  // ── Block state ───────────────────────────────────────────────────────────
  bool _isBlocked = false;

  static const double _coverHeight = 160;
  static const double _avatarRadius = 44;

  bool get _isOwnProfile {
    final myId = Supabase.instance.client.auth.currentUser?.id;
    return myId != null && (_profile?.id == myId);
  }

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
    // Not `hasClients`: resizing across the desktop breakpoint swaps the body,
    // and for one frame the old and new scroll views are both attached to this
    // controller — `position` asserts on that. Identical to `hasClients` on a
    // phone, which only ever has the one.
    if (_scroll.positions.length != 1) return;
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 400) {
      return;
    }
    if (_tab == _ProfileTab.drafts) {
      _loadMoreDrafts();
    } else if (_hasMore && !_loadingMore && _events != null) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uid =
          widget.userId ?? Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) throw Exception('Not signed in');

      final profile = await ProfileService.fetchProfile(uid);
      if (profile == null) throw Exception('Profile not found');

      // Load follow + block state for other people's profiles
      bool following = false;
      bool blocked = false;
      if (!_isOwnProfileFor(profile)) {
        (following, blocked) = await (
          FollowService.isFollowing(profile.id),
          BlockService.isBlocked(profile.id),
        ).wait;
      }

      setState(() {
        _profile = profile;
        _isFollowing = following;
        _isBlocked = blocked;
      });

      // Fire-and-forget events fetch — profile renders without it.
      _loadEvents(uid);
      // Refresh drafts too if the owner has the tab open / loaded.
      if (_isOwnProfileFor(profile) &&
          (_tab == _ProfileTab.drafts || _drafts != null)) {
        _loadDrafts();
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _loadEvents(String userId) async {
    _uid = userId;
    setState(() {
      _events = null;
      _posts = null;
      _reposts = [];
      _eventReposts = [];
      _eventsError = null;
      _visibleCount = _kProfilePageSize;
    });
    try {
      final (eventPage, postPage) = await (
        EventService.getEventsByHost(userId, limit: _kProfilePageSize),
        PostService.getByAuthor(userId, limit: _kProfilePageSize),
      ).wait;
      // This profile's reposts (posts + events) — best-effort, loaded once.
      List<({Post post, DateTime repostedAt})> repostRows = [];
      List<({Event event, DateTime repostedAt})> eventRepostRows = [];
      try {
        (repostRows, eventRepostRows) = await (
          PostService.getRepostsFeed([userId]),
          EventService.getRepostsFeed([userId]),
        ).wait;
      } catch (_) {}
      final (hEvents, lPosts, lReposts, lEventReposts) = await (
        EventService.hydrateLikes(eventPage.items),
        PostService.hydrateLikes(postPage.items),
        PostService.hydrateLikes(repostRows.map((r) => r.post).toList()),
        EventService.hydrateLikes(eventRepostRows.map((r) => r.event).toList()),
      ).wait;
      final (hPosts, hReposts, hEventReposts) = await (
        PostService.hydrateReposts(lPosts),
        PostService.hydrateReposts(lReposts),
        EventService.hydrateReposts(lEventReposts),
      ).wait;
      final repostAt = {for (final r in repostRows) r.post.id: r.repostedAt};
      final eventRepostAt = {
        for (final r in eventRepostRows) r.event.id: r.repostedAt,
      };
      if (!mounted) return;
      setState(() {
        _events = hEvents;
        _posts = hPosts;
        _reposts = [
          for (final p in hReposts)
            (post: p, repostedAt: repostAt[p.id] ?? p.createdAt),
        ];
        _eventReposts = [
          for (final e in hEventReposts)
            (event: e, repostedAt: eventRepostAt[e.id] ?? e.createdAt),
        ];
        _eventCursor = eventPage.nextCursor;
        _postCursor = postPage.nextCursor;
        _eventsHasMore = eventPage.hasMore;
        _postsHasMore = postPage.hasMore;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _eventsError = e.toString());
    }
  }

  /// Load the owner's drafts on first switch to the Drafts tab (and on refresh).
  Future<void> _loadDrafts() async {
    setState(() {
      _draftsLoading = true;
      _draftsError = null;
    });
    try {
      final page = await EventService.getDrafts(limit: _kProfilePageSize);
      if (!mounted) return;
      setState(() {
        _drafts = page.items;
        _draftsCursor = page.nextCursor;
        _draftsHasMore = page.hasMore;
        _draftsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _draftsError = e.toString();
        _draftsLoading = false;
      });
    }
  }

  Future<void> _loadMoreDrafts() async {
    if (!_draftsHasMore || _draftsLoading) return;
    setState(() => _draftsLoading = true);
    try {
      final page = await EventService.getDrafts(
        cursor: _draftsCursor,
        limit: _kProfilePageSize,
      );
      if (!mounted) return;
      setState(() {
        _drafts = [...?_drafts, ...page.items];
        _draftsCursor = page.nextCursor;
        _draftsHasMore = page.hasMore;
        _draftsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _draftsLoading = false);
    }
  }

  /// Open a draft in the editor. Saving there publishes it, so on return we
  /// drop it from the drafts list and refresh the public events list.
  Future<void> _openDraft(Event draft) async {
    final published = await context.push<Event>(
      NileRoutes.eventEdit(draft.id),
      extra: draft,
    );
    if (published != null && !published.isDraft) {
      setState(() => _drafts?.removeWhere((d) => d.id == draft.id));
      if (_profile != null) _loadEvents(_profile!.id);
    }
  }

  void _selectTab(_ProfileTab tab) {
    if (_tab == tab) return;
    setState(() {
      _tab = tab;
      _visibleCount = _kProfilePageSize;
    });
    if (tab == _ProfileTab.drafts && _drafts == null && !_draftsLoading) {
      _loadDrafts();
    }
  }

  Future<void> _loadMore() async {
    final uid = _uid;
    if (uid == null) return;
    setState(() => _loadingMore = true);
    try {
      // Grow the combined window by one page.
      final target = _visibleCount + _kProfilePageSize;

      // Top up only the active tab's source, and only if it has more rows AND
      // its fetched count can't already fill the new window on its own.
      final fetchEvents = _tab == _ProfileTab.events &&
          _eventsHasMore &&
          (_events?.length ?? 0) < target;
      final fetchPosts = _tab == _ProfileTab.posts &&
          _postsHasMore &&
          (_posts?.length ?? 0) < target;

      final (eventPage, postPage) = await (
        fetchEvents
            ? EventService.getEventsByHost(
                uid,
                cursor: _eventCursor,
                limit: _kProfilePageSize,
              )
            : Future.value(Paged.empty<Event>()),
        fetchPosts
            ? PostService.getByAuthor(
                uid,
                cursor: _postCursor,
                limit: _kProfilePageSize,
              )
            : Future.value(Paged.empty<Post>()),
      ).wait;
      final (hEvents, lPosts) = await (
        EventService.hydrateLikes(eventPage.items),
        PostService.hydrateLikes(postPage.items),
      ).wait;
      final hPosts = await PostService.hydrateReposts(lPosts);
      if (!mounted) return;
      setState(() {
        _visibleCount = target;
        _events = [...?_events, ...hEvents];
        _posts = [...?_posts, ...hPosts];
        if (fetchEvents) {
          _eventCursor = eventPage.nextCursor;
          _eventsHasMore = eventPage.hasMore;
        }
        if (fetchPosts) {
          _postCursor = postPage.nextCursor;
          _postsHasMore = postPage.hasMore;
        }
      });
    } catch (_) {
      // Keep existing; scrolling retries.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _togglePostLike(Post post) async {
    final wasLiked = post.likedByMe;
    final delta = wasLiked ? -1 : 1;
    _replacePost(
      post.copyWith(
        likedByMe: !wasLiked,
        likeCount: (post.likeCount + delta).clamp(0, 1 << 30),
      ),
    );
    try {
      wasLiked
          ? await LikeService.unlikePost(post.id)
          : await LikeService.likePost(post.id);
    } catch (_) {
      _replacePost(post);
    }
  }

  Future<void> _togglePostRepost(Post post) async {
    final was = post.repostedByMe;
    final delta = was ? -1 : 1;
    _replacePost(
      post.copyWith(
        repostedByMe: !was,
        repostCount: (post.repostCount + delta).clamp(0, 1 << 30),
      ),
    );
    try {
      was
          ? await RepostService.unrepost(post.id)
          : await RepostService.repost(post.id);
      // The reposted item itself appears/disappears in this profile's list;
      // reload so it shows up immediately rather than on next manual refresh.
      if (_isOwnProfile && _profile != null) _loadEvents(_profile!.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(was ? 'Removed repost' : 'Reposted to your profile'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      _replacePost(post);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to repost')));
    }
  }

  /// The active tab's list sorted by recency (Posts incl. post reposts;
  /// Events incl. event reposts). Live events pin to top.
  List<_ProfileItem>? get _allItems {
    if (_events == null || _posts == null) return null;
    final items = _tab == _ProfileTab.events
        ? <_ProfileItem>[
            ..._events!.map(_ProfileEventItem.new),
            ..._eventReposts.map(
              (r) => _ProfileEventItem(r.event, sortOverride: r.repostedAt),
            ),
          ]
        : <_ProfileItem>[
            ..._posts!.map(_ProfilePostItem.new),
            ..._reposts.map(
              (r) => _ProfilePostItem(r.post, sortOverride: r.repostedAt),
            ),
          ];
    items.sort((a, b) {
      final aLive = a is _ProfileEventItem && a.event.isLive;
      final bLive = b is _ProfileEventItem && b.event.isLive;
      if (aLive != bLive) return aLive ? -1 : 1;
      return b.sortKey.compareTo(a.sortKey);
    });
    return items;
  }

  // The visible slice — capped at _visibleCount (combined cap of 12 per page).
  List<_ProfileItem>? get _profileItems {
    final all = _allItems;
    if (all == null) return null;
    return all.length > _visibleCount ? all.sublist(0, _visibleCount) : all;
  }

  /// The event this profile has on air right now, if any.
  ///
  /// Read off the events already loaded for the grid rather than asking the
  /// server again: [EventService.getLiveNow] excludes the caller, so it can't
  /// answer this for your own profile at all, and a second query would race the
  /// first for no gain. The miss case is a host who has created a full page of
  /// events since the one they are currently streaming — rare enough to accept.
  Event? get _liveEvent {
    for (final e in _events ?? const <Event>[]) {
      if (e.isLive) return e;
    }
    return null;
  }

  /// Helper used during load — before _profile is set, we can't use the
  /// `_isOwnProfile` getter, so we pass the freshly-fetched profile directly.
  bool _isOwnProfileFor(UserProfile p) {
    final myId = Supabase.instance.client.auth.currentUser?.id;
    return myId != null && p.id == myId;
  }

  Future<void> _openEdit() async {
    if (_profile == null) return;
    final updated = await context.push<UserProfile>(
      NileRoutes.settingsEditProfile,
      extra: _profile!,
    );
    if (updated != null) setState(() => _profile = updated);
  }

  Future<void> _openSettings() async {
    if (_profile == null) return;
    final updated = await context.push<UserProfile>(
      NileRoutes.settings,
      extra: _profile!,
    );
    if (updated != null) setState(() => _profile = updated);
  }

  Future<void> _toggleFollow() async {
    if (_profile == null || _followLoading) return;
    setState(() => _followLoading = true);

    // Optimistic update
    final wasFollowing = _isFollowing;
    final delta = wasFollowing ? -1 : 1;
    setState(() {
      _isFollowing = !wasFollowing;
      _profile = _profile!.copyWith(
        followerCount: (_profile!.followerCount + delta).clamp(0, 999999999),
      );
    });

    try {
      if (wasFollowing) {
        await FollowService.unfollow(_profile!.id);
      } else {
        await FollowService.follow(_profile!.id);
      }
    } catch (e) {
      // Revert on failure
      setState(() {
        _isFollowing = wasFollowing;
        _profile = _profile!.copyWith(
          followerCount: (_profile!.followerCount - delta).clamp(0, 999999999),
        );
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Something went wrong: $e')));
      }
    } finally {
      if (mounted) setState(() => _followLoading = false);
    }
  }

  Future<void> _openDm() async {
    final p = _profile;
    if (p == null) return;
    try {
      final conv = await MessageService.getOrCreate(p.id);
      if (!mounted) return;
      await context.push(NileRoutes.dm(p.id), extra: conv);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open conversation: $e')),
      );
    }
  }

  Future<void> _blockUser() async {
    final p = _profile;
    if (p == null) return;
    final ok = await Moderation.confirmBlock(
      context,
      userId: p.id,
      username: p.username,
    );
    if (ok && mounted) {
      // Blocking severs the relationship — leave the now-hidden profile.
      context.pop();
    }
  }

  Future<void> _unblockUser() async {
    final p = _profile;
    if (p == null) return;
    final ok = await Moderation.confirmUnblock(
      context,
      userId: p.id,
      username: p.username,
    );
    if (ok && mounted) setState(() => _isBlocked = false);
  }

  void _reportUser() {
    final p = _profile;
    if (p == null) return;
    Moderation.showReportSheet(
      context,
      targetType: ReportTargetType.user,
      targetId: p.id,
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Compact is the phone layout that shipped; everything wider renders inside
    // the desktop chrome, which already draws the rail, the top bar and back.
    final compact = NileBreakpoints.of(context).isCompact;

    if (_loading) {
      final heroTag = 'avatar-${widget.userId ?? Supabase.instance.client.auth.currentUser?.id}';
      return Scaffold(
        backgroundColor: NileColors.bgPage,
        body: NileMaxWidth(
          child: Stack(
            children: [
              SingleChildScrollView(
                child: NileSkeletonPulse(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Cover strip
                      const NileSkeleton(width: double.infinity, height: 120, radius: 0),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s16, NileSpacing.s16, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Hero(
                              tag: heroTag,
                              child: const NileSkeleton.circle(size: 72),
                            ),
                            const SizedBox(height: 12),
                            const NileSkeleton(width: 160, height: 16),
                            const SizedBox(height: 8),
                            const NileSkeleton(width: 100),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      const NileSkeletonList(count: 2),
                    ],
                  ),
                ),
              ),
              if (compact) _buildCoverBack(),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: NileColors.bgPage,
        body: NileMaxWidth(
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error!,
                      style: NileTextStyles.bodyMd().copyWith(
                        color: NileColors.error,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ),
              ),
              if (compact) _buildCoverBack(),
            ],
          ),
        ),
      );
    }

    final p = _profile!;

    if (!compact) {
      return Scaffold(
        backgroundColor: NileColors.bgPage,
        body: _buildDesktopBody(p),
      );
    }

    return Scaffold(
      backgroundColor: NileColors.bgPage,
      // No app bar — the cover photo is the top of the page. Back (when pushed)
      // and settings / menu float over the cover's top corners (_buildHeader).
      // Create "+" now lives in the glass nav bar (see home_screen.dart),
      // so the profile no longer renders its own FAB.
      body: NileMaxWidth(
        child: RefreshIndicator(
          color: NileColors.volt,
          onRefresh: _load,
          child: CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverToBoxAdapter(child: _buildHeader(p)),
              SliverToBoxAdapter(child: _buildTabToggle()),
              if (_isOwnProfile && _tab == _ProfileTab.drafts)
                _buildDraftsFeed()
              else
                _buildEventsFeed(),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Header ───────────────────────────────────────────────────────────────

  /// Back control over the cover's top-left corner, mirroring the action on the
  /// right. Hides itself on the Profile *tab* (nothing to pop) and appears on
  /// every pushed instance — see [NileCoverBackButton].
  Widget _buildCoverBack() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + NileSpacing.s8,
      left: NileSpacing.s8,
      child: const NileCoverBackButton(),
    );
  }

  /// Floating action over the cover's top corner: settings (own profile) or a
  /// report/block menu (other profiles). Dark disc keeps it legible on any cover.
  Widget _buildCoverActions() {
    if (_isOwnProfile) {
      return NileCoverAction(
        child: IconButton(
          icon: const Icon(Icons.settings_outlined, color: Colors.white),
          tooltip: 'Settings',
          onPressed: _openSettings,
        ),
      );
    }
    return NileCoverAction(
      child: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, color: Colors.white),
        color: NileColors.bgRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NileRadius.sm),
        ),
        onSelected: (v) {
          switch (v) {
            case 'report':
              _reportUser();
            case 'block':
              _blockUser();
            case 'unblock':
              _unblockUser();
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'report', child: Text('Report')),
          if (_isBlocked)
            const PopupMenuItem(value: 'unblock', child: Text('Unblock'))
          else
            PopupMenuItem(
              value: 'block',
              child: Text('Block', style: TextStyle(color: NileColors.error)),
            ),
        ],
      ),
    );
  }

  Widget _buildHeader(UserProfile p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Cover photo ─────────────────────────────────────────────────────
        // The cover is the top of the page (no app bar). Settings / menu floats
        // over its top corner, pushed clear of the status bar.
        // The avatar is rendered AFTER the cover (in the row below, pulled up),
        // so the cover never overlaps the avatar.
        Stack(
          children: [
            CoverPhoto(
              url: p.coverUrl,
              height: _coverHeight,
              showEditChip: false,
              // Tap the cover to view it full-screen.
              onTap: p.coverUrl == null
                  ? null
                  : () => PhotoViewerScreen.open(
                        context,
                        image: NetworkImage(p.coverUrl!),
                      ),
            ),
            _buildCoverBack(),
            Positioned(
              top: MediaQuery.of(context).padding.top + NileSpacing.s8,
              right: NileSpacing.s8,
              child: _buildCoverActions(),
            ),
          ],
        ),

        // ── Avatar + primary action, straddling the cover's bottom edge ─────
        Transform.translate(
          offset: const Offset(0, -_avatarRadius),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, NileSpacing.s16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                GestureDetector(
                  // Tap the avatar to view it full-screen.
                  onTap: p.avatarUrl == null
                      ? null
                      : () => PhotoViewerScreen.open(
                            context,
                            image: NetworkImage(p.avatarUrl!),
                            heroTag: 'avatar-${p.id}',
                          ),
                  child: Container(
                    padding: const EdgeInsets.all(NileSpacing.s4),
                    decoration: BoxDecoration(
                      color: NileColors.bgPage,
                      shape: BoxShape.circle,
                    ),
                    child: Hero(
                      tag: 'avatar-${p.id}',
                      child: CircleAvatar(
                        radius: _avatarRadius,
                        backgroundColor: NileColors.bgRaised,
                        backgroundImage: p.avatarUrl != null
                            ? nileAvatarImage(p.avatarUrl!, _avatarRadius)
                            : null,
                        child: p.avatarUrl == null
                            ? Icon(
                                Icons.person,
                                size: _avatarRadius,
                                color: NileColors.txtTertiary,
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                // Action button sits at the avatar's baseline, nudged DOWN a
                // little (Transform doesn't affect layout) so it clears the
                // cover's bottom edge instead of sitting nearly flush to it.
                Transform.translate(
                  offset: const Offset(0, NileSpacing.s16),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: NileSpacing.s8),
                    child: _headerAction(p),
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── Name, handle, bio, inline follow counts ─────────────────────────
        // Negative top margin claws back the avatar's translate so content
        // sits directly under it.
        Transform.translate(
          offset: const Offset(0, -_avatarRadius + NileSpacing.s4),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(NileSpacing.s16, 0, NileSpacing.s16, NileSpacing.s4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (p.isOfficial)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        child: Text(
                          p.displayName,
                          style: NileTextStyles.displayMd(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(left: NileSpacing.s6, top: 6),
                        child: OfficialBadge(size: 22),
                      ),
                    ],
                  )
                else
                  Text(
                    p.displayName,
                    style: NileTextStyles.displayMd(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 2),
                Text(
                  '@${p.username}',
                  style: NileTextStyles.bodyMd().copyWith(
                    color: NileColors.txtSecondary,
                  ),
                ),
                if (p.bio != null && p.bio!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(p.bio!, style: NileTextStyles.bodyMd()),
                ],
                const SizedBox(height: 16),
                _followCounts(p),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Primary header action: "Edit profile" for the owner, Follow + DM otherwise.
  Widget _headerAction(UserProfile p) {
    if (_isOwnProfile) {
      return OutlinedButton.icon(
        onPressed: _openEdit,
        icon: const Icon(Icons.edit_outlined, size: 16),
        label: const Text('Edit profile'),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _isFollowing
            ? OutlinedButton(
                onPressed: _followLoading ? null : _toggleFollow,
                child: _followLoading
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: NileColors.txtPrimary,
                        ),
                      )
                    : const Text('Following'),
              )
            : FilledButton(
                onPressed: _followLoading ? null : _toggleFollow,
                child: _followLoading
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: NileColors.onVolt,
                        ),
                      )
                    : const Text('Follow'),
              ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: _openDm,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: NileSpacing.s12,
              vertical: NileSpacing.s12,
            ),
          ),
          child: const Icon(Icons.send_outlined, size: 18),
        ),
      ],
    );
  }

  /// Inline "X following · Y followers", each segment tappable.
  Widget _followCounts(UserProfile p) {
    Widget seg(String value, String label, FollowListMode mode) {
      final location = mode == FollowListMode.followers
          ? NileRoutes.followers(p.id)
          : NileRoutes.following(p.id);
      return GestureDetector(
        onTap: () =>
            context.push('$location?name=${Uri.encodeComponent(p.username)}'),
        child: RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: value,
                style: NileTextStyles.labelMd().copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              TextSpan(
                text: ' $label',
                style: NileTextStyles.bodyMd().copyWith(
                  color: NileColors.txtSecondary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        seg(_fmt(p.followingCount), 'following', FollowListMode.following),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s12),
          child: Text(
            '·',
            style: NileTextStyles.bodyMd().copyWith(
              color: NileColors.txtTertiary,
            ),
          ),
        ),
        seg(_fmt(p.followerCount), 'followers', FollowListMode.followers),
      ],
    );
  }

  // ─── Desktop layout ───────────────────────────────────────────────────────
  // The profile fills the chrome's content column — up to 900 pt, against the
  // 600 the phone header was drawn for. A separate body rather than
  // conditionals through the phone one, for the reason EventDetailScreen gives.

  /// A 160 pt strip across a 900 pt column reads as a mistake rather than a
  /// cover, so the desktop banner is deeper and the avatar larger to match.
  static const double _kDesktopCoverHeight = 240;
  static const double _kDesktopAvatarRadius = 56;
  static const double _kDesktopAvatarDiameter =
      (_kDesktopAvatarRadius + NileSpacing.s4) * 2;

  /// Two columns at column width. Wider than the phone's tiles because the
  /// same title is set at a larger measure here.
  static const double _kDesktopTileWidth = 380;

  Widget _buildDesktopBody(UserProfile p) {
    final live = _liveEvent;
    return CustomScrollView(
      // Same controller as the phone body, so _onScroll still drives pagination.
      controller: _scroll,
      slivers: [
        SliverToBoxAdapter(child: _buildDesktopHeader(p)),
        if (live != null) SliverToBoxAdapter(child: _buildLiveBanner(live)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: NileSpacing.s24),
            child: _buildTabToggle(horizontalPadding: NileSpacing.s24),
          ),
        ),
        if (_isOwnProfile && _tab == _ProfileTab.drafts)
          _buildDraftsFeed(desktop: true)
        else
          _buildEventsFeed(desktop: true),
      ],
    );
  }

  /// Cover across the column, identity running horizontally beneath it: the
  /// avatar straddles the cover's bottom edge on the left, name / handle /
  /// counts sit beside it, the one action is on the right.
  ///
  /// Built as a Stack over a Column that reserves the cover's height, rather
  /// than the phone header's stack of negative Transforms. Everything stays
  /// inside the Stack's bounds that way, so the overhanging avatar is still
  /// tappable — a `Clip.none` overhang paints but does not hit-test.
  Widget _buildDesktopHeader(UserProfile p) {
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: _kDesktopCoverHeight),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NileSpacing.s24,
                NileSpacing.s16,
                NileSpacing.s24,
                0,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Holds the avatar's column; the avatar itself is painted by
                  // the Stack so it can overlap without any height arithmetic.
                  const SizedBox(
                    width: _kDesktopAvatarDiameter + NileSpacing.s24,
                  ),
                  Expanded(child: _desktopIdentity(p)),
                  const SizedBox(width: NileSpacing.s24),
                  _headerAction(p),
                ],
              ),
            ),
            if (p.bio != null && p.bio!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  NileSpacing.s24,
                  NileSpacing.s16,
                  NileSpacing.s24,
                  0,
                ),
                child: Text(p.bio!, style: NileTextStyles.bodyMd()),
              ),
          ],
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: CoverPhoto(
            url: p.coverUrl,
            height: _kDesktopCoverHeight,
            showEditChip: false,
            onTap: p.coverUrl == null
                ? null
                : () => PhotoViewerScreen.open(
                    context,
                    image: NetworkImage(p.coverUrl!),
                  ),
          ),
        ),
        // Settings / report-block menu stays: it acts on this profile and the
        // chrome has no equivalent. Back does not — the top bar carries it, and
        // two back buttons would be two.
        Positioned(
          top: NileSpacing.s12,
          right: NileSpacing.s12,
          child: _buildCoverActions(),
        ),
        Positioned(
          left: NileSpacing.s24,
          top: _kDesktopCoverHeight - _kDesktopAvatarDiameter / 2,
          child: _desktopAvatar(p),
        ),
      ],
    );
  }

  Widget _desktopAvatar(UserProfile p) {
    return GestureDetector(
      onTap: p.avatarUrl == null
          ? null
          : () => PhotoViewerScreen.open(
              context,
              image: NetworkImage(p.avatarUrl!),
              heroTag: 'avatar-${p.id}',
            ),
      child: Container(
        padding: const EdgeInsets.all(NileSpacing.s4),
        decoration: BoxDecoration(
          color: NileColors.bgPage,
          shape: BoxShape.circle,
        ),
        child: Hero(
          tag: 'avatar-${p.id}',
          child: CircleAvatar(
            radius: _kDesktopAvatarRadius,
            backgroundColor: NileColors.bgRaised,
            backgroundImage: p.avatarUrl != null
                ? nileAvatarImage(p.avatarUrl!, _kDesktopAvatarRadius)
                : null,
            child: p.avatarUrl == null
                ? Icon(
                    Icons.person,
                    size: _kDesktopAvatarRadius,
                    color: NileColors.txtTertiary,
                  )
                : null,
          ),
        ),
      ),
    );
  }

  /// Name, official badge, handle and follow counts as one block beside the
  /// avatar. The counts move up here from under the bio: at column width there
  /// is room for them on the identity line, which is where they are looked for.
  Widget _desktopIdentity(UserProfile p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: Text(
                p.displayName,
                style: NileTextStyles.displayMd(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (p.isOfficial)
              const Padding(
                padding: EdgeInsets.only(left: NileSpacing.s6, top: 6),
                child: OfficialBadge(size: 22),
              ),
          ],
        ),
        const SizedBox(height: NileSpacing.s2),
        Text(
          '@${p.username}',
          style: NileTextStyles.bodyMd().copyWith(
            color: NileColors.txtSecondary,
          ),
        ),
        const SizedBox(height: NileSpacing.s12),
        _followCounts(p),
      ],
    );
  }

  /// Coral band linking straight into the show this profile is running right
  /// now. Desktop only: on a phone the live event already pins to the top of
  /// the Events grid, and a banner as well would be the same link twice in a
  /// column that has no room to spare.
  Widget _buildLiveBanner(Event e) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NileSpacing.s24,
        NileSpacing.s24,
        NileSpacing.s24,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const NileSectionHeader(
            'On air now',
            accent: NileColors.coral,
            padding: EdgeInsets.only(bottom: NileSpacing.s12),
          ),
          NileHoverCard(
            builder: (_, hovered) => Material(
              // Coral is the ColorScheme's secondary, whose onSecondary is
              // white in both themes — so white is the token here, not a guess.
              color: NileColors.coral,
              child: InkWell(
                onTap: () => _openEvent(e),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NileSpacing.s24,
                    vertical: NileSpacing.s16,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              e.title,
                              style: NileTextStyles.headingSm().copyWith(
                                color: Colors.white,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: NileSpacing.s2),
                            Text(
                              '${e.viewerCount} watching',
                              style: NileTextStyles.bodySm()
                                  .copyWith(
                                    color: Colors.white.withValues(
                                      alpha: 0.85,
                                    ),
                                  )
                                  .tabular,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: NileSpacing.s16),
                      Text(
                        'Watch',
                        style: NileTextStyles.labelMd().copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: NileSpacing.s8),
                      AnimatedSlide(
                        offset: hovered ? const Offset(0.3, 0) : Offset.zero,
                        duration: NileMotion.fast,
                        curve: NileMotion.curve,
                        child: const Icon(
                          Icons.arrow_forward,
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The desktop grid for either tab, plus the paging footer the sliver list
  /// carries on the phone.
  Widget _desktopGrid(List<Widget> children, {bool showFooter = false}) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(
        NileSpacing.s24,
        NileSpacing.s24,
        NileSpacing.s24,
        NileSpacing.s48,
      ),
      sliver: SliverToBoxAdapter(
        // stretch, or a run that doesn't fill its columns gets centred and the
        // grid stops lining up with the header above it.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NileCardGrid(minItemWidth: _kDesktopTileWidth, children: children),
            if (showFooter) const LoadMoreFooter(),
          ],
        ),
      ),
    );
  }

  /// A cover tile at desktop proportions. The tile paints into a Stack sized by
  /// its parent, so the aspect ratio has to come from outside it.
  Widget _desktopEventTile(Event event, VoidCallback onTap) {
    return AspectRatio(
      aspectRatio: 3 / 2,
      child: NileHoverCard(
        builder: (_, _) => _ProfileEventTile(event: event, onTap: onTap),
      ),
    );
  }

  /// The phone's post card, unchanged, inside a grid cell. Every callback is
  /// the same one the sliver list passes — the card is the single source of
  /// truth for what a post does.
  Widget _desktopPostCard(Post post) {
    return NileHoverCard(
      builder: (_, _) => _ProfilePostCard(
        post: post,
        onEdited: _isOwnProfile ? (p) => _replacePost(p) : null,
        onDeleted: _isOwnProfile ? () => _removePost(post.id) : null,
        onLikeToggle: () => _togglePostLike(post),
        onRepostToggle: () => _togglePostRepost(post),
        onUpdated: _replacePost,
        profileId: _profile?.id,
      ),
    );
  }

  // ─── Tab toggle (Posts / Events for all; Drafts owner-only) ───────────────

  Widget _buildTabToggle({double horizontalPadding = NileSpacing.s16}) {
    // Underline tab: volt label + volt underline when active, muted otherwise.
    Widget seg(String label, bool selected, VoidCallback onTap) {
      return InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(right: NileSpacing.s24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: NileSpacing.s12),
                child: Text(
                  label,
                  style: NileTextStyles.labelMd().copyWith(
                    color: selected
                        ? NileColors.txtPrimary
                        : NileColors.txtTertiary,
                    fontWeight:
                        selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              AnimatedContainer(
                duration: NileMotion.fast,
                height: 2,
                width: 28,
                color: selected ? NileColors.volt : Colors.transparent,
              ),
            ],
          ),
        ),
      );
    }

    final draftCount = _drafts?.length;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: NileColors.border)),
      ),
      child: Row(
        children: [
          seg(
            'Events',
            _tab == _ProfileTab.events,
            () => _selectTab(_ProfileTab.events),
          ),
          seg(
            'Posts',
            _tab == _ProfileTab.posts,
            () => _selectTab(_ProfileTab.posts),
          ),
          if (_isOwnProfile)
            seg(
              draftCount != null && draftCount > 0
                  ? 'Drafts ($draftCount)'
                  : 'Drafts',
              _tab == _ProfileTab.drafts,
              () => _selectTab(_ProfileTab.drafts),
            ),
        ],
      ),
    );
  }

  // ─── Drafts feed (owner-only) ─────────────────────────────────────────────

  Widget _buildDraftsFeed({bool desktop = false}) {
    if (_draftsError != null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(NileSpacing.s32),
          child: Center(
            child: Text(
              'Couldn\'t load drafts: $_draftsError',
              textAlign: TextAlign.center,
              style: NileTextStyles.bodySm().copyWith(color: NileColors.error),
            ),
          ),
        ),
      );
    }
    final drafts = _drafts;
    if (drafts == null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(NileSpacing.s40),
          child: Center(
            child: CircularProgressIndicator(color: NileColors.volt),
          ),
        ),
      );
    }
    if (drafts.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(NileSpacing.s40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.drafts_outlined,
                size: 48,
                color: NileColors.border,
              ),
              const SizedBox(height: 12),
              Text('No drafts', style: NileTextStyles.headingSm()),
              const SizedBox(height: 4),
              Text(
                'Events you save as drafts will appear here until you publish them.',
                textAlign: TextAlign.center,
                style: NileTextStyles.bodySm(),
              ),
            ],
          ),
        ),
      );
    }
    if (desktop) {
      return _desktopGrid(
        [
          for (final draft in drafts)
            _desktopEventTile(draft, () => _openDraft(draft)),
        ],
        showFooter: _draftsHasMore,
      );
    }
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s16, NileSpacing.s16, NileGlassNavBar.reservedHeight + NileSpacing.s16),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.82,
        ),
        delegate: SliverChildBuilderDelegate((_, i) {
          final draft = drafts[i];
          return _ProfileEventTile(
            event: draft,
            onTap: () => _openDraft(draft),
          );
        }, childCount: drafts.length),
      ),
    );
  }

  // ─── Events feed ──────────────────────────────────────────────────────────

  Widget _buildEventsFeed({bool desktop = false}) {
    if (_eventsError != null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(NileSpacing.s32),
          child: Center(
            child: Text(
              'Couldn\'t load posts: $_eventsError',
              textAlign: TextAlign.center,
              style: NileTextStyles.bodySm().copyWith(color: NileColors.error),
            ),
          ),
        ),
      );
    }
    final items = _profileItems;
    if (items == null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(NileSpacing.s40),
          child: Center(
            child: CircularProgressIndicator(color: NileColors.volt),
          ),
        ),
      );
    }
    if (items.isEmpty) {
      final isEvents = _tab == _ProfileTab.events;
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(NileSpacing.s40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isEvents ? Icons.event_note : Icons.edit_note,
                size: 48,
                color: NileColors.border,
              ),
              const SizedBox(height: 12),
              Text(
                isEvents ? 'No events yet' : 'No posts yet',
                style: NileTextStyles.headingSm(),
              ),
              const SizedBox(height: 4),
              Text(
                _isOwnProfile
                    ? (isEvents
                          ? 'Events you create will appear here.'
                          : 'Posts you create will appear here.')
                    : 'Check back later.',
                textAlign: TextAlign.center,
                style: NileTextStyles.bodySm(),
              ),
            ],
          ),
        ),
      );
    }
    // Desktop → both tabs become a multi-column grid. Item type rather than
    // tab drives the tile, so a repost lands on the right card either way.
    if (desktop) {
      final children = <Widget>[];
      for (final it in items) {
        switch (it) {
          case _ProfileEventItem(:final event):
            children.add(_desktopEventTile(event, () => _openEvent(event)));
          case _ProfilePostItem(:final post):
            children.add(_desktopPostCard(post));
        }
      }
      return _desktopGrid(children, showFooter: _hasMore);
    }
    // Events tab → 2-column grid of cover tiles. Posts tab → full-width cards.
    if (_tab == _ProfileTab.events) {
      return SliverPadding(
        padding: EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s16, NileSpacing.s16, NileGlassNavBar.reservedHeight + NileSpacing.s16),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.82,
          ),
          delegate: SliverChildBuilderDelegate((_, i) {
            final it = items[i] as _ProfileEventItem;
            return _ProfileEventTile(
              event: it.event,
              onTap: () => _openEvent(it.event),
            );
          }, childCount: items.length),
        ),
      );
    }
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(NileSpacing.s16, NileSpacing.s16, NileSpacing.s16, NileGlassNavBar.reservedHeight + NileSpacing.s16),
      sliver: SliverList.separated(
        itemCount: items.length + (_hasMore ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (_, i) {
          if (i >= items.length) return const LoadMoreFooter();
          final it = items[i] as _ProfilePostItem;
          final post = it.post;
          return _ProfilePostCard(
            post: post,
            onEdited: _isOwnProfile ? (p) => _replacePost(p) : null,
            onDeleted: _isOwnProfile ? () => _removePost(post.id) : null,
            onLikeToggle: () => _togglePostLike(post),
            onRepostToggle: () => _togglePostRepost(post),
            onUpdated: _replacePost,
            profileId: _profile?.id,
          );
        },
      ),
    );
  }

  void _replacePost(Post updated) => setState(() {
    final i = _posts?.indexWhere((p) => p.id == updated.id) ?? -1;
    if (i >= 0) _posts![i] = updated;
    // Reposted cards live in [_reposts]; keep them in sync too.
    for (var j = 0; j < _reposts.length; j++) {
      if (_reposts[j].post.id == updated.id) {
        _reposts[j] = (post: updated, repostedAt: _reposts[j].repostedAt);
      }
    }
  });

  void _removePost(String postId) => setState(() {
    _posts?.removeWhere((p) => p.id == postId);
    _reposts.removeWhere((r) => r.post.id == postId);
  });

  void _openEvent(Event e) {
    // Guard: never open a blocked host's stream, even from a stale card.
    if (_isBlocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You\'ve blocked this account.')),
      );
      return;
    }
    final location = NileRoutes.eventOrWatch(
      isLive: e.isLive,
      eventId: e.id,
      liveKitEventId: e.liveKitEventId,
      fromProfileId: _profile?.id,
    );
    context.push(location, extra: e).then((_) {
      // Refresh on return in case the host edited or ended the event.
      if (_profile != null) _loadEvents(_profile!.id);
    });
  }

  String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return n.toString();
  }
}

// ─── Cover photo widget (public — also used by EditProfileScreen) ─────────────

class CoverPhoto extends StatelessWidget {
  final String? url;
  final double height;
  final Uint8List? localBytes;
  final VoidCallback? onTap;

  /// EditProfileScreen taps to change the cover, so it shows the camera chip;
  /// ProfileScreen taps to view it full-screen, so it hides the chip.
  final bool showEditChip;

  const CoverPhoto({
    super.key,
    this.url,
    required this.height,
    this.localBytes,
    this.onTap,
    this.showEditChip = true,
  });

  @override
  Widget build(BuildContext context) {
    ImageProvider? image;
    if (localBytes != null) {
      image = MemoryImage(localBytes!);
    } else if (url != null) {
      image = ResizeImage(NetworkImage(url!), width: nileDecodeWidth(600));
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: height,
        width: double.infinity,
        decoration: BoxDecoration(
          color: NileColors.bgRaised,
          image: image != null
              ? DecorationImage(image: image, fit: BoxFit.cover)
              : null,
        ),
        child: image == null
            ? const _CoverPlaceholder()
            : (onTap != null && showEditChip)
            ? _editOverlay()
            : null,
      ),
    );
  }

  Widget _editOverlay() {
    return Container(
      alignment: Alignment.bottomRight,
      padding: const EdgeInsets.all(NileSpacing.s12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            NileColors.bgPage.withValues(alpha: 0.4),
          ],
        ),
      ),
      child: buildCameraChip('Edit cover'),
    );
  }
}

/// Public helper — renders the pill-shaped camera chip used on cover photos.
Widget buildCameraChip(String label) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s8, vertical: NileSpacing.s4),
    decoration: BoxDecoration(
      color: NileColors.bgPage.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(NileRadius.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.camera_alt, size: 14, color: NileColors.txtPrimary),
        const SizedBox(width: 4),
        Text(
          label,
          style: NileTextStyles.caption().copyWith(
            color: NileColors.txtPrimary,
            letterSpacing: 0,
          ),
        ),
      ],
    ),
  );
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [NileColors.bgRaised, NileColors.bgSurface],
        ),
      ),
    );
  }
}

// ─── Profile feed item types ─────────────────────────────────────────────────

sealed class _ProfileItem {
  DateTime get sortKey;
}

class _ProfileEventItem extends _ProfileItem {
  final Event event;

  /// Set for reposts — sorts by repost time.
  final DateTime? sortOverride;
  _ProfileEventItem(this.event, {this.sortOverride});
  @override
  DateTime get sortKey => sortOverride ?? event.scheduledAt ?? event.createdAt;
}

class _ProfilePostItem extends _ProfileItem {
  final Post post;

  /// Set for reposts — sorts by repost time instead of the post's createdAt.
  final DateTime? sortOverride;
  _ProfilePostItem(this.post, {this.sortOverride});
  @override
  DateTime get sortKey => sortOverride ?? post.createdAt;
}

// ─── Post card (profile feed) ────────────────────────────────────────────────

class _ProfilePostCard extends StatelessWidget {
  final Post post;
  final void Function(Post)? onEdited;
  final VoidCallback? onDeleted;
  final VoidCallback? onLikeToggle;
  final VoidCallback? onRepostToggle;
  final void Function(Post)? onUpdated;

  /// Id of the profile being viewed — lets the detail screen pop back here
  /// instead of pushing a duplicate profile when its author row is tapped.
  final String? profileId;

  const _ProfilePostCard({
    required this.post,
    this.onEdited,
    this.onDeleted,
    this.onLikeToggle,
    this.onRepostToggle,
    this.onUpdated,
    this.profileId,
  });

  String _shareText() =>
      ShareUrls.postCaption(id: post.id, authorUsername: post.authorUsername);

  Future<void> _openDetail(BuildContext context) async {
    final updated = await context.push<Post>(
      NileRoutes.post(post.id, fromProfileId: profileId),
      extra: post,
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
      borderRadius: BorderRadius.circular(NileRadius.lg),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openDetail(context),
        child: Padding(
          padding: const EdgeInsets.all(NileSpacing.s12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (post.repostedByUsername != null) ...[
                _ProfileRepostHeader(username: post.repostedByUsername!),
                const SizedBox(height: 8),
              ],
              Row(
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: NileColors.bgRaised,
                    backgroundImage: post.authorAvatarUrl != null
                        ? nileAvatarImage(post.authorAvatarUrl!, 14)
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
                  if (onEdited != null || onDeleted != null)
                    _ProfileContentMenu(
                      onEdit: onEdited == null
                          ? null
                          : () async {
                              final updated = await context.push<Post>(
                                NileRoutes.postEdit(post.id),
                                extra: post,
                              );
                              if (updated != null) onEdited!(updated);
                            },
                      onDelete: onDeleted == null
                          ? null
                          : () async {
                              final ok = await _confirmProfileDelete(
                                context,
                                'post',
                              );
                              if (ok) {
                                try {
                                  await PostService.delete(post.id);
                                  onDeleted!();
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('Failed to delete: $e'),
                                      ),
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
                Text(post.caption!.trim(), style: NileTextStyles.bodyMd()),
              ],
              if (post.hasImage) ...[
                const SizedBox(height: 10),
                PostImageCarousel(imageUrls: post.images),
              ],
              if (post.eventId != null) ...[
                const SizedBox(height: 10),
                EventLinkCard(eventId: post.eventId!),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  if (onLikeToggle != null)
                    _LikeRow(
                      liked: post.likedByMe,
                      count: post.likeCount,
                      onTap: onLikeToggle!,
                    ),
                  const SizedBox(width: 16),
                  InkWell(
                    onTap: () => _openDetail(context),
                    borderRadius: BorderRadius.circular(NileRadius.sm),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: NileSpacing.s4,
                        vertical: NileSpacing.s4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
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
                    ),
                  ),
                  if (onRepostToggle != null) ...[
                    const SizedBox(width: 16),
                    _RepostRow(
                      reposted: post.repostedByMe,
                      count: post.repostCount,
                      onTap: onRepostToggle!,
                    ),
                  ],
                  const Spacer(),
                  InkWell(
                    onTap: () => ShareToSheet.show(
                      context,
                      postId: post.id,
                      shareText: _shareText(),
                    ),
                    borderRadius: BorderRadius.circular(NileRadius.sm),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: NileSpacing.s4, vertical: NileSpacing.s4),
                      child: Icon(
                        Icons.send_outlined,
                        size: 18,
                        color: NileColors.txtSecondary,
                      ),
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

// ─── Repost header + row (profile) ───────────────────────────────────────────

class _ProfileRepostHeader extends StatelessWidget {
  final String username;
  const _ProfileRepostHeader({required this.username});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.repeat, size: 14, color: NileColors.txtTertiary),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            'reposted by @$username',
            style: NileTextStyles.caption(),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _RepostRow extends StatelessWidget {
  final bool reposted;
  final int count;
  final VoidCallback onTap;
  const _RepostRow({
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
        padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s4, vertical: NileSpacing.s4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.repeat, size: 18, color: color),
            const SizedBox(width: 5),
            Text(
              '$count',
              style: NileTextStyles.bodySm().copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Like row (shared in profile) ────────────────────────────────────────────

class _LikeRow extends StatelessWidget {
  final bool liked;
  final int count;
  final VoidCallback onTap;
  const _LikeRow({
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
        padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s4, vertical: NileSpacing.s4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              liked ? Icons.favorite : Icons.favorite_border,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 5),
            Text(
              '$count',
              style: NileTextStyles.bodySm().copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Event tile (profile grid) ───────────────────────────────────────────────

class _ProfileEventTile extends StatelessWidget {
  final Event event;
  final VoidCallback onTap;
  const _ProfileEventTile({required this.event, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cover = event.coverImageUrl;
    return Material(
      color: NileColors.bgSurface,
      borderRadius: BorderRadius.circular(NileRadius.lg),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Cover photo, or a gradient placeholder when none was set.
            if (cover != null)
              Image.network(
                cover,
                cacheWidth: nileDecodeWidth(300),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    EventCoverPlaceholder(seed: event.id),
              )
            else
              EventCoverPlaceholder(seed: event.id),
            const DecoratedBox(decoration: NileEffects.coverScrim),
            // Status / date pill, top-left.
            Positioned(
              top: NileSpacing.s12,
              left: NileSpacing.s12,
              child: EventCoverPill(event: event),
            ),
            // Title overlaid at the bottom.
            Positioned(
              left: NileSpacing.s12,
              right: NileSpacing.s12,
              bottom: NileSpacing.s12,
              child: Text(
                event.title,
                style: NileTextStyles.headingSm().copyWith(
                  color: Colors.white,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Profile screen edit/delete helpers ───────────────────────────────────────

Future<bool> _confirmProfileDelete(
  BuildContext context,
  String itemType,
) async {
  return await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: NileColors.bgSurface,
          title: Text('Delete $itemType?', style: NileTextStyles.headingSm()),
          content: Text(
            'This cannot be undone.',
            style: NileTextStyles.bodyMd().copyWith(
              color: NileColors.txtSecondary,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Delete', style: TextStyle(color: NileColors.error)),
            ),
          ],
        ),
      ) ==
      true;
}

class _ProfileContentMenu extends StatelessWidget {
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  const _ProfileContentMenu({this.onEdit, this.onDelete});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      icon: Icon(
        Icons.more_horiz,
        size: 18,
        color: NileColors.txtTertiary,
      ),
      color: NileColors.bgRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
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
            child: Text('Delete', style: TextStyle(color: NileColors.error)),
          ),
      ],
    );
  }
}
