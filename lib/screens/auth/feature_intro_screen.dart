import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../theme.dart';
import '../../widgets/nile_logo.dart';

/// First-launch feature tour, shown once before the login screen on the
/// native app builds (iOS, Android, macOS). Four swipeable pages pitch the
/// app viewer-first, then hand off to signup or login. Seen-state is a local
/// device flag, so a reinstall replays it.
class FeatureIntroScreen extends StatefulWidget {
  const FeatureIntroScreen({super.key, required this.onDone});

  /// Called with `true` when the user taps Get started (push signup) and
  /// `false` when they skip or choose to log in.
  final void Function(bool startSignup) onDone;

  static const _seenKey = 'feature_intro_seen_v1';

  /// Whether the tour has already run. Read failures report `true`, so a broken
  /// prefs store can never trap the user behind the tour.
  static Future<bool> hasSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_seenKey) ?? false;
    } catch (_) {
      return true;
    }
  }

  static Future<void> markSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_seenKey, true);
    } catch (_) {
      // Non-fatal: worst case the tour shows once more next launch.
    }
  }

  /// Debug-only: clears the seen flag so QA can replay the tour without a
  /// full uninstall/reinstall. Wired to a Settings row gated on kDebugMode;
  /// never reachable from a release build.
  static Future<void> resetForTesting() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_seenKey);
    } catch (_) {
      // Non-fatal: the debug row can just be tapped again.
    }
  }

  @override
  State<FeatureIntroScreen> createState() => _FeatureIntroScreenState();
}

/// Hero treatment for a page's art. [card] is the default rounded tile;
/// [ring] is the Currents look, a circle inside a gradient ring, matching
/// the rail on the home feed.
enum _Hero { card, ring }

/// One page of the tour. [chips] are the two small floating feature pills.
class _PageData {
  const _PageData({
    required this.icon,
    required this.accent,
    required this.title,
    required this.body,
    required this.chips,
    this.hero = _Hero.card,
  });

  final IconData icon;
  final Color accent;
  final String title;
  final String body;
  final List<(IconData, String)> chips;
  final _Hero hero;
}

