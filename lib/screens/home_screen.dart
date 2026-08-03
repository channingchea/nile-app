import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:visibility_detector/visibility_detector.dart';
import '../services/ad_service.dart';
import '../services/app_lifecycle.dart';
import '../services/event_repost_service.dart';
import '../services/share_urls.dart';
import '../services/event_service.dart';
import '../services/follow_service.dart';
import '../services/like_service.dart';
import '../services/notification_service.dart';
import '../services/pagination.dart' show Paged;
import '../services/post_service.dart';
import '../services/current_service.dart';
import '../services/report_service.dart';
import '../services/repost_service.dart';
import '../services/search_service.dart';
import '../theme.dart';
import '../widgets/event_cover_pill.dart';
import '../widgets/event_link_card.dart';
import '../widgets/like_button.dart';
import '../widgets/nile_glass_app_bar.dart';
import '../widgets/nile_logo.dart';
import '../widgets/nile_glass_nav_bar.dart';
import '../widgets/nile_skeleton.dart';
import '../widgets/official_badge.dart';
import '../widgets/post_image_carousel.dart';
import '../widgets/pressable.dart';
import '../widgets/currents_rail.dart';
import '../widgets/share_to_sheet.dart';
import '../widgets/empty_state.dart';
import '../widgets/staggered_fade_in.dart';
import 'create_event_flow.dart';
import 'create_post_screen.dart';
import 'create_current_screen.dart';
import 'discover_screen.dart';
import 'edit_event_screen.dart';
import 'edit_post_screen.dart';
import 'event_detail_screen.dart';
import 'like_list_screen.dart';
import 'messages_screen.dart';
import 'notifications_screen.dart';
import 'post_detail_screen.dart';
import 'profile_screen.dart';
import 'currents_player_screen.dart';
import 'viewer_screen.dart';
import 'widgets/load_more_footer.dart';
import 'widgets/moderation_menu.dart';

