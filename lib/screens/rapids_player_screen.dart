import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../services/ad_service.dart';
import '../services/rapid_service.dart';
import '../services/report_service.dart';
import 'package:share_plus/share_plus.dart';

import '../services/share_urls.dart';
import '../services/supabase_client.dart';
import '../theme.dart';
import '../widgets/official_badge.dart';
import 'profile_screen.dart';
import 'widgets/moderation_menu.dart';

/// Full-screen vertical Rapids player: swipe between ≤60s videos, autoplay,
/// auto-advance on completion, with a sponsored video slot after every Nth
/// Rapid (cadence from app_config, docs/plans/rapids.md Phase 4).
class RapidsPlayerScreen extends StatefulWidget {
  /// Jump to this creator's first unwatched Rapid (rail tap). Null starts at
  /// the top of the feed.
  final String? startUserId;

  const RapidsPlayerScreen({super.key, this.startUserId});

  @override
  State<RapidsPlayerScreen> createState() => _RapidsPlayerScreenState();
}

sealed class _PlayerItem {
  String get videoUrl;
}

class _RapidItem extends _PlayerItem {
  Rapid rapid;
  _RapidItem(this.rapid);
  @override
  String get videoUrl => rapid.videoUrl;
}

class _AdItem extends _PlayerItem {
  final RapidAd ad;
  _AdItem(this.ad);
  @override
  String get videoUrl => ad.videoUrl;
}

class _RapidsPlayerScreenState extends State<RapidsPlayerScreen> {
  List<_PlayerItem>? _items;
  String? _error;

  late final PageController _pager;
  final Map<int, VideoPlayerController> _controllers = {};
  int _index = 0;
  bool _advancing = false;

  /// Session-wide mute preference.
  static bool muted = false;

  final Set<String> _viewLogged = {};
  final Set<String> _adImpressionLogged = {};
  Timer? _dwellTimer;

