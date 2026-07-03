import 'dart:typed_data';
import 'package:flutter/material.dart';
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
import '../theme.dart';
import '../widgets/event_cover_pill.dart';
import '../widgets/nile_glass_app_bar.dart';
import '../widgets/event_link_card.dart';
import '../widgets/nile_glass_nav_bar.dart';
import '../widgets/nile_skeleton.dart';
import '../widgets/post_image_carousel.dart';
import '../widgets/share_to_sheet.dart';
import 'widgets/moderation_menu.dart';
import 'post_detail_screen.dart';
import 'settings_screen.dart';
import 'edit_event_screen.dart';
import 'edit_post_screen.dart';
import 'edit_profile_screen.dart';
import 'event_detail_screen.dart';
import 'conversation_screen.dart';
import 'follow_list_screen.dart';
import 'viewer_screen.dart';
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
    if (!_scroll.hasClients) return;
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
    final published = await Navigator.push<Event>(
      context,
      MaterialPageRoute(builder: (_) => EditEventScreen(event: draft)),
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

  /// Helper used during load — before _profile is set, we can't use the
  /// `_isOwnProfile` getter, so we pass the freshly-fetched profile directly.
  bool _isOwnProfileFor(UserProfile p) {
    final myId = Supabase.instance.client.auth.currentUser?.id;
    return myId != null && p.id == myId;
  }

  Future<void> _openEdit() async {
    if (_profile == null) return;
    final updated = await Navigator.of(context).push<UserProfile>(
      MaterialPageRoute(builder: (_) => EditProfileScreen(profile: _profile!)),
    );
    if (updated != null) setState(() => _profile = updated);
  }

  Future<void> _openSettings() async {
    if (_profile == null) return;
    final updated = await Navigator.push<UserProfile>(
      context,
      MaterialPageRoute(builder: (_) => SettingsScreen(profile: _profile!)),
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
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ConversationScreen(conversation: conv),
        ),
      );
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
      Navigator.of(context).pop();
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
    if (_loading) {
      final heroTag = 'avatar-${widget.userId ?? Supabase.instance.client.auth.currentUser?.id}';
      return Scaffold(
        backgroundColor: NileColors.bgPage,
        body: NileMaxWidth(
          child: SingleChildScrollView(
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
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: NileColors.bgPage,
        body: Center(
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
      );
    }

    final p = _profile!;

    return Scaffold(
      backgroundColor: NileColors.bgPage,
      // Content scrolls behind the translucent glass app bar.
      extendBodyBehindAppBar: true,
      // AppBar sits above the cover — keep it minimal.
      appBar: NileGlassBar.appBar(
        title: Text('@${p.username}', style: NileTextStyles.headingSm()),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
          if (_isOwnProfile)
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
              onPressed: _openSettings,
            )
          else
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
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
                    child: Text(
                      'Block',
                      style: TextStyle(color: NileColors.error),
                    ),
                  ),
              ],
            ),
        ],
      ),
      // Create "+" now lives in the glass nav bar (see home_screen.dart),
      // so the profile no longer renders its own FAB.
      body: NileMaxWidth(
        child: RefreshIndicator(
          color: NileColors.volt,
          onRefresh: _load,
          child: CustomScrollView(
            controller: _scroll,
            slivers: [
              // Spacer so the cover starts below the glass bar (not cut by it),
              // matching the home feed; content still scrolls up behind it.
              SliverToBoxAdapter(
                child: SizedBox(
                  height: MediaQuery.of(context).padding.top + kToolbarHeight,
                ),
              ),
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

  Widget _buildHeader(UserProfile p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Cover photo ─────────────────────────────────────────────────────
        // The avatar is rendered AFTER the cover (in the row below, pulled up),
        // so the cover never overlaps the avatar.
        CoverPhoto(url: p.coverUrl, height: _coverHeight),

        // ── Avatar + primary action, straddling the cover's bottom edge ─────
        Transform.translate(
          offset: const Offset(0, -_avatarRadius),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, NileSpacing.s16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.all(NileSpacing.s4),
                  decoration: const BoxDecoration(
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
                const Spacer(),
                // Action button sits at the avatar's baseline (its bottom),
                // matching the "Edit profile" placement in the design.
                Padding(
                  padding: const EdgeInsets.only(bottom: NileSpacing.s8),
                  child: _headerAction(p),
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
                Text(p.displayName, style: NileTextStyles.displayMd()),
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
                    ? const SizedBox(
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
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: NileColors.bgPage,
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
      return GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => FollowListScreen(
              userId: p.id,
              displayName: p.username,
              mode: mode,
            ),
          ),
        ),
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

  // ─── Tab toggle (Posts / Events for all; Drafts owner-only) ───────────────

  Widget _buildTabToggle() {
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
      padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16),
      decoration: const BoxDecoration(
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

  Widget _buildDraftsFeed() {
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
      return const SliverToBoxAdapter(
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
              const Icon(
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

  Widget _buildEventsFeed() {
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
      return const SliverToBoxAdapter(
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
    final route = MaterialPageRoute(
      builder: (_) => e.isLive
          ? ViewerScreen(initialEventId: e.liveKitEventId)
          : EventDetailScreen(event: e, fromProfileId: _profile?.id),
    );
    Navigator.push(context, route).then((_) {
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

  const CoverPhoto({
    super.key,
    this.url,
    required this.height,
    this.localBytes,
    this.onTap,
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
            : onTap != null
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
        const Icon(Icons.camera_alt, size: 14, color: Colors.white),
        const SizedBox(width: 4),
        Text(
          label,
          style: NileTextStyles.caption().copyWith(
            color: Colors.white,
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
      decoration: const BoxDecoration(
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
    final updated = await Navigator.push<Post>(
      context,
      MaterialPageRoute(
        builder: (_) => PostDetailScreen(post: post, fromProfileId: profileId),
      ),
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
                  if (onEdited != null || onDeleted != null)
                    _ProfileContentMenu(
                      onEdit: onEdited == null
                          ? null
                          : () async {
                              final updated = await Navigator.push<Post>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => EditPostScreen(post: post),
                                ),
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
                    child: const Padding(
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
        const Icon(Icons.repeat, size: 14, color: NileColors.txtTertiary),
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
      icon: const Icon(
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