/// Below this many followed-feed items, blend in cold-start "starter" content
/// (live now, topic recs, upcoming shows, newest posts) so a quiet feed still
/// fills the screen. Just a threshold — tune freely.
const int kThinFeedThreshold = 5;

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
  int _discoverKey = 0;
  int _discoverInitialTab = 0;

  // Tabs are built on first visit, not eagerly. An unvisited tab renders as an
  // empty placeholder in the IndexedStack; once shown it stays built (state
  // preserved) so re-selecting it never re-fetches. Feed (0) is visited at start.
  final Set<int> _visited = {0};

  List<Widget> get _pages => [
    _FeedTab(
      key: ValueKey(_feedKey),
      onContentChanged: _onContentChanged,
      onFindPeople: () => _goToDiscover(2),
    ),
    DiscoverScreen(key: ValueKey(_discoverKey), initialTab: _discoverInitialTab),
    const MessagesScreen(),
    ProfileScreen(key: ValueKey(_profileKey)),
  ];

  // Jump to Discover, remounting it on [tab] (0 posts, 1 events, 2 people) so
  // Home's empty-state CTAs land the user somewhere useful instead of a dead end.
  void _goToDiscover(int tab) => setState(() {
    _discoverInitialTab = tab;
    _discoverKey++;
    _selectedIndex = 1;
    _visited.add(1);
  });

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
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(NileRadius.lg),
        ),
      ),
      builder: (_) => _ActionSheet(onCreated: _onContentCreated),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Android system back from a non-Home tab returns to the Home tab instead
    // of exiting the app (standard bottom-nav behavior); back from Home exits
    // as usual. No effect on iOS/desktop, where there's no system back.
    return PopScope(
      canPop: _selectedIndex == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _selectedIndex = 0);
      },
      child: Scaffold(
        backgroundColor: NileColors.bgPage,
        // Content flows behind the floating glass nav bar.
        extendBody: true,
        body: NileMaxWidth(
          // IndexedStack keeps every tab built, so the same event can hold a
          // live Hero on two tabs at once — duplicate tags abort ALL hero
          // flights. HeroMode keeps only the visible tab's heroes active.
          child: IndexedStack(
            index: _selectedIndex,
            children: [
              for (final (i, page) in _pages.indexed)
                if (_visited.contains(i))
                  HeroMode(enabled: i == _selectedIndex, child: page)
                else
                  const SizedBox.shrink(),
            ],
          ),
        ),
        // Liquid Glass nav. To revert: swap NileGlassNavBar → NileMaterialNavBar
        // (lib/widgets/nile_material_nav_bar.dart), set extendBody: false above,
        // restore the FloatingActionButton, and drop the reservedHeight bottom
        // padding from the tab scroll views.
        bottomNavigationBar: NileGlassNavBar(
          selectedIndex: _selectedIndex,
          onDestinationSelected: (i) => setState(() {
            _selectedIndex = i;
            _visited.add(i);
          }),
          // Create "+" sits on the same row as the nav pill, on every tab.
          trailing: _CreateButton(onTap: _showActionSheet),
          destinations: const [
            NileGlassDestination(
              icon: Icons.home_outlined,
              selectedIcon: Icons.home,
              label: 'Home',
            ),
            NileGlassDestination(
              icon: Icons.search_outlined,
              selectedIcon: Icons.search,
              label: 'Discover',
            ),
            NileGlassDestination(
              icon: Icons.send_outlined,
              selectedIcon: Icons.send,
              label: 'Messages',
            ),
            NileGlassDestination(
              icon: Icons.person_outline,
              selectedIcon: Icons.person,
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}

// ── Create button (trailing "+" beside the glass nav) ────────────────────────

class _CreateButton extends StatelessWidget {
  const _CreateButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: NileColors.volt,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: Icon(Icons.add, color: NileColors.onVolt, size: 28),
        ),
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
        padding: const EdgeInsets.fromLTRB(NileSpacing.s24, NileSpacing.s16, NileSpacing.s24, NileSpacing.s24),
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
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CreatePostScreen()),
                ).then((_) => onCreated());
              },
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Create Post'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CreateCurrentScreen()),
                ).then((_) => onCreated());
              },
              icon: const Icon(Icons.bolt_outlined),
              label: const Text('Create Current'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CreateEventFlow()),
                ).then((_) => onCreated());
              },
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Create Event'),
            ),
            const SizedBox(height: 12),
            // Camera/audio quick-entry tiles removed: streaming is entered from
            // the event detail screen, which knows whether you're the host (and
            // therefore whether you get Start Show / End Stream).
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ViewerScreen()),
                );
              },
              icon: const Icon(Icons.tv),
              label: const Text('Watch as Viewer'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Feed tab ──────────────────────────────────────────────────────────────────

class _FeedTab extends StatefulWidget {
  const _FeedTab({super.key, this.onContentChanged, this.onFindPeople});

  /// Called after a repost/unrepost succeeds so the host can refresh the
  /// profile tab (where the reposted item appears).
  final VoidCallback? onContentChanged;

  /// Sends the user to Discover → People. Powers the empty-state CTAs so a
  /// follow-less or quiet feed offers a real next step.
  final VoidCallback? onFindPeople;

  @override
  State<_FeedTab> createState() => _FeedTabState();
}

/// Unified feed entry — either an [Event] or a [Post].
/// [fromNetwork] marks a follow-graph recommendation (liked by people you
/// follow but not authored by someone you follow), surfaced with a tag.
sealed class _FeedItem {
  DateTime get sortKey;
  bool get fromNetwork;

  /// Set on sponsored (paid) items, which carry an ad campaign id for
  /// impression/click logging and render with a "Sponsored" disclosure.
  String? get adCampaignId;
  bool get isSponsored => adCampaignId != null;
}

class _EventFeedItem extends _FeedItem {
  final Event event;
  @override
  final bool fromNetwork;
  @override
  final String? adCampaignId;

  /// When set (reposts), sorts by repost time instead of scheduled/created.
  final DateTime? sortOverride;
  _EventFeedItem(
    this.event, {
    this.fromNetwork = false,
    this.sortOverride,
    this.adCampaignId,
  });
  @override
  DateTime get sortKey => sortOverride ?? event.scheduledAt ?? event.createdAt;
}

class _PostFeedItem extends _FeedItem {
  final Post post;
  @override
  final bool fromNetwork;
  @override
  final String? adCampaignId;

  /// When set (reposts), the item sorts by repost time instead of the original
  /// post's createdAt, so a fresh repost surfaces near the top of the feed.
  final DateTime? sortOverride;
  _PostFeedItem(
    this.post, {
    this.fromNetwork = false,
    this.sortOverride,
    this.adCampaignId,
  });
  @override
  DateTime get sortKey => sortOverride ?? post.createdAt;
}

/// A standalone advertiser creative (Phase A-4): an external ad that is neither
/// an event nor a post, so it carries no like/comment/repost mutation paths.
/// Always sponsored. Injected like other ads; never authored by a Nile user.
class _AdFeedItem extends _FeedItem {
  final AdCreative creative;
  @override
  final String adCampaignId;
  _AdFeedItem(this.creative, {required this.adCampaignId});
  @override
  bool get fromNetwork => false;
  @override
  DateTime get sortKey => DateTime.now();
}

class _FeedTabState extends State<_FeedTab> {
  List<_FeedItem>? _items;
  // Platform-wide "Live now" rail, shown to every user above the feed (Phase 3).
  // Live events live here, not in the list below, so nothing shows twice.
  List<Event> _liveNow = [];
  // Currents rail — creators with live (≤24h) Currents, followed-first. The rail
  // widget itself always renders (its first slot is the create entry).
  List<CurrentRailEntry> _currentsRail = [];
  // Cold-start fill for zero-follow and thin feeds (Phase 1). Rendered as a
  // separate section below the followed feed, in priority order (topic →
  // upcoming → newest; live shows in the rail above) — not time-sorted.
  List<_FeedItem> _starterItems = [];
  bool _starterMode = false; // true when the user follows no one
  bool _starterHeaderDismissed = false;
  String? _error;
  int _unreadCount = 0;

  // Follow-graph recommendations, interleaved into the followed feed every
  // [_recInterval] items. Loaded once per [_load]; not part of pagination.
  List<_FeedItem> _recs = [];
  static const _recInterval = 6;

  // Sponsored items, injected after recs at a rarer cadence than recs so ads
  // stay sparse. Loaded once per [_load]; not part of pagination. Impressions
  // already counted this session are tracked so we log at most one per card.
  List<_FeedItem> _ads = [];
  static const _adInterval = 8;
  // Per-card impression guard, keyed 'ad-<campaignId>-<itemId>'. An entry is
  // added when a card logs an impression and removed when it scrolls fully out
  // of view, so each distinct viewing counts once.
  final Set<String> _loggedImpressions = {};
  // Dwell timers: an impression only counts after the card has stayed ≥50%
  // visible for 1s, so fast scroll-pasts don't log (honest CPM).
  final Map<String, Timer> _impressionTimers = {};

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
  void _mutate(
    bool Function(_FeedItem) match,
    _FeedItem Function(_FeedItem) update,
  ) {
    setState(() {
      for (final list in [_items, _recs, _starterItems]) {
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
      _starterItems.removeWhere(match);
    });
  }

  void _replacePost(Post updated) => _mutate(
    (it) => it is _PostFeedItem && it.post.id == updated.id,
    (it) => _PostFeedItem(
      updated,
      fromNetwork: it.fromNetwork,
      adCampaignId: it.adCampaignId,
    ),
  );

  void _removePost(String postId) =>
      _remove((it) => it is _PostFeedItem && it.post.id == postId);

  void _replaceEvent(Event updated) => _mutate(
    (it) => it is _EventFeedItem && it.event.id == updated.id,
    (it) => _EventFeedItem(
      updated,
      fromNetwork: it.fromNetwork,
      adCampaignId: it.adCampaignId,
    ),
  );

  void _removeEvent(String eventId) =>
      _remove((it) => it is _EventFeedItem && it.event.id == eventId);

  /// Hides a dismissed sponsored ad (after "Not interested" or a report). Also
  /// drops it from [_ads] so a feed re-interleave can't re-inject it this session.
  void _removeAd(String campaignId) {
    _ads = _ads.where((it) => it.adCampaignId != campaignId).toList();
    _remove((it) => it is _AdFeedItem && it.adCampaignId == campaignId);
  }

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
    _replacePost(
      post.copyWith(
        repostedByMe: !was,
        repostCount: (post.repostCount + delta).clamp(0, 1 << 30),
      ),
    );
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to repost')));
    }
  }

  Future<void> _toggleEventRepost(Event event) async {
    final was = event.repostedByMe;
    final delta = was ? -1 : 1;
    _replaceEvent(
      event.copyWith(
        repostedByMe: !was,
        repostCount: (event.repostCount + delta).clamp(0, 1 << 30),
      ),
    );
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to repost')));
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
    AppLifecycle.instance.state.addListener(_onLifecycleChanged);
    _load();
    _loadUnread();
  }

  @override
  void dispose() {
    for (final t in _impressionTimers.values) {
      t.cancel();
    }
    _impressionTimers.clear();
    AppLifecycle.instance.state.removeListener(_onLifecycleChanged);
    _scroll.dispose();
    super.dispose();
  }

  // On return from background, refresh just the Live Now rail (lighter than a
  // full reload) so streams that started or ended while away are current.
  void _onLifecycleChanged() {
    if (AppLifecycle.instance.state.value == AppLifecycleState.resumed) {
      _refreshLiveNow();
    }
  }

  Future<void> _refreshLiveNow() async {
    try {
      final live = await EventService.getLiveNow();
      if (!mounted) return;
      final liveIds = {for (final e in live) e.id};
      setState(() {
        _liveNow = live;
        // Keep the list free of anything now surfaced in the rail.
        _items?.removeWhere(
          (it) => it is _EventFeedItem && liveIds.contains(it.event.id),
        );
      });
    } catch (_) {}
  }

  // Live Now rail taps go to the event's landing page, not straight into the
  // stream — the detail screen has the join CTA.
  void _openLive(Event event) => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => EventDetailScreen(event: event)),
  );

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 400) {
      return;
    }
    if (_hasMore && !_loadingMore && _items != null) _loadMore();
  }

  String _idOf(_FeedItem it) => switch (it) {
    _EventFeedItem(:final event) => 'e:${event.id}',
    _PostFeedItem(:final post) => 'p:${post.id}',
    _AdFeedItem(:final adCampaignId) => 'ad:$adCampaignId',
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

  /// Injects sponsored items into [feed] (already rec-interleaved): one ad after
  /// every [_adInterval] items. Ads whose content already appears in the feed
  /// are skipped, and ads keep their serving order. Runs after [_interleaveRecs]
  /// so ads are rarer than recs. Returns a new list; input ordering is untouched.
  List<_FeedItem> _injectAds(List<_FeedItem> feed) {
    if (_ads.isEmpty) return feed;
    final seen = feed.map(_idOf).toSet();
    final ads = _ads.where((a) => seen.add(_idOf(a))).toList();
    if (ads.isEmpty) return feed;

    final out = <_FeedItem>[];
    var a = 0;
    for (var i = 0; i < feed.length; i++) {
      out.add(feed[i]);
      if ((i + 1) % _adInterval == 0 && a < ads.length) out.add(ads[a++]);
    }
    out.addAll(ads.sublist(a));
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
      _starterItems = [];
      _liveNow = [];
      _starterMode = false;
      _error = null;
    });
    try {
      final ids = await FollowService.getFollowingIds();
      _followingIds = ids;

      // Platform-wide Live Now rail — for every user, loaded once. Best-effort:
      // a failure here just means no rail, never a broken feed.
      var liveNow = <Event>[];
      try {
        liveNow = await EventService.getLiveNow();
      } catch (_) {}
      final liveIds = {for (final e in liveNow) e.id};

      // Currents rail — best-effort (rail() returns [] on failure internally).
      final currentsRail = await CurrentService.rail();

      var items = <_FeedItem>[];
      var recs = <_FeedItem>[];
      var ads = <_FeedItem>[];
      Paged<Event> eventPage = Paged.empty();
      Paged<Post> postPage = Paged.empty();

      // Followed feed — skipped entirely when the user follows no one.
      if (ids.isNotEmpty) {
        (eventPage, postPage) = await (
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
            eventRepostRows.map((r) => r.event).toList(),
          ),
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
          for (final r in eventRepostRows) r.event.id: r.repostedAt,
        };
        items = <_FeedItem>[
          ...hEvents.map((e) => _EventFeedItem(e)),
          ...hPosts.map((p) => _PostFeedItem(p)),
          ...hReposts.map((p) => _PostFeedItem(p, sortOverride: repostAt[p.id])),
          ...hEventReposts.map(
            (e) => _EventFeedItem(e, sortOverride: eventRepostAt[e.id]),
          ),
        ];
        _sortItems(items);
        // Recs and ads are best-effort: a failure here must not break the feed.
        try {
          final (rEvents, rPosts, feedAds) = await (
            SearchService.recommendedEvents(),
            SearchService.recommendedPosts(),
            AdService.feedAds(),
          ).wait;
          recs = [
            ...rEvents.map((e) => _EventFeedItem(e, fromNetwork: true)),
            ...rPosts.map((p) => _PostFeedItem(p, fromNetwork: true)),
          ];
          ads = [
            for (final ad in feedAds)
              if (ad.event != null)
                _EventFeedItem(ad.event!, adCampaignId: ad.campaignId)
              else if (ad.post != null)
                _PostFeedItem(ad.post!, adCampaignId: ad.campaignId)
              else if (ad.creative != null)
                _AdFeedItem(ad.creative!, adCampaignId: ad.campaignId),
          ];
        } catch (_) {}
      }

      // Live events belong to the rail, not the list — drop them so a followed
      // host who's live doesn't appear twice.
      items = items
          .where(
            (it) => !(it is _EventFeedItem && liveIds.contains(it.event.id)),
          )
          .toList();

      // Cold-start fill: always for zero-follow, and to top up a thin feed.
      var starter = <_FeedItem>[];
      if (ids.isEmpty || items.length < kThinFeedThreshold) {
        final exclude = {
          ...items.map(_idOf),
          ...recs.map(_idOf),
          for (final e in liveNow) 'e:${e.id}',
        };
        starter = await _loadStarterItems(exclude);
      }

      if (!mounted) return;
      setState(() {
        _items = items;
        _liveNow = liveNow;
        _currentsRail = currentsRail;
        _recs = recs;
        _ads = ads;
        _starterItems = starter;
        _starterMode = ids.isEmpty;
        _eventCursor = eventPage.nextCursor;
        _postCursor = postPage.nextCursor;
        _eventsHasMore = eventPage.hasMore;
        _postsHasMore = postPage.hasMore;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  /// Builds the cold-start fill in priority order: topic recommendations →
  /// upcoming shows → newest discover posts. (Live now is surfaced in the rail
  /// above, so it isn't repeated here.) Deduped by id and against [exclude]
  /// (ids already in the followed feed / recs / rail). Every fetch is
  /// best-effort, so a single failure just yields a shorter list.
  Future<List<_FeedItem>> _loadStarterItems(Set<String> exclude) async {
    var topic = <Event>[];
    var upcoming = <Event>[];
    var posts = <Post>[];
    try {
      final r = await (
        SearchService.recommendedEventsByTopic(),
        EventService.getUpcoming(),
        PostService.getDiscover(),
      ).wait;
      topic = r.$1;
      upcoming = r.$2;
      posts = r.$3.items;
    } catch (_) {}

    // Hydrate like/repost flags so the action buttons render correct state.
    try {
      final events = await EventService.hydrateReposts(
        await EventService.hydrateLikes([...topic, ...upcoming]),
      );
      final byId = {for (final e in events) e.id: e};
      Event pick(Event e) => byId[e.id] ?? e;
      topic = topic.map(pick).toList();
      upcoming = upcoming.map(pick).toList();
    } catch (_) {}
    try {
      posts = await PostService.hydrateReposts(
        await PostService.hydrateLikes(posts),
      );
    } catch (_) {}

    final out = <_FeedItem>[];
    final seen = {...exclude};
    void add(_FeedItem it) {
      if (seen.add(_idOf(it))) out.add(it);
    }

    for (final e in topic) {
      add(_EventFeedItem(e));
    }
    for (final e in upcoming) {
      add(_EventFeedItem(e));
    }
    for (final p in posts) {
      add(_PostFeedItem(p));
    }
    return out;
  }

  /// Builds the card widget for a single feed item (event / post / ad),
  /// wiring the owner and ad callbacks. Shared by the followed feed and the
  /// starter section.
  Widget _cardFor(_FeedItem it) {
    final myId = Supabase.instance.client.auth.currentUser?.id;
    final campaignId = it.adCampaignId;
    // Sponsored cards suppress owner edit/delete affordances.
    return switch (it) {
      _EventFeedItem(:final event) => _EventCard(
        event: event,
        fromNetwork: it.fromNetwork,
        isSponsored: it.isSponsored,
        onTapAd: campaignId == null
            ? null
            : () => AdService.logClick(campaignId),
        onEdited: myId == event.hostId && campaignId == null
            ? (e) => _replaceEvent(e)
            : null,
        onDeleted: myId == event.hostId && campaignId == null
            ? () => _removeEvent(event.id)
            : null,
        onLikeToggle: () => _toggleEventLike(event),
        onRepostToggle: () => _toggleEventRepost(event),
      ),
      _PostFeedItem(:final post) => _PostCard(
        post: post,
        fromNetwork: it.fromNetwork,
        isSponsored: it.isSponsored,
        onTapAd: campaignId == null
            ? null
            : () => AdService.logClick(campaignId),
        onEdited: myId == post.authorId && campaignId == null
            ? (p) => _replacePost(p)
            : null,
        onDeleted: myId == post.authorId && campaignId == null
            ? () => _removePost(post.id)
            : null,
        onLikeToggle: () => _togglePostLike(post),
        onRepostToggle: () => _togglePostRepost(post),
        onUpdated: (updated) => _replacePost(updated),
      ),
      _AdFeedItem(:final creative) => _AdCreativeCard(
        creative: creative,
        campaignId: campaignId!,
        onTap: () => AdService.logClick(campaignId),
        onDismiss: () => _removeAd(campaignId),
      ),
    };
  }

  // ── Currents rail actions ────────────────────────────────────────────────────

  /// Opens the Current creation flow; refreshes the rail on return so the
  /// creator sees their new Current land (without a full feed reload).
  Future<void> _createCurrent() async {
    final created = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CreateCurrentScreen()),
    );
    if (created != null) _reloadCurrentsRail();
  }

  /// Opens the vertical player at [e]'s first unwatched Current; refreshes the
  /// rail on return so watched rings update.
  Future<void> _openCurrents(CurrentRailEntry e) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => CurrentsPlayerScreen(startUserId: e.userId),
      ),
    );
    _reloadCurrentsRail();
  }

  Future<void> _reloadCurrentsRail() async {
    final rail = await CurrentService.rail();
    if (mounted) setState(() => _currentsRail = rail);
  }

  /// Wraps a sponsored card in a [VisibilityDetector] that logs an honest CPM
  /// impression once per viewing (≥50% visible for ≥1s, re-arming on exit).
  /// Non-sponsored items pass through untouched.
  Widget _wrapImpression(_FeedItem it) {
    final campaignId = it.adCampaignId;
    final card = _cardFor(it);
    if (campaignId == null) return card;
    final impressionKey = 'ad-$campaignId-${_idOf(it)}';
    return VisibilityDetector(
      key: ValueKey(impressionKey),
      onVisibilityChanged: (info) {
        // Re-arm as soon as the card drops below a quarter visible; waiting for
        // an exact 0 is unreliable since the card is often recycled before
        // reporting 0.0.
        if (info.visibleFraction < 0.25) {
          _loggedImpressions.remove(impressionKey);
          _impressionTimers.remove(impressionKey)?.cancel();
        } else if (info.visibleFraction >= 0.5 &&
            !_loggedImpressions.contains(impressionKey) &&
            !_impressionTimers.containsKey(impressionKey)) {
          _impressionTimers[impressionKey] = Timer(
            const Duration(seconds: 1),
            () {
              // Still armed after 1s of dwell (a drop below 50% before now
              // would have cancelled us).
              _impressionTimers.remove(impressionKey);
              if (_loggedImpressions.add(impressionKey)) {
                AdService.logImpression(campaignId);
              }
            },
          );
        } else if (info.visibleFraction < 0.5) {
          // Dropped below the threshold mid-dwell: cancel.
          _impressionTimers.remove(impressionKey)?.cancel();
        }
      },
      child: card,
    );
  }

  @override
  Widget build(BuildContext context) {
    // bottom:false lets the feed scroll behind the translucent glass nav bar.
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: NileColors.volt,
        backgroundColor: NileColors.bgSurface,
        onRefresh: _load,
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            NileGlassBar.sliverAppBar(
              title: const NileLogo(size: 'small', height: 28),
              actions: [
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
            else if (_items == null)
              const SliverToBoxAdapter(child: NileSkeletonList())
            else ...[
              // Currents rail — always first; its leading slot is the "Your
              // Current" create entry, so it renders even with no content.
              SliverToBoxAdapter(
                child: CurrentsRail(
                  entries: _currentsRail,
                  onCreate: _createCurrent,
                  onTapCreator: _openCurrents,
                ),
              ),
              // Platform-wide Live Now rail — pinned first for every user,
              // hidden entirely when nothing is live (no empty shell).
              if (_liveNow.isNotEmpty)
                SliverToBoxAdapter(
                  child: _LiveNowRail(events: _liveNow, onTap: _openLive),
                ),
              // Followed feed (empty when the user follows no one). Reserves
              // the nav-bar gap at its foot only when no starter section
              // follows it.
              if (_items!.isNotEmpty)
                Builder(
                  builder: (_) {
                    final display = _injectAds(_interleaveRecs(_items!));
                    final bottom = _starterItems.isEmpty
                        ? NileGlassNavBar.reservedHeight + NileSpacing.s16
                        : NileSpacing.s16;
                    return SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        NileSpacing.s16,
                        NileSpacing.s8,
                        NileSpacing.s16,
                        bottom,
                      ),
                      sliver: SliverList.separated(
                        itemCount: display.length + (_hasMore ? 1 : 0),
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (_, i) {
                          if (i >= display.length) return const LoadMoreFooter();
                          return NileStaggeredFadeIn(
                            index: i,
                            child: _wrapImpression(display[i]),
                          );
                        },
                      ),
                    );
                  },
                ),
              // Cold-start starter fill, in priority order (not time-sorted),
              // under a header that explains why it's shown.
              if (_starterItems.isNotEmpty) ...[
                if (!(_starterMode && _starterHeaderDismissed))
                  SliverToBoxAdapter(
                    child: _StarterHeader(
                      label: _starterMode
                          ? 'Follow creators to shape this feed'
                          : 'Suggested for you',
                      onDismiss: _starterMode
                          ? () =>
                                setState(() => _starterHeaderDismissed = true)
                          : null,
                    ),
                  ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    NileSpacing.s16,
                    NileSpacing.s8,
                    NileSpacing.s16,
                    NileGlassNavBar.reservedHeight + NileSpacing.s16,
                  ),
                  sliver: SliverList.separated(
                    itemCount: _starterItems.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (_, i) => NileStaggeredFadeIn(
                      index: i,
                      child: _cardFor(_starterItems[i]),
                    ),
                  ),
                ),
              ],
              // Nothing to show at all: still offer a next step.
              if (_items!.isEmpty && _starterItems.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _followingIds.isEmpty
                      ? _EmptyFollows(onFindPeople: widget.onFindPeople)
                      : _EmptyFeed(onFindPeople: widget.onFindPeople),
                ),
            ],
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
  final bool isSponsored;
  final VoidCallback? onTapAd;
  final void Function(Event)? onEdited;
  final VoidCallback? onDeleted;
  final VoidCallback? onLikeToggle;
  final VoidCallback? onRepostToggle;
  const _EventCard({
    required this.event,
    this.fromNetwork = false,
    this.isSponsored = false,
    this.onTapAd,
    this.onEdited,
    this.onDeleted,
    this.onLikeToggle,
    this.onRepostToggle,
  });

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
    return NilePressable(
      child: Material(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.lg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () async {
            onTapAd?.call();
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
              if (isSponsored) const _SponsoredTag(padded: true),
              if (fromNetwork && !isSponsored) const _NetworkTag(padded: true),
              if (event.repostedByUsername != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(NileSpacing.s12, NileSpacing.s8, NileSpacing.s12, 0),
                  child: _RepostHeader(username: event.repostedByUsername!),
                ),
              _Thumbnail(event: event, hero: event.repostedByUsername == null),
              Padding(
                padding: const EdgeInsets.all(NileSpacing.s12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 14,
                          backgroundColor: NileColors.bgRaised,
                          backgroundImage: event.hostAvatarUrl != null
                              ? nileAvatarImage(event.hostAvatarUrl!, 14)
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
                            style: NileTextStyles.caption(),
                          ),
                        ] else
                          Text(
                            _timeAgo(event.createdAt),
                            style: NileTextStyles.caption(),
                          ),
                        if (onEdited != null)
                          _ContentMenu(
                            onEdit: () async {
                              final updated = await Navigator.push<Event>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => EditEventScreen(event: event),
                                ),
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
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (onLikeToggle != null)
                          LikeButton(
                            liked: event.likedByMe,
                            count: event.likeCount,
                            onTap: onLikeToggle!,
                            onCountTap: () =>
                                LikeListScreen.openEvent(context, event.id),
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
                          onTap: () => ShareToSheet.showEvent(
                            context,
                            eventId: event.id,
                            shareText: _shareText(),
                          ),
                          borderRadius: BorderRadius.circular(NileRadius.sm),
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: NileSpacing.s4,
                              vertical: NileSpacing.s4,
                            ),
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
            ],
          ),
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
        Icon(Icons.bolt, size: 14, color: NileColors.volt),
        const SizedBox(width: 4),
        Text(
          'From your network',
          style: NileTextStyles.caption().copyWith(
            color: NileColors.txtTertiary,
          ),
        ),
      ],
    );
    return padded
        ? Padding(padding: const EdgeInsets.fromLTRB(NileSpacing.s12, NileSpacing.s12, NileSpacing.s12, 0), child: row)
        : row;
  }
}