  /// Impression/view only counts after this long on screen (honest CPM;
  /// instant swipe-aways never bill).
  static const _dwell = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _pager = PageController();
    _load();
  }

  @override
  void dispose() {
    _dwellTimer?.cancel();
    for (final c in _controllers.values) {
      c.dispose();
    }
    _pager.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final (feed, ads, freq) = await (
        RapidService.feed(),
        AdService.rapidsAds(),
        AdService.rapidsAdFrequency(),
      ).wait;
      if (feed.isEmpty) {
        if (mounted) setState(() => _error = 'No Rapids to watch right now.');
        return;
      }

      // Interleave: one ad after every [freq] Rapids, each ad served once.
      final items = <_PlayerItem>[];
      var adIdx = 0;
      for (var i = 0; i < feed.length; i++) {
        items.add(_RapidItem(feed[i]));
        if ((i + 1) % freq == 0 && adIdx < ads.length) {
          items.add(_AdItem(ads[adIdx++]));
        }
      }

      // Rail tap: start at the creator's first unwatched Rapid (or their first).
      var start = 0;
      if (widget.startUserId != null) {
        final unwatched = items.indexWhere((it) =>
            it is _RapidItem &&
            it.rapid.authorId == widget.startUserId &&
            !it.rapid.watchedByMe);
        final first = items.indexWhere(
            (it) => it is _RapidItem && it.rapid.authorId == widget.startUserId);
        start = unwatched >= 0 ? unwatched : (first >= 0 ? first : 0);
      }

      if (!mounted) return;
      setState(() {
        _items = items;
        _index = start;
      });
      // jumpToPage needs the PageView built first.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (start > 0) _pager.jumpToPage(start);
        _onPageChanged(start);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  // ── Playback window management ─────────────────────────────────────────────

  Future<VideoPlayerController> _controllerFor(int i) async {
    final existing = _controllers[i];
    if (existing != null) return existing;
    final c = VideoPlayerController.networkUrl(Uri.parse(_items![i].videoUrl));
    _controllers[i] = c;
    await c.initialize();
    c.setVolume(muted ? 0 : 1);
    if (mounted) setState(() {});
    return c;
  }

  void _onPageChanged(int i) {
    _dwellTimer?.cancel();
    _advancing = false;
    setState(() => _index = i);

    // Keep only a {previous, current, next} controller window alive.
    final keep = {i - 1, i, i + 1};
    _controllers.removeWhere((k, c) {
      if (keep.contains(k)) return false;
      c.dispose();
      return true;
    });

    // Pause neighbors, play current, warm the next.
    for (final e in _controllers.entries) {
      if (e.key != i) e.value.pause();
    }
    _playCurrent(i);
    if (i + 1 < _items!.length) _controllerFor(i + 1); // prefetch
    _armDwell(i);
  }

  Future<void> _playCurrent(int i) async {
    final c = await _controllerFor(i);
    if (!mounted || _index != i) return;
    c
      ..seekTo(Duration.zero)
      ..setLooping(false)
      ..play();
    c.addListener(() => _maybeAdvance(i, c));
  }

  /// Auto-advance when the current video finishes; pop after the last one.
  void _maybeAdvance(int i, VideoPlayerController c) {
    if (!mounted || _index != i || _advancing) return;
    final v = c.value;
    if (v.duration > Duration.zero &&
        v.position >= v.duration &&
        !v.isPlaying) {
      _advancing = true;
      if (i + 1 < _items!.length) {
        _pager.nextPage(duration: NileMotion.base, curve: NileMotion.curve);
      } else {
        Navigator.pop(context);
      }
    }
  }

  void _armDwell(int i) {
    _dwellTimer = Timer(_dwell, () {
      if (!mounted || _index != i) return;
      final it = _items![i];
      if (it is _RapidItem) {
        if (_viewLogged.add(it.rapid.id)) {
          RapidService.logView(it.rapid.id);
          setState(() {
            it.rapid = it.rapid
                .copyWith(watchedByMe: true, viewCount: it.rapid.viewCount + 1);
          });
        }
      } else if (it is _AdItem) {
        if (_adImpressionLogged.add(it.ad.campaignId)) {
          AdService.logImpression(it.ad.campaignId);
        }
      }
    });
  }

  void _togglePause() {
    final c = _controllers[_index];
    if (c == null || !c.value.isInitialized) return;
    setState(() => c.value.isPlaying ? c.pause() : c.play());
  }

  void _toggleMute() {
    setState(() => muted = !muted);
    for (final c in _controllers.values) {
      c.setVolume(muted ? 0 : 1);
    }
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _toggleLike(_RapidItem it) async {
    final r = it.rapid;
    setState(() {
      it.rapid = r.copyWith(
        likedByMe: !r.likedByMe,
        likeCount: r.likeCount + (r.likedByMe ? -1 : 1),
      );
    });
    try {
      r.likedByMe
          ? await RapidService.unlike(r.id)
          : await RapidService.like(r.id);
    } catch (_) {
      if (mounted) setState(() => it.rapid = r); // revert
    }
  }

  Future<void> _openComments(_RapidItem it) async {
    final c = _controllers[_index];
    c?.pause();
    await showModalBottomSheet(
      context: context,
      backgroundColor: NileColors.bgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
      ),
      builder: (_) => _RapidCommentsSheet(
        rapid: it.rapid,
        onCountChanged: (delta) => setState(() {
          it.rapid =
              it.rapid.copyWith(commentCount: it.rapid.commentCount + delta);
        }),
      ),
    );
    if (mounted) c?.play();
  }

  void _share(_RapidItem it) {
    // Rapids expire in 24h, so the durable share target is the creator's
    // profile link (rich DM cards for rapids are a non-goal in v1).
    Share.share(
      '@${it.rapid.authorUsername} on Nile\n'
      '${ShareUrls.profile(it.rapid.authorUsername)}',
    );
  }

  Future<void> _moreMenu(_PlayerItem item) async {
    final c = _controllers[_index];
    c?.pause();
    final myId = supabase.auth.currentUser?.id;
    if (item is _RapidItem) {
      final own = item.rapid.authorId == myId;
      await showModalBottomSheet(
        context: context,
        backgroundColor: NileColors.bgSurface,
        shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
        ),
        builder: (sheetCtx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (own)
                ListTile(
                  leading: const Icon(Icons.delete_outline,
                      color: NileColors.error),
                  title: Text('Delete Rapid',
                      style: NileTextStyles.bodyLg()
                          .copyWith(color: NileColors.error)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _deleteOwn(item);
                  },
                )
              else ...[
                ListTile(
                  leading: const Icon(Icons.flag_outlined),
                  title: Text('Report Rapid', style: NileTextStyles.bodyLg()),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    Moderation.showReportSheet(
                      context,
                      targetType: ReportTargetType.rapid,
                      targetId: item.rapid.id,
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.block),
                  title: Text('Block @${item.rapid.authorUsername}',
                      style: NileTextStyles.bodyLg()),
                  onTap: () async {
                    Navigator.pop(sheetCtx);
                    final blocked = await Moderation.confirmBlock(
                      context,
                      userId: item.rapid.authorId,
                      username: item.rapid.authorUsername,
                    );
                    if (blocked && mounted) Navigator.pop(context);
                  },
                ),
              ],
            ],
          ),
        ),
      );
    } else if (item is _AdItem) {
      await showModalBottomSheet(
        context: context,
        backgroundColor: NileColors.bgSurface,
        shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
        ),
        builder: (sheetCtx) => SafeArea(
          child: ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: Text('Report ad', style: NileTextStyles.bodyLg()),
            onTap: () {
              Navigator.pop(sheetCtx);
              Moderation.showReportSheet(
                context,
                targetType: ReportTargetType.ad,
                targetId: item.ad.campaignId,
              );
            },
          ),
        ),
      );
    }
    if (mounted) c?.play();
  }

  Future<void> _deleteOwn(_RapidItem it) async {
    try {
      await RapidService.delete(it.rapid);
      if (!mounted) return;
      final items = _items!..remove(it);
      if (items.whereType<_RapidItem>().isEmpty) {
        Navigator.pop(context);
      } else {
        setState(() {});
        _onPageChanged(_index.clamp(0, items.length - 1));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Couldn\'t delete: $e')));
      }
    }
  }

  Future<void> _openAd(RapidAd ad) async {
    AdService.logClick(ad.campaignId);
    final uri = Uri.tryParse(ad.clickUrl);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _error != null
          ? _errorBody()
          : _items == null
              ? SafeArea(
                  child: Stack(
                    children: [
                      Center(
                          child:
                              CircularProgressIndicator(color: NileColors.volt)),
                      _closeButton(),
                    ],
                  ),
                )
              : _pagerBody(),
    );
  }

  Widget _errorBody() {
    return SafeArea(
      child: Stack(
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(NileSpacing.s24),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style:
                    NileTextStyles.bodyLg().copyWith(color: Colors.white70),
              ),
            ),
          ),
          _closeButton(),
        ],
      ),
    );
  }

  Widget _pagerBody() {
    final items = _items!;
    return Stack(
      children: [
        PageView.builder(
          controller: _pager,
          scrollDirection: Axis.vertical,
          onPageChanged: _onPageChanged,
          itemCount: items.length,
          itemBuilder: (_, i) => _page(items[i], i),
        ),
        SafeArea(
          child: Stack(
            children: [
              _closeButton(),
              Positioned(
                top: NileSpacing.s4,
                right: NileSpacing.s8,
                child: IconButton(
                  onPressed: _toggleMute,
                  icon: Icon(
                    muted ? Icons.volume_off : Icons.volume_up,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _closeButton() {
    return Positioned(
      top: NileSpacing.s4,
      left: NileSpacing.s8,
      child: IconButton(
        onPressed: () => Navigator.pop(context),
        icon: const Icon(Icons.close, color: Colors.white),
      ),
    );
  }

  Widget _page(_PlayerItem item, int i) {
    final c = _controllers[i];
    final ready = c != null && c.value.isInitialized;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _togglePause,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (ready)
            FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: c.value.size.width,
                height: c.value.size.height,
                child: VideoPlayer(c),
              ),
            )
          else
            _poster(item),
          // Paused glyph.
          if (ready && !c.value.isPlaying)
            const Center(
              child: Icon(Icons.play_arrow_rounded,
                  size: 72, color: Colors.white70),
            ),
          // Bottom scrim for overlay legibility.
          const DecoratedBox(decoration: NileEffects.coverScrim),
          // Progress.
          if (ready)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: VideoProgressIndicator(
                c,
                allowScrubbing: false,
                padding: EdgeInsets.zero,
                colors: VideoProgressColors(
                  playedColor: NileColors.volt,
                  bufferedColor: Colors.white24,
                  backgroundColor: Colors.white10,
                ),
              ),
            ),
          switch (item) {
            _RapidItem() => _rapidOverlay(item),
            _AdItem() => _adOverlay(item),
          },
        ],
      ),
    );
  }

  Widget _poster(_PlayerItem item) {
    final thumb = switch (item) {
      _RapidItem(:final rapid) => rapid.thumbUrl,
      _AdItem(:final ad) => ad.thumbUrl,
    };
    return thumb != null
        ? Image.network(thumb, fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black))
        : Center(
            child: CircularProgressIndicator(color: NileColors.volt));
  }

  Widget _rapidOverlay(_RapidItem it) {
    final r = it.rapid;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            NileSpacing.s16, 0, NileSpacing.s8, NileSpacing.s16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Author + caption.
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ProfileScreen(userId: r.authorId),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: NileColors.bgRaised,
                          backgroundImage: r.authorAvatarUrl != null
                              ? nileAvatarImage(r.authorAvatarUrl!, 16)
                              : null,
                          child: r.authorAvatarUrl == null
                              ? const Icon(Icons.person,
                                  size: 16, color: Colors.white70)
                              : null,
                        ),
                        const SizedBox(width: NileSpacing.s8),
                        Flexible(
                          child: Text(
                            '@${r.authorUsername}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NileTextStyles.labelMd()
                                .copyWith(color: Colors.white),
                          ),
                        ),
                        if (r.authorIsOfficial) ...[
                          const SizedBox(width: NileSpacing.s4),
                          const OfficialBadge(size: 14),
                        ],
                      ],
                    ),
                  ),
                  if (r.caption != null && r.caption!.isNotEmpty) ...[
                    const SizedBox(height: NileSpacing.s8),
                    Text(
                      r.caption!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: NileTextStyles.bodyMd()
                          .copyWith(color: Colors.white),
                    ),
                  ],
                  const SizedBox(height: NileSpacing.s8),
                  Text(
                    '${r.viewCount} ${r.viewCount == 1 ? 'view' : 'views'}',
                    style: NileTextStyles.caption()
                        .copyWith(color: Colors.white70)
                        .tabular,
                  ),
                ],
              ),
            ),
            // Action column.
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _action(
                  icon: r.likedByMe ? Icons.favorite : Icons.favorite_border,
                  color: r.likedByMe ? NileColors.coral : Colors.white,
                  label: '${r.likeCount}',
                  onTap: () => _toggleLike(it),
                ),
                _action(
                  icon: Icons.mode_comment_outlined,
                  label: '${r.commentCount}',
                  onTap: () => _openComments(it),
                ),
                _action(
                  icon: Icons.share_outlined,
                  onTap: () => _share(it),
                ),
                _action(
                  icon: Icons.more_horiz,
                  onTap: () => _moreMenu(it),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _adOverlay(_AdItem it) {
    final ad = it.ad;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            NileSpacing.s16, 0, NileSpacing.s8, NileSpacing.s16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: NileSpacing.s6,
                            vertical: NileSpacing.s2),
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius:
                              BorderRadius.circular(NileRadius.xs),
                        ),
                        child: Text(
                          'Sponsored',
                          style: NileTextStyles.caption()
                              .copyWith(color: Colors.white),
                        ),
                      ),
                      const SizedBox(width: NileSpacing.s8),
                      Flexible(
                        child: Text(
                          ad.advertiserName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NileTextStyles.labelMd()
                              .copyWith(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: NileSpacing.s8),
                  Text(
                    ad.headline,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: NileTextStyles.headingSm()
                        .copyWith(color: Colors.white),
                  ),
                  if (ad.body != null && ad.body!.isNotEmpty) ...[
                    const SizedBox(height: NileSpacing.s4),
                    Text(
                      ad.body!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: NileTextStyles.bodySm()
                          .copyWith(color: Colors.white70),
                    ),
                  ],
                  const SizedBox(height: NileSpacing.s12),
                  FilledButton(
                    onPressed: () => _openAd(ad),
                    style: FilledButton.styleFrom(
                      backgroundColor: NileColors.volt,
                      foregroundColor: NileColors.onVolt,
                      padding: const EdgeInsets.symmetric(
                          horizontal: NileSpacing.s24,
                          vertical: NileSpacing.s8),
                    ),
                    child: const Text('Learn more'),
                  ),
                ],
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _action(
                  icon: Icons.more_horiz,
                  onTap: () => _moreMenu(it),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _action({
    required IconData icon,
    String? label,
    Color color = Colors.white,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: NileSpacing.s12),
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30, color: color),
            if (label != null)
              Text(
                label,
                style: NileTextStyles.caption()
                    .copyWith(color: Colors.white)
                    .tabular,
              ),
          ],
        ),
      ),
    );
  }
}

