import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/block_service.dart';
import '../services/event_service.dart';
import '../services/follow_service.dart';
import '../services/message_service.dart';
import '../services/like_service.dart';
import '../services/post_service.dart';
import '../services/profile_service.dart';
import '../services/report_service.dart';
import '../theme.dart';
import 'widgets/moderation_menu.dart';
import 'post_detail_screen.dart';
import 'settings_screen.dart';
import 'create_event_screen.dart';
import 'create_post_screen.dart';
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

class _ProfileScreenState extends State<ProfileScreen> {
  UserProfile? _profile;
  bool _loading = true;
  String? _error;

  // ── Events + posts created by this profile ────────────────────────────────
  List<Event>? _events;
  List<Post>? _posts;
  String? _eventsError;

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

  // More to show if either a source has un-fetched rows, or the merged list
  // already holds more than the current display window.
  bool get _hasMore {
    if (_postsHasMore || _eventsHasMore) return true;
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
    if (_hasMore && !_loadingMore && _events != null) _loadMore();
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
      _eventsError = null;
      _visibleCount = _kProfilePageSize;
    });
    try {
      final (eventPage, postPage) = await (
        EventService.getEventsByHost(userId, limit: _kProfilePageSize),
        PostService.getByAuthor(userId, limit: _kProfilePageSize),
      ).wait;
      final (hEvents, hPosts) = await (
        EventService.hydrateLikes(eventPage.items),
        PostService.hydrateLikes(postPage.items),
      ).wait;
      if (!mounted) return;
      setState(() {
        _events = hEvents;
        _posts = hPosts;
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

  Future<void> _loadMore() async {
    final uid = _uid;
    if (uid == null) return;
    setState(() => _loadingMore = true);
    try {
      // Grow the combined window by one page.
      final target = _visibleCount + _kProfilePageSize;

      // Top up a source only if it has more rows AND its fetched count can't
      // already fill the new window on its own — otherwise we have enough
      // candidates to keep the merged sort correct up to `target`.
      final fetchEvents = _eventsHasMore && (_events?.length ?? 0) < target;
      final fetchPosts = _postsHasMore && (_posts?.length ?? 0) < target;

      final (eventPage, postPage) = await (
        fetchEvents
            ? EventService.getEventsByHost(uid,
                cursor: _eventCursor, limit: _kProfilePageSize)
            : Future.value(Paged.empty<Event>()),
        fetchPosts
            ? PostService.getByAuthor(uid,
                cursor: _postCursor, limit: _kProfilePageSize)
            : Future.value(Paged.empty<Post>()),
      ).wait;
      final (hEvents, hPosts) = await (
        EventService.hydrateLikes(eventPage.items),
        PostService.hydrateLikes(postPage.items),
      ).wait;
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
    _replacePost(post.copyWith(
      likedByMe: !wasLiked,
      likeCount: (post.likeCount + delta).clamp(0, 1 << 30),
    ));
    try {
      wasLiked
          ? await LikeService.unlikePost(post.id)
          : await LikeService.likePost(post.id);
    } catch (_) {
      _replacePost(post);
    }
  }

  Future<void> _toggleEventLike(Event event) async {
    final wasLiked = event.likedByMe;
    final delta = wasLiked ? -1 : 1;
    _replaceEvent(event.copyWith(
      likedByMe: !wasLiked,
      likeCount: (event.likeCount + delta).clamp(0, 1 << 30),
    ));
    try {
      wasLiked
          ? await LikeService.unlikeEvent(event.id)
          : await LikeService.likeEvent(event.id);
    } catch (_) {
      _replaceEvent(event);
    }
  }

  /// Combined post/event list sorted by recency. Live events pin to top.
  // Full merged + sorted list (live events first, then newest-first).
  List<_ProfileItem>? get _allItems {
    if (_events == null || _posts == null) return null;
    final items = <_ProfileItem>[
      ..._events!.map(_ProfileEventItem.new),
      ..._posts!.map(_ProfilePostItem.new),
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

  void _showCreateSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: NileColors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
      ),
      builder: (_) => SafeArea(
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
                    .then((_) {
                      if (_profile != null) _loadEvents(_profile!.id);
                    });
                },
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Create Post'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const CreateEventScreen()))
                    .then((_) {
                      if (_profile != null) _loadEvents(_profile!.id);
                    });
                },
                icon: const Icon(Icons.add_circle_outline),
                label: const Text('Create Event'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openEdit() async {
    if (_profile == null) return;
    final updated = await Navigator.of(context).push<UserProfile>(
      MaterialPageRoute(
        builder: (_) => EditProfileScreen(profile: _profile!),
      ),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Something went wrong: $e')),
        );
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
    final ok = await Moderation.confirmBlock(context,
        userId: p.id, username: p.username);
    if (ok && mounted) {
      // Blocking severs the relationship — leave the now-hidden profile.
      Navigator.of(context).pop();
    }
  }

  Future<void> _unblockUser() async {
    final p = _profile;
    if (p == null) return;
    final ok = await Moderation.confirmUnblock(context,
        userId: p.id, username: p.username);
    if (ok && mounted) setState(() => _isBlocked = false);
  }

  void _reportUser() {
    final p = _profile;
    if (p == null) return;
    Moderation.showReportSheet(context,
        targetType: ReportTargetType.user, targetId: p.id);
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: NileColors.bgPage,
        body: Center(
          child: CircularProgressIndicator(color: NileColors.volt),
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
              Text(_error!,
                  style:
                      NileTextStyles.bodyMd().copyWith(color: NileColors.error)),
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
      // AppBar sits above the cover — keep it minimal.
      appBar: AppBar(
        backgroundColor: NileColors.bgPage,
        title: Text('@${p.username}', style: NileTextStyles.headingSm()),
        actions: [
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
                  borderRadius: BorderRadius.circular(NileRadius.sm)),
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
                    child: Text('Block',
                        style: TextStyle(color: NileColors.error)),
                  ),
              ],
            ),
        ],
      ),
      floatingActionButton: _isOwnProfile
          ? FloatingActionButton(
              onPressed: _showCreateSheet,
              backgroundColor: NileColors.volt,
              foregroundColor: NileColors.bgPage,
              child: const Icon(Icons.add),
            )
          : null,
      body: NileMaxWidth(child: RefreshIndicator(
        color: NileColors.volt,
        onRefresh: _load,
        child: CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverToBoxAdapter(child: _buildHeader(p)),
            const SliverToBoxAdapter(
              child: Divider(color: NileColors.border, height: 1),
            ),
            _buildEventsFeed(),
          ],
        ),
      )),
    );
  }

  // ─── Header ───────────────────────────────────────────────────────────────

  Widget _buildHeader(UserProfile p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Cover + avatar overlap ──────────────────────────────────────────
        Stack(
          clipBehavior: Clip.none,
          children: [
            // Cover photo
            CoverPhoto(url: p.coverUrl, height: _coverHeight),

            // Avatar pinned to bottom-left, half overhanging the cover
            Positioned(
              bottom: -_avatarRadius,
              left: 20,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: const BoxDecoration(
                  color: NileColors.bgPage,
                  shape: BoxShape.circle,
                ),
                child: CircleAvatar(
                  radius: _avatarRadius,
                  backgroundColor: NileColors.bgRaised,
                  backgroundImage: p.avatarUrl != null
                      ? NetworkImage(p.avatarUrl!) as ImageProvider
                      : null,
                  child: p.avatarUrl == null
                      ? Icon(Icons.person,
                          size: _avatarRadius, color: NileColors.txtTertiary)
                      : null,
                ),
              ),
            ),
          ],
        ),

        // ── Stats row (right-aligned to leave room for avatar) ──────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
          child: SizedBox(
            height: _avatarRadius + 12, // fill the avatar overhang space
            child: Row(
              children: [
                // Spacer matching avatar diameter + gap
                const SizedBox(width: _avatarRadius * 2 + 20),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _StatCol(
                          label: 'Posts',
                          value: _fmt(
                              (_events?.length ?? 0) + (_posts?.length ?? 0))),
                      _StatCol(
                        label: 'Followers',
                        value: _fmt(p.followerCount),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => FollowListScreen(
                              userId: p.id,
                              displayName: p.username,
                              mode: FollowListMode.followers,
                            ),
                          ),
                        ),
                      ),
                      _StatCol(
                        label: 'Following',
                        value: _fmt(p.followingCount),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => FollowListScreen(
                              userId: p.id,
                              displayName: p.username,
                              mode: FollowListMode.following,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── Name, bio, action button ────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(p.displayName, style: NileTextStyles.headingSm()),
              if (p.bio != null && p.bio!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(p.bio!, style: NileTextStyles.bodySm()),
              ],
              const SizedBox(height: 16),
              if (_isOwnProfile)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _openEdit,
                    child: const Text('Edit Profile'),
                  ),
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: _isFollowing
                          ? OutlinedButton(
                              onPressed: _followLoading ? null : _toggleFollow,
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(
                                    color: NileColors.border),
                                foregroundColor: NileColors.txtPrimary,
                              ),
                              child: _followLoading
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: NileColors.txtPrimary),
                                    )
                                  : const Text('Following'),
                            )
                          : FilledButton(
                              onPressed: _followLoading ? null : _toggleFollow,
                              style: FilledButton.styleFrom(
                                backgroundColor: NileColors.volt,
                                foregroundColor: NileColors.bgPage,
                              ),
                              child: _followLoading
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: NileColors.bgPage),
                                    )
                                  : const Text('Follow'),
                            ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _openDm,
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: NileColors.border),
                        foregroundColor: NileColors.txtPrimary,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                      ),
                      child: const Icon(Icons.send_outlined, size: 18),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ─── Events feed ──────────────────────────────────────────────────────────

  Widget _buildEventsFeed() {
    if (_eventsError != null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: Text(
              'Couldn\'t load posts: $_eventsError',
              textAlign: TextAlign.center,
              style:
                  NileTextStyles.bodySm().copyWith(color: NileColors.error),
            ),
          ),
        ),
      );
    }
    final items = _profileItems;
    if (items == null) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: Center(
            child: CircularProgressIndicator(color: NileColors.volt),
          ),
        ),
      );
    }
    if (items.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.event_note,
                  size: 48, color: NileColors.border),
              const SizedBox(height: 12),
              Text(
                _isOwnProfile ? 'No posts yet' : 'Nothing posted yet',
                style: NileTextStyles.headingSm(),
              ),
              const SizedBox(height: 4),
              Text(
                _isOwnProfile
                    ? 'Posts and events you create will appear here.'
                    : 'Check back later.',
                textAlign: TextAlign.center,
                style: NileTextStyles.bodySm(),
              ),
            ],
          ),
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      sliver: SliverList.separated(
        itemCount: items.length + (_hasMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (_, i) {
          if (i >= items.length) return const LoadMoreFooter();
          final it = items[i];
          return switch (it) {
            _ProfileEventItem(:final event) => _ProfileEventCard(
                event: event,
                onTap: () => _openEvent(event),
                onEdited: _isOwnProfile ? (e) => _replaceEvent(e) : null,
                onLikeToggle: () => _toggleEventLike(event),
              ),
            _ProfilePostItem(:final post) => _ProfilePostCard(
                post: post,
                onEdited: _isOwnProfile ? (p) => _replacePost(p) : null,
                onDeleted: _isOwnProfile ? () => _removePost(post.id) : null,
                onLikeToggle: () => _togglePostLike(post),
                onUpdated: _replacePost,
              ),
          };
        },
      ),
    );
  }

  void _replacePost(Post updated) => setState(() {
        final i = _posts?.indexWhere((p) => p.id == updated.id) ?? -1;
        if (i >= 0) _posts![i] = updated;
      });

  void _removePost(String postId) =>
      setState(() => _posts?.removeWhere((p) => p.id == postId));

  void _replaceEvent(Event updated) => setState(() {
        final i = _events?.indexWhere((e) => e.id == updated.id) ?? -1;
        if (i >= 0) _events![i] = updated;
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
          : EventDetailScreen(event: e),
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
      image = NetworkImage(url!);
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
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, NileColors.bgPage.withValues(alpha: 0.4)],
        ),
      ),
      child: buildCameraChip('Edit cover'),
    );
  }
}

