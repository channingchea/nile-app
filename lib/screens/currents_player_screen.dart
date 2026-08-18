import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../router.dart';
import '../services/ad_service.dart';
import '../services/current_service.dart';
import '../services/follow_service.dart';
import '../services/nile_shortcuts.dart';
import '../services/report_service.dart';
import 'package:share_plus/share_plus.dart';

import '../services/share_urls.dart';
import '../services/supabase_client.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/official_badge.dart';
import 'widgets/moderation_menu.dart';

/// Full-screen vertical Currents player: swipe between ≤60s videos, autoplay,
/// auto-advance on completion, with a sponsored video slot after every Nth
/// Current (cadence from app_config, docs/plans/currents.md Phase 4).
class CurrentsPlayerScreen extends StatefulWidget {
  /// Jump to this creator's first unwatched Current (rail tap). Null starts at
  /// the top of the feed.
  final String? startUserId;

  const CurrentsPlayerScreen({super.key, this.startUserId});

  @override
  State<CurrentsPlayerScreen> createState() => _CurrentsPlayerScreenState();
}

sealed class _PlayerItem {
  String get videoUrl;
}

class _CurrentItem extends _PlayerItem {
  Current current;
  _CurrentItem(this.current);
  @override
  String get videoUrl => current.videoUrl;
}

class _AdItem extends _PlayerItem {
  final CurrentAd ad;
  _AdItem(this.ad);
  @override
  String get videoUrl => ad.videoUrl;
}

