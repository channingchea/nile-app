import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:google_fonts/google_fonts.dart';

// ── Breakpoints ───────────────────────────────────────────────────────────────
// Four window classes, pinned to real device widths rather than round numbers:
//
//   compact   < 740, or under 600 tall   phone, iPad Split View, phone landscape
//   medium    740–1023                   iPad mini / 11" portrait — icon rail
//   expanded  1024–1179                  iPad 13" portrait — labelled rail
//   wide      >= 1180                    iPad 11" landscape and up — all three zones
//
// `compact` is the phone layout and is deliberately untouched by the desktop
// work; everything wider gets the three-zone shell (nav rail | content column |
// context rail) assembled in HomeScreen.

enum NileWindowClass { compact, medium, expanded, wide }

class NileBreakpoints {
  NileBreakpoints._();

  /// The desktop shell starts at the narrowest iPad — the mini, 744 pt in
  /// portrait. Anything below is a phone or an iPad Split View pane.
  static const double medium = 740;

  /// Room for the 214 pt labelled rail: the 13" iPad in portrait (1024) and up.
  static const double expanded = 1024;

  /// All three zones. 214 rail + a 640 pt minimum content column + 322 context
  /// rail = 1176, so the 11" iPad in landscape (1194) is the first device that
  /// earns the full layout.
  static const double wide = 1180;

  /// A phone in landscape is wider than an iPad is tall, but only ~430 pt high.
  /// Height is what separates "small screen turned sideways" from "tablet" —
  /// without it, rotating an iPhone would swap in a nav rail that eats most of
  /// the vertical room there is.
  static const double minHeightForRail = 600;

  static NileWindowClass classify(Size size) {
    if (size.height < minHeightForRail) return NileWindowClass.compact;
    final width = size.width;
    return width >= wide
        ? NileWindowClass.wide
        : width >= expanded
        ? NileWindowClass.expanded
        : width >= medium
        ? NileWindowClass.medium
        : NileWindowClass.compact;
  }

  static NileWindowClass of(BuildContext context) =>
      classify(MediaQuery.sizeOf(context));
}

extension NileWindowClassX on NileWindowClass {
  /// Phone layout: glass bottom nav, 600 px column, no rails.
  bool get isCompact => this == NileWindowClass.compact;

  /// A nav rail replaces the glass bottom nav from `medium` up.
  bool get hasNavRail => this != NileWindowClass.compact;

  /// Labels appear once there's room for the full 214 px rail; on an iPad in
  /// portrait the rail is icon-only.
  bool get navRailLabelled => index >= NileWindowClass.expanded.index;

  /// The context rail is the last zone in and the first out — it needs 322 px
  /// of its own on top of the rail and a readable content column.
  bool get hasContextRail => index >= NileWindowClass.wide.index;
}

/// Centers [child] in a readable content column — 600 px on phones, up to
/// [desktop] once the desktop shell is in play. Narrower windows are
/// unaffected.
///
/// Grids, players and full-bleed media pass an explicit [maxWidth] (or skip
/// this widget entirely) so they can break out wider.
class NileMaxWidth extends StatelessWidget {
  const NileMaxWidth({super.key, required this.child, this.maxWidth});

  final Widget child;

  /// Overrides the breakpoint-derived column width.
  /// Pass [double.infinity] to bypass the constraint entirely.
  final double? maxWidth;

  /// Phone content column.
  static const double compact = 600;

  /// Desktop content column ceiling.
  ///
  /// The wireframes drew 760 at a 1280 reference width. Both rails are pinned
  /// to the window edges, so on a wider display something has to absorb the
  /// surplus: the column grows to this ceiling first, and the context rail
  /// takes whatever is left over. Capping at 760 instead left 216 pt of dead
  /// gutter either side of the feed on a 1728 pt MacBook.
  ///
  /// Lower this to 760 to go back to the wireframe measure — the shell reads it
  /// straight from here, so nothing else has to change.
  static const double desktop = 900;