class _FeatureIntroScreenState extends State<FeatureIntroScreen>
    with SingleTickerProviderStateMixin {
  // Accents resolve from the active palette, so this can't be a const list.
  static List<_PageData> get _pages => [
    _PageData(
      icon: Icons.sensors,
      accent: NileColors.coral,
      title: 'Live shows, wherever you are',
      body: 'Watch concerts, services, and performances as they happen. '
          'Grab a ticket and you are in the room from anywhere.',
      chips: const [
        (Icons.confirmation_number_outlined, 'Tickets'),
        (Icons.hd_outlined, 'Live in HD'),
      ],
    ),
    _PageData(
      // Matches the Currents rail: bolt in a circle with a volt gradient ring.
      icon: Icons.bolt,
      accent: NileColors.volt,
      hero: _Hero.ring,
      title: 'Quick clips, always on',
      body: 'Swipe through Currents for short videos from the artists and '
          'creators you follow.',
      chips: const [
        (Icons.swipe, 'Swipe to browse'),
        (Icons.bolt, 'Under a minute'),
      ],
    ),
    _PageData(
      icon: Icons.groups_outlined,
      accent: NileColors.azure,
      title: 'Find your people',
      body: 'Follow the creators you love, message the crew, and see what is '
          'happening next in your scene.',
      chips: const [
        (Icons.person_add_alt, 'Follow'),
        (Icons.chat_bubble_outline, 'Message'),
      ],
    ),
    _PageData(
      // Amber, not volt: Currents now owns volt, and gold suits payouts.
      icon: Icons.payments_outlined,
      accent: NileColors.amber,
      title: 'Go live. Get paid.',
      body: 'Sell tickets, collect tips, and earn from replays. Payouts land '
          'straight in your bank account.',
      chips: const [
        (Icons.favorite_outline, 'Tips'),
        (Icons.replay, 'Replays'),
      ],
    ),
  ];

  final _pageController = PageController();
  int _index = 0;

  // Screen-level entrance, so the first page doesn't pop in flat.
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: NileMotion.base,
  )..forward();

  @override
  void dispose() {
    _pageController.dispose();
    _entrance.dispose();
    super.dispose();
  }

  void _next() => _pageController.nextPage(
    duration: NileMotion.base,
    curve: NileMotion.curve,
  );

  @override
  Widget build(BuildContext context) {
    final pages = _pages;
    final isLast = _index == pages.length - 1;

    return Scaffold(
      backgroundColor: NileColors.bgPage,
      body: NileMaxWidth(
        child: SizedBox(
          width: double.infinity,
          child: SafeArea(
            child: FadeTransition(
              opacity: CurvedAnimation(
                parent: _entrance,
                curve: NileMotion.curve,
              ),
              child: Column(
                children: [
                  _topBar(),
                  Expanded(child: _pager(pages)),
                  _dots(pages.length),
                  const SizedBox(height: NileSpacing.s24),
                  _actions(isLast),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NileSpacing.s24,
        NileSpacing.s8,
        NileSpacing.s8,
        0,
      ),
      child: Row(
        children: [
          NileLogo(size: 'small', height: 28),
          const SizedBox(width: NileSpacing.s8),
          Text(
            'Nile',
            style: GoogleFonts.syne(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: NileColors.volt,
              letterSpacing: -0.5,
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => widget.onDone(false),
            child: Text(
              'Skip',
              style: NileTextStyles.bodyMd().copyWith(
                color: NileColors.txtSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Rebuilds on every scroll frame so each page's entrance is tied to the
  /// swipe: a half-dragged page crossfades with its neighbour instead of
  /// sitting blank until the drag settles.
  Widget _pager(List<_PageData> pages) {
    return AnimatedBuilder(
      animation: _pageController,
      builder: (_, _) {
        final offset =
            _pageController.hasClients &&
                _pageController.position.haveDimensions
            ? (_pageController.page ?? _index.toDouble())
            : _index.toDouble();
        return PageView.builder(
          controller: _pageController,
          itemCount: pages.length,
          onPageChanged: (i) => setState(() => _index = i),
          itemBuilder: (_, i) => _IntroPage(
            data: pages[i],
            t: (1 - (offset - i).abs()).clamp(0.0, 1.0),
          ),
        );
      },
    );
  }

  Widget _dots(int count) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: NileMotion.fast,
            margin: const EdgeInsets.symmetric(horizontal: NileSpacing.s4),
            width: i == _index ? 24 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: i <= _index ? NileColors.volt : NileColors.bgRaised,
              borderRadius: BorderRadius.circular(NileRadius.pill),
            ),
          ),
      ],
    );
  }

  /// The secondary link keeps its slot on every page so the primary button
  /// never shifts as the label changes.
  Widget _actions(bool isLast) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NileSpacing.s32,
        0,
        NileSpacing.s32,
        NileSpacing.s8,
      ),
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: DecoratedBox(
              decoration: isLast
                  ? NileEffects.voltGlow
                  : const BoxDecoration(),
              child: FilledButton(
                onPressed: isLast ? () => widget.onDone(true) : _next,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    vertical: NileSpacing.s16,
                  ),
                ),
                child: Text(isLast ? 'Get started' : 'Next'),
              ),
            ),
          ),
          SizedBox(
            height: 44,
            child: AnimatedOpacity(
              opacity: isLast ? 1 : 0,
              duration: NileMotion.fast,
              child: IgnorePointer(
                ignoring: !isLast,
                child: Center(
                  child: TextButton(
                    onPressed: () => widget.onDone(false),
                    child: Text(
                      'I already have an account',
                      style: NileTextStyles.bodyMd().copyWith(
                        color: NileColors.volt,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Art + copy for a single page. [t] is 0 when fully off-screen and 1 when
/// settled, driving both the fade and the rise.
class _IntroPage extends StatelessWidget {
  const _IntroPage({required this.data, required this.t});

  final _PageData data;
  final double t;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: NileSpacing.s32),
      child: Column(
        children: [
          const SizedBox(height: NileSpacing.s16),
          _IntroArt(data: data, t: t),
          const SizedBox(height: NileSpacing.s40),
          Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, 20 * (1 - t)),
              child: Column(
                children: [
                  Text(
                    data.title,
                    textAlign: TextAlign.center,
                    style: NileTextStyles.displayMd(),
                  ),
                  const SizedBox(height: NileSpacing.s12),
                  Text(
                    data.body,
                    textAlign: TextAlign.center,
                    style: NileTextStyles.bodyLg().copyWith(
                      color: NileColors.txtSecondary,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Hero composition: an accent glow behind a raised card holding the feature
/// icon, with two feature pills floating at opposite corners.
class _IntroArt extends StatelessWidget {
  const _IntroArt({required this.data, required this.t});

  final _PageData data;
  final double t;

  static const _alignments = [
    Alignment(-0.95, -0.62),
    Alignment(0.95, 0.66),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 248,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  data.accent.withValues(alpha: 0.30 * t),
                  data.accent.withValues(alpha: 0),
                ],
                stops: const [0.15, 1],
              ),
            ),
          ),
          Transform.translate(
            offset: Offset(0, 24 * (1 - t)),
            child: Opacity(opacity: t, child: _hero()),
          ),
          for (var i = 0; i < data.chips.length; i++)
            Align(
              alignment: _alignments[i],
              child: _chip(data.chips[i], i),
            ),
        ],
      ),
    );
  }

  static const double _heroSize = 164;

  Widget _hero() => switch (data.hero) {
    _Hero.card => Container(
      width: _heroSize,
      height: _heroSize,
      decoration: BoxDecoration(
        color: NileColors.bgSurface,
        borderRadius: BorderRadius.circular(NileRadius.xl),
        border: Border.all(color: NileColors.borderStrong),
      ),
      child: Icon(data.icon, size: 76, color: data.accent),
    ),
    // Same three-layer build as CurrentsRail's unwatched slot (gradient ring,
    // page-colored gap, filled circle), scaled up to hero size.
    _Hero.ring => Container(
      width: _heroSize,
      height: _heroSize,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [NileColors.volt, NileColors.azure],
        ),
      ),
      child: Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: NileColors.bgPage,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: NileColors.bgSurface,
          ),
          child: Icon(data.icon, size: 72, color: data.accent),
        ),
      ),
    ),
  };

  /// Chips trail the card in, one after the other.
  Widget _chip((IconData, String) chip, int i) {
    final ct = ((t - 0.35 - i * 0.12) / 0.5).clamp(0.0, 1.0);
    return Opacity(
      opacity: ct,
      child: Transform.translate(
        offset: Offset(0, 16 * (1 - ct)),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: NileSpacing.s12,
            vertical: NileSpacing.s8,
          ),
          decoration: BoxDecoration(
            color: NileColors.bgRaised,
            borderRadius: BorderRadius.circular(NileRadius.pill),
            border: Border.all(color: NileColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(chip.$1, size: 15, color: data.accent),
              const SizedBox(width: NileSpacing.s6),
              Text(chip.$2, style: NileTextStyles.labelMd().copyWith(fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}