/// Public helper — renders the pill-shaped camera chip used on cover photos.
Widget buildCameraChip(String label) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: NileColors.bgPage.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(NileRadius.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.camera_alt, size: 14, color: Colors.white),
        const SizedBox(width: 4),
        Text(label,
            style: NileTextStyles.caption()
                .copyWith(color: Colors.white, letterSpacing: 0)),
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
  _ProfileEventItem(this.event);
  @override
  DateTime get sortKey => event.scheduledAt ?? event.createdAt;
}

class _ProfilePostItem extends _ProfileItem {
  final Post post;
  _ProfilePostItem(this.post);
  @override
  DateTime get sortKey => post.createdAt;
}

// ─── Post card (profile feed) ────────────────────────────────────────────────

class _ProfilePostCard extends StatelessWidget {
  final Post post;
  final void Function(Post)? onEdited;
  final VoidCallback? onDeleted;
  final VoidCallback? onLikeToggle;
  final void Function(Post)? onUpdated;
  const _ProfilePostCard({
    required this.post,
    this.onEdited,
    this.onDeleted,
    this.onLikeToggle,
    this.onUpdated,
  });

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
                Text(_timeAgo(post.createdAt),
                    style: NileTextStyles.caption()),
                if (onEdited != null || onDeleted != null)
                  _ProfileContentMenu(
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
                            final ok =
                                await _confirmProfileDelete(context, 'post');
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
              Text(post.caption!.trim(), style: NileTextStyles.bodyMd()),
            ],
            if (post.hasImage) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(NileRadius.sm),
                child: Image.network(
                  post.imageUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    height: 200,
                    color: NileColors.bgRaised,
                    child: const Center(
                      child:
                          Icon(Icons.broken_image, color: NileColors.border),
                    ),
                  ),
                ),
              ),
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
              ],
            ),
          ],
        ),
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
  const _LikeRow(
      {required this.liked, required this.count, required this.onTap});

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