  static double columnFor(BuildContext context) =>
      NileBreakpoints.of(context).isCompact ? compact : desktop;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth ?? columnFor(context)),
      child: child,
    ),
  );
}

// ── Image memory ──────────────────────────────────────────────────────────────
// Network images are decoded at (roughly) their displayed size instead of the
// source resolution — a 4000 px upload shown as a thumbnail would otherwise
// decode to a multi-megabyte bitmap and stay cached as long as the screen is on
// the navigation stack. Sizes assume a 3x device pixel ratio (our densest
// targets), so quality is unaffected.

/// Decode width in physical pixels for an image displayed [logicalWidth]
/// logical pixels wide. Full-width images are capped at 600 by [NileMaxWidth],
/// so pass 600 for those. Use as `Image.network(..., cacheWidth: ...)`.
int nileDecodeWidth(double logicalWidth) => (logicalWidth * 3).round();

/// Downsampled [NetworkImage] for a [CircleAvatar] of the given [radius].
/// Use for `backgroundImage:` slots, which take an ImageProvider and so can't
/// use Image.network's cacheWidth.
ImageProvider nileAvatarImage(String url, double radius) =>
    ResizeImage(NetworkImage(url), width: nileDecodeWidth(radius * 2));

// ── Spacing ───────────────────────────────────────────────────────────────────
// 4/8-pt grid. Use these for ALL padding, margins, and gaps — never raw numbers.
// s2/s6 are micro sizes reserved for badges and chips.

class NileSpacing {
  NileSpacing._();

  static const double s2 = 2;
  static const double s4 = 4;
  static const double s6 = 6;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16; // standard horizontal page padding
  static const double s24 = 24;
  static const double s32 = 32;
  static const double s40 = 40;
  static const double s48 = 48;

  /// Standard page content padding.
  static const EdgeInsets page = EdgeInsets.symmetric(horizontal: s16);
}

// ── Colors ────────────────────────────────────────────────────────────────────

/// The theme-varying color tokens, one instance per theme. Values mirror
/// Nile_Design_System/tokens/colors.css exactly. Registered as a
/// [ThemeExtension] on both ThemeDatas, so `context.nile.<token>` resolves
/// per active theme; [NileColors] getters delegate to the current instance.
@immutable
class NilePalette extends ThemeExtension<NilePalette> {
  const NilePalette({
    required this.bgPage,
    required this.bgSurface,
    required this.bgRaised,
    required this.txtPrimary,
    required this.txtSecondary,
    required this.txtTertiary,
    required this.border,
    required this.borderStrong,
    required this.volt,
  });

  final Color bgPage; // scaffold / page bg
  final Color bgSurface; // cards, app bars
  final Color bgRaised; // elevated, hover fills
  final Color txtPrimary;
  final Color txtSecondary;
  final Color txtTertiary;
  final Color border; // hairline "lit edge"
  final Color borderStrong;
  final Color volt; // primary CTA — volt-dark in light for legibility

  static const NilePalette dark = NilePalette(
    bgPage: Color(0xFF0A0A0A),
    bgSurface: Color(0xFF18181B),
    bgRaised: Color(0xFF27272A),
    txtPrimary: Color(0xFFFAFAFA),
    txtSecondary: Color(0xFFA1A1AA),
    txtTertiary: Color(0xFF71717A),
    border: Color(0x1AFFFFFF), // white 10%
    borderStrong: Color(0x33FFFFFF), // white 20%
    volt: Color(0xFFC8FF00),
  );

  static const NilePalette light = NilePalette(
    bgPage: Color(0xFFF4F4F5),
    bgSurface: Color(0xFFFFFFFF),
    bgRaised: Color(0xFFFAFAFA),
    txtPrimary: Color(0xFF0A0A0A),
    txtSecondary: Color(0xFF52525B),
    txtTertiary: Color(0xFFA1A1AA),
    border: Color(0x140A0A0A), // black 8%
    borderStrong: Color(0x290A0A0A), // black 16%
    volt: Color(0xFFA0CC00), // volt-dark
  );