class _CurrentsPlayerScreenState extends State<CurrentsPlayerScreen>
    with TickerProviderStateMixin {
  List<_PlayerItem>? _items;
  String? _error;

  late final PageController _pager;
  final Map<int, VideoPlayerController> _controllers = {};
  int _index = 0;
  bool _advancing = false;

  /// Drives the current image Current's slideshow (null while a video is active).
  /// One controller runs the whole slideshow; its value maps to the current
  /// frame via [_slideAt].
  AnimationController? _slideCtrl;

  /// Session-wide mute preference.
  static bool muted = false;

  final Set<String> _viewLogged = {};
  final Set<String> _adImpressionLogged = {};
  Timer? _dwellTimer;

  /// Impression/view only counts after this long on screen (honest CPM;
  /// instant swipe-aways never bill).
  static const _dwell = Duration(seconds: 2);

  // ── Desktop state ──────────────────────────────────────────────────────────

  /// True only while a windowed layout is on screen and nothing is stacked
  /// above this route. Written from [build] rather than worked out inside the
  /// key handler, because the answer depends on MediaQuery and on the route —
  /// both of which are only safe to read while building.
  bool _keysLive = false;

  /// Follow state the desktop column has changed this session, keyed by author.
  /// Kept here rather than on the model: [Current.copyWith] deliberately
  /// doesn't carry `isFollowed`, and widening it for one button on one layout
  /// would change what every other screen's copy means.
  final Map<String, bool> _following = {};

  /// Authors with a follow request in flight, so a double-click can't send two.
  final Set<String> _followBusy = {};

  @override
  void initState() {
    super.initState();
    _pager = PageController();
    // Arrow paging is a desktop affordance — on a phone there is no keyboard to
    // press it with and the handler is pure overhead. Installed here and torn
    // down in dispose so it can never outlive the pager it drives.
    if (NileShortcuts.supported) {
      HardwareKeyboard.instance.addHandler(_onKey);
    }
    _load();
  }

  @override
  void dispose() {
    if (NileShortcuts.supported) {
      HardwareKeyboard.instance.removeHandler(_onKey);
    }
    _dwellTimer?.cancel();
    _slideCtrl?.dispose();
    for (final c in _controllers.values) {
      c.dispose();
    }
    _pager.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final (feed, ads, freq) = await (
        CurrentService.feed(),
        AdService.currentsAds(),
        AdService.currentsAdFrequency(),
      ).wait;
      if (feed.isEmpty) {
        if (mounted) setState(() => _error = 'No Currents to watch right now.');
        return;
      }

      // Interleave: one ad after every [freq] Currents, each ad served once.
      final items = <_PlayerItem>[];
      var adIdx = 0;
      for (var i = 0; i < feed.length; i++) {
        items.add(_CurrentItem(feed[i]));
        if ((i + 1) % freq == 0 && adIdx < ads.length) {
          items.add(_AdItem(ads[adIdx++]));
        }
      }

      // Rail tap: start at the creator's first unwatched Current (or their first).
      var start = 0;
      if (widget.startUserId != null) {
        final unwatched = items.indexWhere((it) =>
            it is _CurrentItem &&
            it.current.authorId == widget.startUserId &&
            !it.current.watchedByMe);
        final first = items.indexWhere(
            (it) => it is _CurrentItem && it.current.authorId == widget.startUserId);
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
    _slideCtrl?.dispose();
    _slideCtrl = null;
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
    if (i + 1 < _items!.length && !_isImageItem(i + 1)) {
      _controllerFor(i + 1); // prefetch next video
    }
    _armDwell(i);
  }

  bool _isImageItem(int i) {
    final it = _items![i];
    return it is _CurrentItem && it.current.isImage;
  }

  Future<void> _playCurrent(int i) async {
    final it = _items![i];
    if (it is _CurrentItem && it.current.isImage) {
      _startSlideshow(i, it);
      return;
    }
    final c = await _controllerFor(i);
    if (!mounted || _index != i) return;
    c
      ..seekTo(Duration.zero)
      ..setLooping(false)
      ..play();
    c.addListener(() => _maybeAdvance(i, c));
  }

  /// Run an image Current as a timed slideshow: one controller spans all frames,
  /// its value * total = elapsed ms. On completion, advance to the next Current.
  void _startSlideshow(int i, _CurrentItem it) {
    _slideCtrl?.dispose();
    final total = it.current.images.fold<int>(0, (s, im) => s + im.durationMs);
    final ctrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: total <= 0 ? 1 : total),
    )..addStatusListener((s) {
        if (s == AnimationStatus.completed) _advanceFrom(i);
      });
    _slideCtrl = ctrl;
    ctrl.forward();
    if (mounted) setState(() {});
  }

  /// Which frame is showing at normalized progress [t] (0–1).
  int _slideAt(List<CurrentImage> imgs, double t) {
    final total = imgs.fold<int>(0, (s, im) => s + im.durationMs);
    final elapsed = t * total;
    var acc = 0.0;
    for (var k = 0; k < imgs.length; k++) {
      acc += imgs[k].durationMs;
      if (elapsed < acc) return k;
    }
    return imgs.isEmpty ? 0 : imgs.length - 1;
  }

  /// Advance to the next item, or pop after the last one.
  void _advanceFrom(int i) {
    if (!mounted || _index != i || _advancing) return;
    _advancing = true;
    if (i + 1 < _items!.length) {
      _pager.nextPage(duration: NileMotion.base, curve: NileMotion.curve);
    } else {
      Navigator.pop(context);
    }
  }

  /// Auto-advance when the current video finishes.
  void _maybeAdvance(int i, VideoPlayerController c) {
    if (!mounted || _index != i || _advancing) return;
    final v = c.value;
    if (v.duration > Duration.zero &&
        v.position >= v.duration &&
        !v.isPlaying) {
      _advanceFrom(i);
    }
  }

  void _armDwell(int i) {
    _dwellTimer = Timer(_dwell, () {
      if (!mounted || _index != i) return;
      final it = _items![i];
      if (it is _CurrentItem) {
        // Watching your own Current isn't a view — it would inflate the count
        // and dim your own rail ring.
        if (it.current.authorId == supabase.auth.currentUser?.id) return;
        if (_viewLogged.add(it.current.id)) {
          CurrentService.logView(it.current.id);
          setState(() {
            it.current = it.current
                .copyWith(watchedByMe: true, viewCount: it.current.viewCount + 1);
          });
        }
      } else if (it is _AdItem) {
        if (_adImpressionLogged.add(it.ad.campaignId)) {
          AdService.logImpression(it.ad.campaignId);
        }
      }
    });
  }

  /// Tap zones: left third back, right third forward, middle play/pause.
  /// Inside a multi-image Current the side zones step frames first, and only
  /// move to the next/previous Current once its frames run out. Forward past
  /// the last item closes the player, like auto-advance does.
  void _onTapZone(TapUpDetails d, [double? zoneWidth]) {
    // The zones are thirds of the box that was tapped, not of the window: on
    // desktop the player is a ~450 pt column in the middle of a 1400 pt screen.
    final w = zoneWidth ?? MediaQuery.sizeOf(context).width;
    final dx = d.localPosition.dx;
    if (dx < w / 3) {
      if (_stepFrame(-1)) return;
      if (_index > 0) {
        _pager.previousPage(
            duration: NileMotion.base, curve: NileMotion.curve);
      }
    } else if (dx > w * 2 / 3) {
      if (_stepFrame(1)) return;
      _advanceFrom(_index);
    } else {
      _togglePause();
    }
  }

  /// Jump [delta] frames within the image Current on screen. False when there
  /// is no such frame (or this isn't a slideshow), so the caller can page on.
  bool _stepFrame(int delta) {
    final it = _items![_index];
    final ctrl = _slideCtrl;
    if (ctrl == null || it is! _CurrentItem || !it.current.isImage) return false;
    final imgs = it.current.images;
    if (imgs.length < 2) return false;
    final k = _slideAt(imgs, ctrl.value) + delta;
    if (k < 0 || k >= imgs.length) return false;
    final total = imgs.fold<int>(0, (s, im) => s + im.durationMs);
    if (total <= 0) return false;
    var start = 0;
    for (var j = 0; j < k; j++) {
      start += imgs[j].durationMs;
    }
    // forward() from here runs the remaining fraction of the total duration,
    // so each frame keeps its own dwell time.
    ctrl.value = start / total;
    ctrl.forward();
    return true;
  }

  /// Up / Down (and J / K) page the feed on desktop.
  ///
  /// Handled here rather than as a [NileShortcuts] binding: those drive the
  /// list that currently has focus, and this screen is a pager, not a list.
  /// The one rule that carries over is the important one — every binding is a
  /// bare key, and the comment composer is a click away, so a focused text
  /// field takes the keystroke and this handler never sees it.
  bool _onKey(KeyEvent event) {
    if (!_keysLive) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    // Same check, and the same reason, as NileShortcuts._typing: typing "jk"
    // into a comment must type j and k.
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null && focused.widget is EditableText) return false;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed) {
      return false; // ⌘1–⌘5 and friends belong to NileShortcuts.
    }

    final key = event.logicalKey;
    switch (key) {
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.keyJ:
        _pageBy(1);
        return true;
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.keyK:
        _pageBy(-1);
        return true;
    }
    return false;
  }

  /// Keyboard paging, routed through the same helpers as the tap zones so the
  /// two can't disagree about what "next" means — including stepping a
  /// slideshow's frames before leaving the Current it belongs to.
  void _pageBy(int delta) {
    final items = _items;
    if (items == null || items.isEmpty) return;
    if (_stepFrame(delta)) return;
    if (delta > 0) {
      _advanceFrom(_index);
    } else if (_index > 0) {
      _pager.previousPage(duration: NileMotion.base, curve: NileMotion.curve);
    }
  }

  void _togglePause() {
    if (_isImageItem(_index)) {
      final s = _slideCtrl;
      if (s == null) return;
      setState(() => s.isAnimating ? s.stop() : s.forward());
      return;
    }
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

  /// Pause whatever is playing on the current page (video or slideshow) — used
  /// while a modal sheet is open.
  void _pauseCurrent() {
    if (_isImageItem(_index)) {
      _slideCtrl?.stop();
    } else {
      _controllers[_index]?.pause();
    }
  }

  void _resumeCurrent() {
    if (_isImageItem(_index)) {
      _slideCtrl?.forward();
    } else {
      _controllers[_index]?.play();
    }
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _toggleLike(_CurrentItem it) async {
    final r = it.current;
    setState(() {
      it.current = r.copyWith(
        likedByMe: !r.likedByMe,
        likeCount: r.likeCount + (r.likedByMe ? -1 : 1),
      );
    });
    try {
      r.likedByMe
          ? await CurrentService.unlike(r.id)
          : await CurrentService.like(r.id);
    } catch (_) {
      if (mounted) setState(() => it.current = r); // revert
    }
  }

  bool _isFollowing(Current c) => _following[c.authorId] ?? c.isFollowed;

  /// Optimistic, like [_toggleLike]: the button flips now and reverts if the
  /// write fails. Desktop only — the phone overlay has no room for it.
  Future<void> _toggleFollow(Current c) async {
    final id = c.authorId;
    if (!_followBusy.add(id)) return;
    final next = !_isFollowing(c);
    setState(() => _following[id] = next);
    try {
      next ? await FollowService.follow(id) : await FollowService.unfollow(id);
    } catch (_) {
      if (mounted) setState(() => _following[id] = !next); // revert
    } finally {
      _followBusy.remove(id);
    }
  }

  Future<void> _openComments(_CurrentItem it) async {
    _pauseCurrent();
    await showModalBottomSheet(
      context: context,
      backgroundColor: NileColors.bgSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(NileRadius.lg)),
      ),
      builder: (_) => _CurrentCommentsSheet(
        current: it.current,
        onCountChanged: (delta) => setState(() {
          it.current =
              it.current.copyWith(commentCount: it.current.commentCount + delta);
        }),
      ),
    );
    if (mounted) _resumeCurrent();
  }

  void _share(_CurrentItem it) {
    // Currents expire in 24h, so the durable share target is the creator's
    // profile link (rich DM cards for currents are a non-goal in v1).
    Share.share(
      '@${it.current.authorUsername} on Nile\n'
      '${ShareUrls.profile(it.current.authorUsername)}',
    );
  }

  Future<void> _moreMenu(_PlayerItem item) async {
    _pauseCurrent();
    final myId = supabase.auth.currentUser?.id;
    if (item is _CurrentItem) {
      final own = item.current.authorId == myId;
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
                  title: Text('Delete Current',
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
                  title: Text('Report Current', style: NileTextStyles.bodyLg()),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    Moderation.showReportSheet(
                      context,
                      targetType: ReportTargetType.current,
                      targetId: item.current.id,
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.block),
                  title: Text('Block @${item.current.authorUsername}',
                      style: NileTextStyles.bodyLg()),
                  onTap: () async {
                    Navigator.pop(sheetCtx);
                    final blocked = await Moderation.confirmBlock(
                      context,
                      userId: item.current.authorId,
                      username: item.current.authorUsername,
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
    if (mounted) _resumeCurrent();
  }

  Future<void> _deleteOwn(_CurrentItem it) async {
    try {
      await CurrentService.delete(it.current);
      if (!mounted) return;
      final items = _items!..remove(it);
      if (items.whereType<_CurrentItem>().isEmpty) {
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

  Future<void> _openAd(CurrentAd ad) async {
    AdService.logClick(ad.campaignId);
    final uri = Uri.tryParse(ad.clickUrl);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // The chrome hands this route the whole width left of the nav rail
    // (NileAppShell.wantsFullWidth), which is what the columns below are for.
    // A window with no rail is a phone or a Split View pane, and there gets the
    // full-bleed pager that shipped to beta, untouched.
    if (!NileBreakpoints.of(context).hasNavRail) {
      _keysLive = false;
      return _buildCompactBody();
    }
    // Nothing stacked above us: a sheet or a dialog holds the keyboard while it
    // is open, and paging the feed behind it would be paging something nobody
    // is looking at.
    _keysLive = ModalRoute.of(context)?.isCurrent ?? true;
    // Decided on measured width, not window class: a nav rail starts at the
    // iPad mini, and that window has nothing like the room for three columns.
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth >= _contextAt
          ? _buildDesktopBody(constraints.maxWidth)
          : _buildCompactBody(),
    );
  }

  Widget _buildCompactBody() {
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
    // Horizontal paging leaves the vertical axis free for swipe-down-to-exit.
    return GestureDetector(
      onVerticalDragEnd: _maybeDismiss,
      child: Stack(
        children: [
          PageView.builder(
            controller: _pager,
            scrollDirection: Axis.horizontal,
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
                  child: _topButton(
                    muted ? Icons.volume_off : Icons.volume_up,
                    _toggleMute,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A flick downwards closes the player (the pager owns horizontal drags).
  void _maybeDismiss(DragEndDetails d) {
    if ((d.primaryVelocity ?? 0) > 250) Navigator.pop(context);
  }

  Widget _closeButton() {
    return Positioned(
      top: NileSpacing.s4,
      left: NileSpacing.s8,
      child: _topButton(Icons.close, () => Navigator.pop(context)),
    );
  }

  /// Top control on a dark disc — the video behind can be any brightness, so a
  /// bare white glyph disappears against pale footage.
  Widget _topButton(IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.black45,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(NileSpacing.s8),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }

  /// [overlays] false strips the creator/ad chrome and its scrim: on desktop
  /// those live in the left column, and the video is left unobstructed.
  /// [tapWidth] is the player's own width where that isn't the window's.
  Widget _page(_PlayerItem item, int i,
      {bool overlays = true, double? tapWidth}) {
    if (item is _CurrentItem && item.current.isImage) {
      return _imagePage(item, i, overlays: overlays, tapWidth: tapWidth);
    }
    final c = _controllers[i];
    final ready = c != null && c.value.isInitialized;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) => _onTapZone(d, tapWidth),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (ready)
            // Fit the full frame to the screen width (height-bound only when
            // the clip is taller than the viewport) — never crop the sides.
            Center(
              child: AspectRatio(
                aspectRatio: c.value.aspectRatio,
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
          if (overlays) const DecoratedBox(decoration: NileEffects.coverScrim),
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
          if (overlays)
            switch (item) {
              _CurrentItem() => _currentOverlay(item),
              _AdItem() => _adOverlay(item),
            },
        ],
      ),
    );
  }

  Widget _imagePage(_CurrentItem it, int i,
      {bool overlays = true, double? tapWidth}) {
    final imgs = it.current.images;
    final active = i == _index && _slideCtrl != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) => _onTapZone(d, tapWidth),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (active)
            AnimatedBuilder(
              animation: _slideCtrl!,
              builder: (_, _) {
                final k = _slideAt(imgs, _slideCtrl!.value);
                return _slideImage(imgs.isEmpty ? null : imgs[k].url);
              },
            )
          else
            _slideImage(imgs.isEmpty ? it.current.thumbUrl : imgs.first.url),
          // Paused glyph.
          if (active)
            AnimatedBuilder(
              animation: _slideCtrl!,
              builder: (_, _) => _slideCtrl!.isAnimating
                  ? const SizedBox.shrink()
                  : const Center(
                      child: Icon(Icons.play_arrow_rounded,
                          size: 72, color: Colors.white70),
                    ),
            ),
          if (overlays) const DecoratedBox(decoration: NileEffects.coverScrim),
          // Segmented slideshow progress (bottom, like the video bar).
          if (active)
            Positioned(
              left: NileSpacing.s2,
              right: NileSpacing.s2,
              bottom: 0,
              child: AnimatedBuilder(
                animation: _slideCtrl!,
                builder: (_, _) => _segments(imgs, _slideCtrl!.value),
              ),
            ),
          if (overlays) _currentOverlay(it),
        ],
      ),
    );
  }

  Widget _slideImage(String? url) {
    if (url == null || url.isEmpty) {
      return const ColoredBox(color: Colors.black);
    }
    // contain, not cover: landscape and portrait frames both size to the
    // screen width rather than being cropped to fill.
    return Image.network(
      url,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black),
    );
  }

  /// One thin bar per frame; completed frames full, current frame fills.
  Widget _segments(List<CurrentImage> imgs, double t) {
    if (imgs.isEmpty) return const SizedBox.shrink();
    final durs = [for (final im in imgs) im.durationMs];
    final total = durs.fold<int>(0, (s, d) => s + d);
    final elapsed = t * total;
    final starts = <int>[];
    var acc = 0;
    for (final d in durs) {
      starts.add(acc);
      acc += d;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: NileSpacing.s2),
      child: Row(
        children: [
          for (var k = 0; k < durs.length; k++)
            Expanded(
              flex: durs[k],
              child: Container(
                height: 3,
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor:
                      ((elapsed - starts[k]) / durs[k]).clamp(0.0, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: NileColors.volt,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _poster(_PlayerItem item) {
    final thumb = switch (item) {
      _CurrentItem(:final current) => current.thumbUrl,
      _AdItem(:final ad) => ad.thumbUrl,
    };
    return thumb != null
        ? Image.network(thumb, fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black))
        : Center(
            child: CircularProgressIndicator(color: NileColors.volt));
  }

  Widget _currentOverlay(_CurrentItem it) {
    final r = it.current;
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
                    onTap: () => context.push(NileRoutes.profile(r.authorId)),
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
        // Opaque so a slightly-off tap hits the action, not the "next" zone.
        behavior: HitTestBehavior.opaque,
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

  // ── Desktop ────────────────────────────────────────────────────────────────
  //
  // A Current is authored at 9:16. Stretched across the width the chrome hands
  // this route it would be a wall of video, so the player keeps its own shape
  // in the middle, and the two things the phone stacks *on top of* it — who
  // made this, and what people are saying about it — become columns either
  // side, where they obstruct nothing.

  /// Creator context. The same measure as Messages' list pane: an avatar, a
  /// name and a caption all read at this width.
  static const double _contextWidth = 320;

  /// Comments. The shared side-panel measure (NileDesktopSplit.defaultSideWidth).
  static const double _commentsWidth = 340;

  /// Below this a 9:16 player stops being a player and starts being a strip.
  static const double _minPlayerWidth = 300;

  /// Context column + player. Under it the phone's full-bleed pager is a better
  /// use of an iPad-mini-sized window than two squeezed columns.
  static const double _contextAt = _contextWidth + 1 + _minPlayerWidth;

  /// …plus the comment column. Below it, comments stay behind the sheet they
  /// open on a phone.
  static const double _commentsAt = _contextAt + 1 + _commentsWidth;

  Widget _buildDesktopBody(double width) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(NileSpacing.s24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: NileTextStyles.bodyLg()
                .copyWith(color: NileColors.txtSecondary),
          ),
        ),
      );
    }
    final items = _items;
    if (items == null) {
      return Center(child: CircularProgressIndicator(color: NileColors.volt));
    }
    if (items.isEmpty) return const SizedBox.shrink();
    // A delete can leave _index one ahead of the list for the frame before
    // _onPageChanged re-clamps it.
    final item = items[_index.clamp(0, items.length - 1)];
    final pinned = width >= _commentsAt;

    // No close button and no swipe-to-dismiss here: the chrome's top bar owns
    // back, and a click-drag across a video shouldn't throw the screen away.
    return SafeArea(
      top: false,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: _contextWidth,
            child: switch (item) {
              _CurrentItem() =>
                _desktopCurrentContext(item, commentsPinned: pinned),
              _AdItem() => _desktopAdContext(item),
            },
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _desktopPlayer(items)),
          if (pinned) ...[
            const VerticalDivider(width: 1),
            SizedBox(width: _commentsWidth, child: _desktopComments(item)),
          ],
        ],
      ),
    );
  }

  /// The pager at the shape it was shot in, centred, page background either
  /// side. [AspectRatio] takes the height when the window is short and the
  /// width when the column is narrow — "natural size, bounded by what's
  /// available", with no stretching in either direction.
  Widget _desktopPlayer(List<_PlayerItem> items) {
    return Padding(
      padding: const EdgeInsets.all(NileSpacing.s24),
      child: Center(
        child: AspectRatio(
          aspectRatio: 9 / 16,
          child: LayoutBuilder(
            builder: (_, constraints) => ClipRRect(
              borderRadius: BorderRadius.circular(NileRadius.lg),
              child: ColoredBox(
                // Letterboxing a clip that isn't 9:16 is part of the picture
                // rather than chrome, so it stays the black the compact
                // scaffold already uses behind one.
                color: Colors.black,
                child: PageView.builder(
                  controller: _pager,
                  scrollDirection: Axis.horizontal,
                  onPageChanged: _onPageChanged,
                  itemCount: items.length,
                  itemBuilder: (_, i) => _page(
                    items[i],
                    i,
                    overlays: false,
                    tapWidth: constraints.maxWidth,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _desktopCurrentContext(
    _CurrentItem it, {
    required bool commentsPinned,
  }) {
    final r = it.current;
    final own = r.authorId == supabase.auth.currentUser?.id;
    final comments =
        '${r.commentCount} ${r.commentCount == 1 ? 'comment' : 'comments'}';
    return ListView(
      padding: const EdgeInsets.all(NileSpacing.s16),
      children: [
        InkWell(
          onTap: () => context.push(NileRoutes.profile(r.authorId)),
          borderRadius: BorderRadius.circular(NileRadius.sm),
          child: Padding(
            padding: const EdgeInsets.all(NileSpacing.s4),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: NileColors.bgRaised,
                  backgroundImage: r.authorAvatarUrl != null
                      ? nileAvatarImage(r.authorAvatarUrl!, 24)
                      : null,
                  child: r.authorAvatarUrl == null
                      ? Icon(Icons.person,
                          size: 24, color: NileColors.txtTertiary)
                      : null,
                ),
                const SizedBox(width: NileSpacing.s12),
                Flexible(
                  child: Text(
                    '@${r.authorUsername}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NileTextStyles.labelLg(),
                  ),
                ),
                if (r.authorIsOfficial) ...[
                  const SizedBox(width: NileSpacing.s4),
                  const OfficialBadge(size: 16),
                ],
              ],
            ),
          ),
        ),
        if (!own) ...[
          const SizedBox(height: NileSpacing.s12),
          SizedBox(
            width: double.infinity,
            child: _isFollowing(r)
                ? OutlinedButton(
                    onPressed: () => _toggleFollow(r),
                    child: const Text('Following'),
                  )
                : FilledButton(
                    onPressed: () => _toggleFollow(r),
                    child: const Text('Follow'),
                  ),
          ),
        ],
        if (r.caption != null && r.caption!.isNotEmpty) ...[
          const SizedBox(height: NileSpacing.s16),
          // The whole caption, not the overlay's three lines — this column
          // scrolls, and nothing is sitting on top of a video here.
          Text(r.caption!, style: NileTextStyles.bodyMd()),
        ],
        const SizedBox(height: NileSpacing.s12),
        Text(
          '${r.viewCount} ${r.viewCount == 1 ? 'view' : 'views'}',
          style: NileTextStyles.caption().tabular,
        ),
        const Divider(height: NileSpacing.s24),
        _desktopAction(
          icon: r.likedByMe ? Icons.favorite : Icons.favorite_border,
          label: '${r.likeCount} ${r.likeCount == 1 ? 'like' : 'likes'}',
          color: r.likedByMe ? NileColors.coral : null,
          onTap: () => _toggleLike(it),
        ),
        // With the column pinned the comments are already on screen, so this
        // row is the count and nothing more.
        if (commentsPinned)
          _desktopStat(icon: Icons.mode_comment_outlined, label: comments)
        else
          _desktopAction(
            icon: Icons.mode_comment_outlined,
            label: comments,
            onTap: () => _openComments(it),
          ),
        _desktopAction(
          icon: Icons.share_outlined,
          label: 'Share',
          onTap: () => _share(it),
        ),
        _desktopAction(
          icon: muted ? Icons.volume_off : Icons.volume_up,
          label: muted ? 'Unmute' : 'Mute',
          onTap: _toggleMute,
        ),
        _desktopAction(
          icon: Icons.more_horiz,
          label: 'More',
          onTap: () => _moreMenu(it),
        ),
      ],
    );
  }

  Widget _desktopAdContext(_AdItem it) {
    final ad = it.ad;
    return ListView(
      padding: const EdgeInsets.all(NileSpacing.s16),
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: NileSpacing.s6, vertical: NileSpacing.s2),
              decoration: BoxDecoration(
                color: NileColors.bgRaised,
                borderRadius: BorderRadius.circular(NileRadius.xs),
              ),
              child: Text('Sponsored', style: NileTextStyles.caption()),
            ),
          ],
        ),
        const SizedBox(height: NileSpacing.s12),
        Text(
          ad.advertiserName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: NileTextStyles.labelLg(),
        ),
        const SizedBox(height: NileSpacing.s8),
        Text(ad.headline, style: NileTextStyles.headingSm()),
        if (ad.body != null && ad.body!.isNotEmpty) ...[
          const SizedBox(height: NileSpacing.s8),
          Text(ad.body!, style: NileTextStyles.bodySm()),
        ],
        const SizedBox(height: NileSpacing.s16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => _openAd(ad),
            child: const Text('Learn more'),
          ),
        ),
        const Divider(height: NileSpacing.s24),
        _desktopAction(
          icon: muted ? Icons.volume_off : Icons.volume_up,
          label: muted ? 'Unmute' : 'Mute',
          onTap: _toggleMute,
        ),
        _desktopAction(
          icon: Icons.more_horiz,
          label: 'More',
          onTap: () => _moreMenu(it),
        ),
      ],
    );
  }

  /// The phone's sheet, pinned open as a column. Same widget, same fetching and
  /// paging — it is told it is embedded and drops the sheet furniture.
  Widget _desktopComments(_PlayerItem item) {
    if (item is! _CurrentItem) {
      return const NileEmptyState(
        icon: Icons.mode_comment_outlined,
        title: 'No comments',
        body: "Sponsored posts don't take comments.",
      );
    }
    return _CurrentCommentsSheet(
      // Keyed on the Current: paging has to mount a clean sheet rather than
      // hand a State still fetching the last one's comments a new model.
      key: ValueKey(item.current.id),
      current: item.current,
      embedded: true,
      onCountChanged: (delta) => setState(() {
        item.current =
            item.current.copyWith(commentCount: item.current.commentCount + delta);
      }),
    );
  }

  /// One row of the desktop action list. Labelled, unlike the phone's glyph
  /// column: there is room for words here, and a pointer has none of the
  /// muscle memory a thumb has for a stack of icons.
  Widget _desktopAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    final tint = color ?? NileColors.txtPrimary;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(NileRadius.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NileRadius.sm),
        child: Padding(
          padding: const EdgeInsets.all(NileSpacing.s8),
          child: Row(
            children: [
              Icon(icon, size: 22, color: tint),
              const SizedBox(width: NileSpacing.s12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NileTextStyles.bodyMd().copyWith(color: tint),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Same shape as [_desktopAction], but nothing happens when you click it.
  Widget _desktopStat({required IconData icon, required String label}) {
    return Padding(
      padding: const EdgeInsets.all(NileSpacing.s8),
      child: Row(
        children: [
          Icon(icon, size: 22, color: NileColors.txtSecondary),
          const SizedBox(width: NileSpacing.s12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NileTextStyles.bodyMd()
                  .copyWith(color: NileColors.txtSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Comments sheet ────────────────────────────────────────────────────────────

class _CurrentCommentsSheet extends StatefulWidget {
  final Current current;
  final void Function(int delta) onCountChanged;

  /// Pinned open as the desktop comment column instead of presented as a modal
  /// sheet: it fills the space it is given, and drops the grab handle for a
  /// sheet that isn't there to drag.
  final bool embedded;

  const _CurrentCommentsSheet({
    super.key,
    required this.current,
    required this.onCountChanged,
    this.embedded = false,
  });

  @override
  State<_CurrentCommentsSheet> createState() => _CurrentCommentsSheetState();
}

class _CurrentCommentsSheetState extends State<_CurrentCommentsSheet> {
  final _input = TextEditingController();
  List<CurrentComment>? _comments;
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
      final page = await CurrentService.comments(widget.current.id);
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
          await CurrentService.comments(widget.current.id, cursor: _cursor);
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
          await CurrentService.addComment(currentId: widget.current.id, body: body);
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

  Future<void> _commentMenu(CurrentComment c) async {
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
                  await CurrentService.deleteComment(c.id);
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
                    targetType: ReportTargetType.currentComment,
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
    // Embedded, the column it was handed is the height it gets; as a sheet it
    // keeps the seven-tenths of the screen it has always taken.
    return SizedBox(
      height:
          widget.embedded ? null : MediaQuery.of(context).size.height * 0.7,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Column(
          children: [
            if (!widget.embedded) ...[
              const SizedBox(height: NileSpacing.s12),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: NileColors.border,
                  borderRadius: BorderRadius.circular(NileRadius.pill),
                ),
              ),
            ],
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
                    tooltip: 'Post comment',
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

  Widget _commentTile(CurrentComment c) {
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
            tooltip: 'Comment options',
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