// ── "Sponsored" tag ──────────────────────────────────────────────────────────

/// Ad disclosure marking a paid (sponsored) feed item. Deliberately muted, not
/// Volt, so it reads as a disclosure and not a CTA — and FTC/app-store rules
/// require it to be unambiguous. Layout mirrors [_NetworkTag].
class _SponsoredTag extends StatelessWidget {
  final bool padded;
  const _SponsoredTag({this.padded = false});

  @override
  Widget build(BuildContext context) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.campaign_outlined,
          size: 14,
          color: NileColors.txtTertiary,
        ),
        const SizedBox(width: 4),
        Text(
          'Sponsored',
          style: NileTextStyles.caption().copyWith(
            color: NileColors.txtTertiary,
          ),
        ),
      ],
    );
    return padded
        ? Padding(padding: const EdgeInsets.fromLTRB(NileSpacing.s12, NileSpacing.s12, NileSpacing.s12, 0), child: row)
        : row;
  }
}

// ── Standalone advertiser creative card (Phase A-4) ────────────────────────────

/// Renders an external advertiser's standalone ad: 4:3 image, headline, body,
/// advertiser name, and a "Sponsored" disclosure. Tapping logs a click and
/// opens the external [AdCreative.clickUrl] in the system browser — never an
/// in-app webview (preserves the no-IAP posture). No like/comment/repost.
class _AdCreativeCard extends StatelessWidget {
  final AdCreative creative;
  final String campaignId;
  final VoidCallback onTap;