  static NilePalette of(Brightness b) =>
      b == Brightness.dark ? dark : light;

  @override
  ThemeExtension<NilePalette> copyWith() => this;

  @override
  ThemeExtension<NilePalette> lerp(
    covariant ThemeExtension<NilePalette>? other,
    double t,
  ) => t < 0.5 ? this : (other ?? this);
}

/// Preferred accessor for new code: `context.nile.bgSurface` — registers a
/// Theme dependency so the widget rebuilds automatically on theme change.
extension NileContext on BuildContext {
  NilePalette get nile => Theme.of(this).extension<NilePalette>()!;
}

class NileColors {
  NileColors._();

  /// Backing palette for the theme-varying tokens below. Set by ThemeService
  /// whenever the effective brightness changes (it then rebuilds the tree,
  /// so every build re-reads the new values). Do not set directly.
  static NilePalette palette = NilePalette.dark;

  // Theme-varying — resolve from the active palette.
  static Color get bgPage => palette.bgPage;
  static Color get bgSurface => palette.bgSurface;
  static Color get bgRaised => palette.bgRaised;
  static Color get txtPrimary => palette.txtPrimary;
  static Color get txtSecondary => palette.txtSecondary;
  static Color get txtTertiary => palette.txtTertiary;
  static Color get border => palette.border;
  static Color get borderStrong => palette.borderStrong;
  static Color get volt => palette.volt;

  // Fixed across themes (per design system).
  /// Text/icon color on a volt background — black in BOTH themes.
  static const Color onVolt = Color(0xFF0A0A0A);
  static const Color coral = Color(
    0xFFFF4D6D,
  ); // LIVE badge, Go Live, urgent/destructive
  static const Color azure = Color(0xFF00B4FF); // info, links, featured
  static const Color violet = Color(0xFF8B5CF6); // creator / premium
  static const Color amber = Color(0xFFFFB800); // rewards / gold

  // Semantic
  static const Color success = Color(0xFF22C55E);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);
}

// ── Border radii ──────────────────────────────────────────────────────────────

class NileRadius {
  NileRadius._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 20;
  static const double xl = 28;
  static const double pill = 999;
}

// ── Motion ────────────────────────────────────────────────────────────────────
// Two durations, one curve. State changes (hover, toggle, color) use [fast];
// anything that moves or enters/exits (transitions, fades, slides) uses [base].

class NileMotion {
  NileMotion._();

  static const Duration fast = Duration(milliseconds: 150);
  static const Duration base = Duration(milliseconds: 300);
  static const Curve curve = Curves.easeOutCubic;
}

// ── Depth helpers ─────────────────────────────────────────────────────────────

class NileEffects {
  NileEffects._();

  /// Faint volt glow. Reserve for the single primary CTA on a screen.
  /// Wrap the button: DecoratedBox(decoration: NileEffects.voltGlow, child: …)
  /// Getter (not final) so it re-resolves volt per active theme.
  static BoxDecoration get voltGlow => BoxDecoration(
    borderRadius: BorderRadius.circular(NileRadius.pill),
    boxShadow: [
      BoxShadow(
        color: NileColors.volt.withValues(alpha: 0.25),
        blurRadius: 24,
        spreadRadius: -2,
      ),
    ],
  );

  /// Bottom scrim for text legibility over cover images.
  /// Place in a Stack on top of the image, behind the text.
  static const BoxDecoration coverScrim = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      stops: [0.4, 1.0],
      colors: [Colors.transparent, Color(0x99000000)],
    ),
  );
}

// ── Text styles ───────────────────────────────────────────────────────────────

class NileTextStyles {
  NileTextStyles._();