// ── Comments sheet ────────────────────────────────────────────────────────────

class _RapidCommentsSheet extends StatefulWidget {
  final Rapid rapid;
  final void Function(int delta) onCountChanged;
  const _RapidCommentsSheet(
      {required this.rapid, required this.onCountChanged});

  @override
  State<_RapidCommentsSheet> createState() => _RapidCommentsSheetState();
}

class _RapidCommentsSheetState extends State<_RapidCommentsSheet> {
  final _input = TextEditingController();
  List<RapidComment>? _comments;
  String? _cursor;
  bool _hasMore = false;
  bool _loadingMore = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final page = await RapidService.comments(widget.rapid.id);
      if (!mounted) return;
      setState(() {
        _comments = page.items;
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
      });
    } catch (_) {
      if (mounted) setState(() => _comments = []);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final page =
          await RapidService.comments(widget.rapid.id, cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _comments = [..._comments!, ...page.items];
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
      });
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _send() async {
    final body = _input.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final c =
          await RapidService.addComment(rapidId: widget.rapid.id, body: body);
      if (!mounted) return;
      setState(() {
        _comments = [c, ..._comments ?? []];
        _input.clear();
      });
      widget.onCountChanged(1);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Couldn\'t comment: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _commentMenu(RapidComment c) async {
    final myId = supabase.auth.currentUser?.id;
    final own = c.authorId == myId;
    await showModalBottomSheet(
      context: context,
      backgroundColor: NileColors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: own
            ? ListTile(
                leading:
                    const Icon(Icons.delete_outline, color: NileColors.error),
                title: Text('Delete comment',
                    style: NileTextStyles.bodyLg()
                        .copyWith(color: NileColors.error)),
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  await RapidService.deleteComment(c.id);
                  if (!mounted) return;
                  setState(() => _comments!.removeWhere((x) => x.id == c.id));
                  widget.onCountChanged(-1);
                },
              )
            : ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: Text('Report comment', style: NileTextStyles.bodyLg()),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  Moderation.showReportSheet(
                    context,
                    targetType: ReportTargetType.rapidComment,
                    targetId: c.id,
                  );
                },
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Column(
          children: [
            const SizedBox(height: NileSpacing.s12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: NileColors.border,
                borderRadius: BorderRadius.circular(NileRadius.pill),
              ),
            ),
            const SizedBox(height: NileSpacing.s12),
            Text('Comments', style: NileTextStyles.headingSm()),
            const SizedBox(height: NileSpacing.s8),
            Expanded(
              child: _comments == null
                  ? Center(
                      child:
                          CircularProgressIndicator(color: NileColors.volt))
                  : _comments!.isEmpty
                      ? Center(
                          child: Text(
                            'Be the first to comment.',
                            style: NileTextStyles.bodyMd()
                                .copyWith(color: NileColors.txtTertiary),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(
                              horizontal: NileSpacing.s16),
                          itemCount: _comments!.length + (_hasMore ? 1 : 0),
                          itemBuilder: (_, i) {
                            if (i >= _comments!.length) {
                              _loadMore();
                              return Padding(
                                padding: const EdgeInsets.all(NileSpacing.s12),
                                child: Center(
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: NileColors.volt),
                                  ),
                                ),
                              );
                            }
                            return _commentTile(_comments![i]);
                          },
                        ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(NileSpacing.s12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      maxLength: 500,
                      minLines: 1,
                      maxLines: 3,
                      textCapitalization: TextCapitalization.sentences,
                      style: NileTextStyles.bodyMd(),
                      decoration: const InputDecoration(
                        hintText: 'Add a comment…',
                        counterText: '',
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: NileSpacing.s8),
                  IconButton(
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: NileColors.volt),
                          )
                        : Icon(Icons.send, color: NileColors.volt),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _commentTile(RapidComment c) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NileSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: NileColors.bgRaised,
            backgroundImage: c.authorAvatarUrl != null
                ? nileAvatarImage(c.authorAvatarUrl!, 14)
                : null,
            child: c.authorAvatarUrl == null
                ? Icon(Icons.person, size: 14, color: NileColors.txtTertiary)
                : null,
          ),
          const SizedBox(width: NileSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        '@${c.authorUsername}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NileTextStyles.labelMd(),
                      ),
                    ),
                    if (c.authorIsOfficial) ...[
                      const SizedBox(width: NileSpacing.s4),
                      const OfficialBadge(size: 12),
                    ],
                  ],
                ),
                const SizedBox(height: NileSpacing.s2),
                Text(c.body, style: NileTextStyles.bodyMd()),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => _commentMenu(c),
            icon: Icon(Icons.more_horiz,
                size: 18, color: NileColors.txtTertiary),
          ),
        ],
      ),
    );
  }
}