// ─── Event card (profile feed) ───────────────────────────────────────────────

class _ProfileEventCard extends StatelessWidget {
  final Event event;
  final VoidCallback onTap;
  final void Function(Event)? onEdited;
  final VoidCallback? onLikeToggle;

  const _ProfileEventCard({
    required this.event,
    required this.onTap,
    this.onEdited,
    this.onLikeToggle,
  });

  String _timeAgo(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inDays > 0) return '${d.inDays}d ago';
    if (d.inHours > 0) return '${d.inHours}h ago';
    if (d.inMinutes > 0) return '${d.inMinutes}m ago';
    return 'just now';
  }

  String? _scheduledLabel() {
    final s = event.scheduledAt;
    if (s == null) return null;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final t =
        '${s.hour.toString().padLeft(2, '0')}:${s.minute.toString().padLeft(2, '0')}';
    return '${months[s.month - 1]} ${s.day} · $t';
  }

  @override
  Widget build(BuildContext context) {
    final cover = event.coverImageUrl;
    return Material(
      color: NileColors.bgSurface,
      borderRadius: BorderRadius.circular(NileRadius.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 112,
                height: 112,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (cover != null)
                      Image.network(
                        cover,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const ColoredBox(
                          color: NileColors.bgRaised,
                          child: Icon(Icons.live_tv,
                              color: NileColors.border),
                        ),
                      )
                    else
                      const ColoredBox(
                        color: NileColors.bgRaised,
                        child: Icon(Icons.live_tv, color: NileColors.border),
                      ),
                    Positioned(
                      top: 6,
                      left: 6,
                      child: _StatusPill(event: event),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          event.title,
                          style: NileTextStyles.headingSm(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (event.description != null &&
                            event.description!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            event.description!,
                            style: NileTextStyles.bodySm(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        if (event.isLive) ...[
                          const Icon(Icons.visibility,
                              size: 13, color: NileColors.txtTertiary),
                          const SizedBox(width: 4),
                          Text('${event.viewerCount}',
                              style: NileTextStyles.caption()),
                        ] else if (_scheduledLabel() != null) ...[
                          const Icon(Icons.calendar_today,
                              size: 12, color: NileColors.txtTertiary),
                          const SizedBox(width: 4),
                          Text(_scheduledLabel()!,
                              style: NileTextStyles.caption()),
                        ] else
                          Text(_timeAgo(event.createdAt),
                              style: NileTextStyles.caption()),
                        if (onLikeToggle != null) ...[
                          const SizedBox(width: 12),
                          _LikeRow(
                            liked: event.likedByMe,
                            count: event.likeCount,
                            onTap: onLikeToggle!,
                          ),
                        ],
                        const Spacer(),
                        if (event.price != null && event.price! > 0)
                          Text(
                            '\$${(event.price! / 100).toStringAsFixed(2)}',
                            style: NileTextStyles.labelSm()
                                .copyWith(color: NileColors.volt),
                          ),
                        if (onEdited != null)
                          _ProfileContentMenu(
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
                  ],
                ),
              ),
            ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final Event event;
  const _StatusPill({required this.event});

  @override
  Widget build(BuildContext context) {
    late final Color bg;
    late final Color fg;
    late final String label;
    if (event.isLive) {
      bg = NileColors.coral;
      fg = Colors.white;
      label = 'LIVE';
    } else if (event.isEnded) {
      bg = Colors.black54;
      fg = Colors.white;
      label = 'ENDED';
    } else {
      bg = Colors.black54;
      fg = NileColors.volt;
      label = 'SCHEDULED';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(NileRadius.xs),
      ),
      child: Text(
        label,
        style: NileTextStyles.caption().copyWith(
          color: fg,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

// ─── Stat column ──────────────────────────────────────────────────────────────

class _StatCol extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onTap;

  const _StatCol({required this.label, required this.value, this.onTap});

  @override
  Widget build(BuildContext context) {
    final col = Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(value, style: NileTextStyles.headingMd()),
        const SizedBox(height: 2),
        Text(label, style: NileTextStyles.caption()),
      ],
    );

    if (onTap == null) return col;
    return GestureDetector(
      onTap: onTap,
      child: col,
    );
  }
}

// ── Profile screen edit/delete helpers ───────────────────────────────────────

Future<bool> _confirmProfileDelete(BuildContext context, String itemType) async {
  return await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: NileColors.bgSurface,
          title:
              Text('Delete $itemType?', style: NileTextStyles.headingSm()),
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

class _ProfileContentMenu extends StatelessWidget {
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  const _ProfileContentMenu({this.onEdit, this.onDelete});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      icon:
          const Icon(Icons.more_horiz, size: 18, color: NileColors.txtTertiary),
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
            child:
                Text('Delete', style: TextStyle(color: NileColors.error)),
          ),
      ],
    );
  }
}