  // Display / Headings — Syne
  static TextStyle displayLg([NilePalette? p]) => GoogleFonts.syne(
    fontSize: 48,
    fontWeight: FontWeight.w800,
    color: (p ?? NileColors.palette).txtPrimary,
    letterSpacing: -1,
  );

  static TextStyle displayMd([NilePalette? p]) => GoogleFonts.syne(
    fontSize: 32,
    fontWeight: FontWeight.w700,
    color: (p ?? NileColors.palette).txtPrimary,
    letterSpacing: -0.5,
  );

  static TextStyle headingLg([NilePalette? p]) => GoogleFonts.syne(
    fontSize: 24,
    fontWeight: FontWeight.w700,
    color: (p ?? NileColors.palette).txtPrimary,
  );

  static TextStyle headingMd([NilePalette? p]) => GoogleFonts.syne(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    color: (p ?? NileColors.palette).txtPrimary,
  );

  static TextStyle headingSm([NilePalette? p]) => GoogleFonts.syne(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: (p ?? NileColors.palette).txtPrimary,
  );

  // Body / UI labels — Outfit
  static TextStyle bodyLg([NilePalette? p]) => GoogleFonts.outfit(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    color: (p ?? NileColors.palette).txtPrimary,
  );

  static TextStyle bodyMd([NilePalette? p]) => GoogleFonts.outfit(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: (p ?? NileColors.palette).txtPrimary,
  );

  static TextStyle bodySm([NilePalette? p]) => GoogleFonts.outfit(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    color: (p ?? NileColors.palette).txtSecondary,
  );

  static TextStyle labelLg([NilePalette? p]) => GoogleFonts.outfit(
    fontSize: 18,
    fontWeight: FontWeight.w500,
    color: (p ?? NileColors.palette).txtPrimary,
  );

  static TextStyle labelMd([NilePalette? p]) => GoogleFonts.outfit(
    fontSize: 16,
    fontWeight: FontWeight.w500,
    color: (p ?? NileColors.palette).txtPrimary,
  );

  static TextStyle labelSm([NilePalette? p]) => GoogleFonts.outfit(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    color: (p ?? NileColors.palette).txtSecondary,
    letterSpacing: 1.2,
  );

  static TextStyle caption([NilePalette? p]) => GoogleFonts.outfit(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    color: (p ?? NileColors.palette).txtTertiary,
    letterSpacing: 0.5,
  );
}

/// Tabular figures for live-updating numbers (counts, timers, prices) —
/// every digit gets the same width, so values don't jiggle as they change.
extension NileNumericText on TextStyle {
  TextStyle get tabular =>
      copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
}

// ── ThemeData ─────────────────────────────────────────────────────────────────