  /// Removes this card from the feed (after "Not interested" or a submitted
  /// report), so the viewer doesn't keep seeing an ad they dismissed.
  final VoidCallback onDismiss;
  const _AdCreativeCard({
    required this.creative,
    required this.campaignId,
    required this.onTap,
    required this.onDismiss,
  });

  Future<void> _open(BuildContext context) async {
    onTap();
    final uri = Uri.tryParse(creative.clickUrl);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open link')),
      );
    }
  }

  void _notInterested(BuildContext context) {
    AdService.logNotInterested(campaignId);
    onDismiss();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Thanks — you'll see fewer ads like this.")),
    );
  }

  Future<void> _report(BuildContext context) async {
    final submitted = await Moderation.showReportSheet(
      context,
      targetType: ReportTargetType.ad,
      targetId: campaignId,
    );
    if (submitted) onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    return NilePressable(
      child: Material(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.lg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _open(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 4 / 3,
                child: Image.network(
                  creative.imageUrl,
                  fit: BoxFit.cover,
                  cacheWidth: nileDecodeWidth(600),
                  errorBuilder: (_, _, _) =>
                      Container(color: NileColors.bgRaised),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  NileSpacing.s12, NileSpacing.s8, NileSpacing.s4, NileSpacing.s12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Expanded(child: _SponsoredTag()),
                        SizedBox(
                          height: 28,
                          width: 28,
                          child: PopupMenuButton<String>(
                            padding: EdgeInsets.zero,
                            iconSize: 18,
                            tooltip: 'Ad options',
                            icon: Icon(
                              Icons.more_horiz,
                              color: NileColors.txtTertiary,
                            ),
                            color: NileColors.bgSurface,
                            onSelected: (v) {
                              if (v == 'not_interested') {
                                _notInterested(context);
                              } else if (v == 'report') {
                                _report(context);
                              }
                            },
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'not_interested',
                                child: Text(
                                  'Not interested',
                                  style: NileTextStyles.bodyMd(),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'report',
                                child: Text(
                                  'Report ad',
                                  style: NileTextStyles.bodyMd()
                                      .copyWith(color: NileColors.error),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: NileSpacing.s8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(creative.headline,
                              style: NileTextStyles.headingSm()),
                          const SizedBox(height: 4),
                          Text(
                            creative.body,
                            style: NileTextStyles.bodyMd()
                                .copyWith(color: NileColors.txtSecondary),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            creative.advertiserName,
                            style: NileTextStyles.labelSm()
                                .copyWith(color: NileColors.txtTertiary),
                          ),
                        ],
                      ),
                    ),
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

// ── Post card ─────────────────────────────────────────────────────────────────

class _PostCard extends StatelessWidget {
  final Post post;
  final bool fromNetwork;
  final bool isSponsored;
  final VoidCallback? onTapAd;
  final void Function(Post)? onEdited;
  final VoidCallback? onDeleted;
  final VoidCallback? onLikeToggle;
  final VoidCallback? onRepostToggle;
  final void Function(Post)? onUpdated;
  const _PostCard({
    required this.post,
    this.fromNetwork = false,
    this.isSponsored = false,
    this.onTapAd,
    this.onEdited,
    this.onDeleted,
    this.onLikeToggle,
    this.onRepostToggle,
    this.onUpdated,
  });

  String _shareText() =>
      ShareUrls.postCaption(id: post.id, authorUsername: post.authorUsername);

  Future<void> _openDetail(BuildContext context) async {
    onTapAd?.call();
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
    return NilePressable(
      child: Material(
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
                if (isSponsored) ...[
                  const _SponsoredTag(),
                  const SizedBox(height: 8),
                ] else if (fromNetwork) ...[
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
                      _ContentMenu(
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
                                final ok = await _confirmDelete(
                                  context,
                                  'post',
                                );
                                if (ok) {
                                  try {
                                    await PostService.delete(post.id);
                                    onDeleted!();
                                  } catch (e) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
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
                      LikeButton(
                        liked: post.likedByMe,
                        count: post.likeCount,
                        onTap: onLikeToggle!,
                        onCountTap: () =>
                            LikeListScreen.openPost(context, post.id),
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
                      _RepostButton(
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
                        padding: EdgeInsets.symmetric(
                          horizontal: NileSpacing.s4,
                          vertical: NileSpacing.s4,
                        ),
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

// ── Thumbnail ─────────────────────────────────────────────────────────────────

class _Thumbnail extends StatelessWidget {
  final Event event;

  /// Disabled on repost cards: the original card owns this event's Hero, and
  /// two live Heroes with one tag abort every flight in the route.
  final bool hero;
  const _Thumbnail({required this.event, this.hero = true});

  @override
  Widget build(BuildContext context) {
    final placeholder = EventCoverPlaceholder(seed: event.id);
    final image = event.thumbnailUrl != null
        ? Image.network(
            event.thumbnailUrl!,
            cacheWidth: nileDecodeWidth(600),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => placeholder,
          )
        : placeholder;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hero)
            Hero(tag: 'event-cover-${event.id}', child: image)
          else
            image,
          const DecoratedBox(decoration: NileEffects.coverScrim),
          Positioned(top: 8, left: 8, child: EventCoverPill(event: event)),
        ],
      ),
    );
  }
}

// ── Live Now rail ─────────────────────────────────────────────────────────────

/// Horizontal shelf of currently-live events, pinned at the top of Home for
/// every user (Phase 3). Mirrors Discover's network-rail shelf. Fed by
/// [EventService.getLiveNow]; the caller hides it entirely when empty.
class _LiveNowRail extends StatelessWidget {
  final List<Event> events;
  final void Function(Event) onTap;
  const _LiveNowRail({required this.events, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NileSpacing.s16,
            NileSpacing.s8,
            NileSpacing.s16,
            0,
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: NileColors.coral,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text('Live now', style: NileTextStyles.labelMd()),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 184,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s16),
            itemCount: events.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (_, i) => SizedBox(
              width: 220,
              child: _LiveNowCard(
                event: events[i],
                onTap: () => onTap(events[i]),
              ),
            ),
          ),
        ),
        const SizedBox(height: NileSpacing.s8),
      ],
    );
  }
}

class _LiveNowCard extends StatelessWidget {
  final Event event;
  final VoidCallback onTap;
  const _LiveNowCard({required this.event, required this.onTap});

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
              Expanded(child: _LiveThumbnail(event: event)),
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
      ),
    );
  }
}

/// Live event cover for a rail card: image (or gradient placeholder) under a
/// scrim, LIVE badge top-left, viewer count top-right. No Hero — the rail and
/// the viewer screen don't share a cover transition.
class _LiveThumbnail extends StatelessWidget {
  final Event event;
  const _LiveThumbnail({required this.event});

  @override
  Widget build(BuildContext context) {
    final placeholder = EventCoverPlaceholder(seed: event.id);
    final image = event.thumbnailUrl != null
        ? Image.network(
            event.thumbnailUrl!,
            cacheWidth: nileDecodeWidth(600),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => placeholder,
          )
        : placeholder;
    return Stack(
      fit: StackFit.expand,
      children: [
        image,
        const DecoratedBox(decoration: NileEffects.coverScrim),
        Positioned(top: 8, left: 8, child: EventCoverPill(event: event)),
        Positioned(
          top: 8,
          right: 8,
          child: _ViewerCountPill(count: event.viewerCount),
        ),
      ],
    );
  }
}

class _ViewerCountPill extends StatelessWidget {
  final int count;
  const _ViewerCountPill({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: NileSpacing.s8,
        vertical: NileSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(NileRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.visibility, size: 12, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            '$count',
            style: NileTextStyles.caption().copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Empty / error states ──────────────────────────────────────────────────────

/// One-line header above the cold-start starter section. In zero-follow mode
/// it explains why the fill is shown and can be dismissed; in thin-feed mode
/// it's a plain "Suggested for you" divider.
class _StarterHeader extends StatelessWidget {
  final String label;
  final VoidCallback? onDismiss;
  const _StarterHeader({required this.label, this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NileSpacing.s16,
        NileSpacing.s16,
        NileSpacing.s8,
        0,
      ),
      child: Row(
        children: [
          Icon(Icons.auto_awesome, size: 16, color: NileColors.volt),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: NileTextStyles.labelMd())),
          if (onDismiss != null)
            IconButton(
              onPressed: onDismiss,
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              color: NileColors.txtTertiary,
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close),
            ),
        ],
      ),
    );
  }
}

class _EmptyFollows extends StatelessWidget {
  const _EmptyFollows({this.onFindPeople});
  final VoidCallback? onFindPeople;

  @override
  Widget build(BuildContext context) => NileEmptyState(
    icon: Icons.person_add_outlined,
    title: 'Follow creators',
    body: 'Follow people to fill your feed with their events and posts.',
    actionLabel: onFindPeople == null ? null : 'Find people to follow',
    onAction: onFindPeople,
  );
}

class _EmptyFeed extends StatelessWidget {
  const _EmptyFeed({this.onFindPeople});
  final VoidCallback? onFindPeople;

  @override
  Widget build(BuildContext context) => NileEmptyState(
    icon: Icons.live_tv,
    title: 'No events right now',
    body: 'Check back later, or find more creators to follow.',
    actionLabel: onFindPeople == null ? null : 'Discover creators',
    onAction: onFindPeople,
  );
}

// ── Shared edit/delete helpers ────────────────────────────────────────────────

Future<bool> _confirmDelete(BuildContext context, String itemType) async {
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

/// Three-dot popup menu used on owned content cards.
class _ContentMenu extends StatelessWidget {
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  const _ContentMenu({this.onEdit, this.onDelete});

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