ThemeData nileTheme(Brightness brightness) {
  final p = NilePalette.of(brightness);
  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: p.volt,
    onPrimary: NileColors.onVolt, // black text on volt bg (both themes)
    secondary: NileColors.coral,
    onSecondary: Colors.white,
    error: NileColors.error,
    onError: Colors.white,
    surface: p.bgSurface,
    onSurface: p.txtPrimary,
    surfaceContainerHighest: p.bgRaised,
    outline: p.border,
    outlineVariant: p.borderStrong,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: p.bgPage,
    extensions: [p], // enables context.nile.<token>

    // Fade-through page transitions (calmer than the default slide)
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      },
    ),

    // App bar
    appBarTheme: AppBarTheme(
      backgroundColor: p.bgPage,
      foregroundColor: p.txtPrimary,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: NileTextStyles.headingMd(p),
      // Status/nav bar icons flip with the theme.
      systemOverlayStyle: brightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
    ),

    // Text
    textTheme: TextTheme(
      displayLarge: NileTextStyles.displayLg(p),
      displayMedium: NileTextStyles.displayMd(p),
      headlineLarge: NileTextStyles.headingLg(p),
      headlineMedium: NileTextStyles.headingMd(p),
      headlineSmall: NileTextStyles.headingSm(p),
      bodyLarge: NileTextStyles.bodyLg(p),
      bodyMedium: NileTextStyles.bodyMd(p),
      bodySmall: NileTextStyles.bodySm(p),
      labelLarge: NileTextStyles.labelLg(p),
      labelMedium: NileTextStyles.labelMd(p),
      labelSmall: NileTextStyles.labelSm(p),
    ),

    // Filled button — volt bg, dark text
    // textStyle must NOT include a color — foregroundColor controls it.
    // Any explicit color in textStyle would override foregroundColor.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.volt,
        foregroundColor: NileColors.onVolt,
        textStyle: NileTextStyles.labelLg(p).copyWith(color: null),
        shape: const StadiumBorder(),
      ),
    ),

    // Outlined button
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.txtPrimary,
        side: BorderSide(color: p.borderStrong),
        textStyle: NileTextStyles.labelLg(p),
        shape: const StadiumBorder(),
      ),
    ),

    // Elevated button
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: p.bgRaised,
        foregroundColor: p.txtPrimary,
        textStyle: NileTextStyles.labelMd(p),
        shape: const StadiumBorder(),
      ),
    ),

    // Cards — lg radius, hairline border, no shadow (depth via border + surface)
    cardTheme: CardThemeData(
      color: p.bgSurface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NileRadius.lg),
        side: BorderSide(color: p.border),
      ),
    ),

    // Text button
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.txtSecondary,
        textStyle: NileTextStyles.bodyMd(p),
      ),
    ),

    // Text fields
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.bgSurface,
      labelStyle: GoogleFonts.outfit(
        color: p.txtSecondary,
        fontSize: 14,
      ),
      hintStyle: GoogleFonts.outfit(
        color: p.txtTertiary,
        fontSize: 14,
      ),
      border: OutlineInputBorder(
        borderSide: BorderSide(color: p.border),
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: p.border),
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: p.volt, width: 1.5),
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
      errorBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: NileColors.error),
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
    ),

    // Dividers
    dividerTheme: DividerThemeData(
      color: p.border,
      thickness: 1,
    ),

    // Snack bar
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.bgRaised,
      contentTextStyle: NileTextStyles.bodyMd(p),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
      behavior: SnackBarBehavior.floating,
    ),

    // Icon
    iconTheme: IconThemeData(color: p.txtSecondary),

    // Time picker
    timePickerTheme: TimePickerThemeData(
      backgroundColor: p.bgSurface,
      // Hour/minute input boxes
      hourMinuteColor: WidgetStateColor.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? p.volt
            : p.bgRaised,
      ),
      hourMinuteTextColor: WidgetStateColor.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? NileColors.onVolt
            : p.txtPrimary,
      ),
      hourMinuteTextStyle: GoogleFonts.outfit(
        fontSize: 48,
        fontWeight: FontWeight.w700,
        height: 1.0,
      ),
      hourMinuteShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
      // AM / PM toggle
      dayPeriodColor: WidgetStateColor.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? p.volt.withValues(alpha: 0.15)
            : Colors.transparent,
      ),
      dayPeriodTextColor: WidgetStateColor.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? p.volt
            : p.txtSecondary,
      ),
      dayPeriodTextStyle: GoogleFonts.outfit(
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      dayPeriodShape: RoundedRectangleBorder(
        side: BorderSide(color: p.border),
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
      // Dial
      dialBackgroundColor: p.bgRaised,
      dialHandColor: p.volt,
      dialTextColor: WidgetStateColor.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? NileColors.onVolt
            : p.txtPrimary,
      ),
      dialTextStyle: GoogleFonts.outfit(
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
      // Misc
      entryModeIconColor: p.txtSecondary,
      helpTextStyle: GoogleFonts.outfit(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: p.txtSecondary,
        letterSpacing: 0.8,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NileRadius.lg),
      ),
    ),
  );
}
