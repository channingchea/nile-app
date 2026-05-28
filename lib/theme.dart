import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Constrains [child] to 600 px and centers it horizontally.
/// On screens narrower than 600 px the constraint has no effect.
class NileMaxWidth extends StatelessWidget {
  const NileMaxWidth({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: child,
        ),
      );
}

// ── Colors ────────────────────────────────────────────────────────────────────

class NileColors {
  NileColors._();

  // Surfaces (dark mode)
  static const Color bgPage    = Color(0xFF0A0A0A); // scaffold / page bg
  static const Color bgSurface = Color(0xFF18181B); // cards, app bars
  static const Color bgRaised  = Color(0xFF27272A); // elevated, hover fills

  // Text
  static const Color txtPrimary   = Color(0xFFFAFAFA);
  static const Color txtSecondary = Color(0xFFA1A1AA);
  static const Color txtTertiary  = Color(0xFF71717A);

  // Borders
  static const Color border       = Color(0xFF3F3F46);
  static const Color borderStrong = Color(0xFF52525B);

  // Accent / vibrant
  static const Color volt   = Color(0xFFC8FF00); // primary CTA — text on volt = bgPage
  static const Color coral  = Color(0xFFFF4D6D); // LIVE badge, Go Live, urgent/destructive
  static const Color azure  = Color(0xFF00B4FF); // info, links, featured
  static const Color violet = Color(0xFF8B5CF6); // creator / premium
  static const Color amber  = Color(0xFFFFB800); // rewards / gold

  // Semantic
  static const Color success = Color(0xFF22C55E);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error   = Color(0xFFEF4444);
}

// ── Border radii ──────────────────────────────────────────────────────────────

class NileRadius {
  NileRadius._();

  static const double xs   = 4;
  static const double sm   = 8;
  static const double md   = 12;
  static const double lg   = 20;
  static const double xl   = 28;
  static const double pill = 999;
}

// ── Text styles ───────────────────────────────────────────────────────────────

class NileTextStyles {
  NileTextStyles._();

  // Display / Headings — Syne
  static TextStyle displayLg() => GoogleFonts.syne(
        fontSize: 48,
        fontWeight: FontWeight.w800,
        color: NileColors.txtPrimary,
        letterSpacing: -1,
      );

  static TextStyle displayMd() => GoogleFonts.syne(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        color: NileColors.txtPrimary,
        letterSpacing: -0.5,
      );

  static TextStyle headingLg() => GoogleFonts.syne(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        color: NileColors.txtPrimary,
      );

  static TextStyle headingMd() => GoogleFonts.syne(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: NileColors.txtPrimary,
      );

  static TextStyle headingSm() => GoogleFonts.syne(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: NileColors.txtPrimary,
      );

  // Body / UI labels — Outfit
  static TextStyle bodyLg() => GoogleFonts.outfit(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: NileColors.txtPrimary,
      );

  static TextStyle bodyMd() => GoogleFonts.outfit(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: NileColors.txtPrimary,
      );

  static TextStyle bodySm() => GoogleFonts.outfit(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: NileColors.txtSecondary,
      );

  static TextStyle labelLg() => GoogleFonts.outfit(
        fontSize: 18,
        fontWeight: FontWeight.w500,
        color: NileColors.txtPrimary,
      );

  static TextStyle labelMd() => GoogleFonts.outfit(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: NileColors.txtPrimary,
      );

  static TextStyle labelSm() => GoogleFonts.outfit(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: NileColors.txtSecondary,
        letterSpacing: 1.2,
      );

  static TextStyle caption() => GoogleFonts.outfit(
        fontSize: 11,
        fontWeight: FontWeight.w400,
        color: NileColors.txtTertiary,
        letterSpacing: 0.5,
      );
}

// ── ThemeData ─────────────────────────────────────────────────────────────────

ThemeData nileTheme() {
  const colorScheme = ColorScheme(
    brightness: Brightness.dark,
    primary:        NileColors.volt,
    onPrimary:      NileColors.bgPage,   // black text on volt bg
    secondary:      NileColors.coral,
    onSecondary:    Colors.white,
    error:          NileColors.error,
    onError:        Colors.white,
    surface:        NileColors.bgSurface,
    onSurface:      NileColors.txtPrimary,
    surfaceContainerHighest: NileColors.bgRaised,
    outline:        NileColors.border,
    outlineVariant: NileColors.borderStrong,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: NileColors.bgPage,

    // App bar
    appBarTheme: AppBarTheme(
      backgroundColor: NileColors.bgPage,
      foregroundColor: NileColors.txtPrimary,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: NileTextStyles.headingMd(),
    ),

    // Text
    textTheme: TextTheme(
      displayLarge:  NileTextStyles.displayLg(),
      displayMedium: NileTextStyles.displayMd(),
      headlineLarge: NileTextStyles.headingLg(),
      headlineMedium: NileTextStyles.headingMd(),
      headlineSmall: NileTextStyles.headingSm(),
      bodyLarge:     NileTextStyles.bodyLg(),
      bodyMedium:    NileTextStyles.bodyMd(),
      bodySmall:     NileTextStyles.bodySm(),
      labelLarge:    NileTextStyles.labelLg(),
      labelMedium:   NileTextStyles.labelMd(),
      labelSmall:    NileTextStyles.labelSm(),
    ),

    // Filled button — volt bg, dark text
    // textStyle must NOT include a color — foregroundColor controls it.
    // Any explicit color in textStyle would override foregroundColor.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: NileColors.volt,
        foregroundColor: NileColors.bgPage,
        textStyle: NileTextStyles.labelLg().copyWith(color: null),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NileRadius.sm),
        ),
      ),
    ),

    // Outlined button
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: NileColors.txtPrimary,
        side: const BorderSide(color: NileColors.border),
        textStyle: NileTextStyles.labelLg(),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NileRadius.sm),
        ),
      ),
    ),

    // Elevated button
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: NileColors.bgRaised,
        foregroundColor: NileColors.txtPrimary,
        textStyle: NileTextStyles.labelMd(),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NileRadius.sm),
        ),
      ),
    ),

    // Text button
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: NileColors.txtSecondary,
        textStyle: NileTextStyles.bodyMd(),
      ),
    ),

    // Text fields
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: NileColors.bgSurface,
      labelStyle: GoogleFonts.outfit(color: NileColors.txtSecondary, fontSize: 14),
      hintStyle: GoogleFonts.outfit(color: NileColors.txtTertiary, fontSize: 14),
      border: OutlineInputBorder(
        borderSide: const BorderSide(color: NileColors.border),
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
      enabledBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: NileColors.border),
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: NileColors.volt, width: 1.5),
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
      errorBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: NileColors.error),
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
    ),

    // Dividers
    dividerTheme: const DividerThemeData(
      color: NileColors.border,
      thickness: 1,
    ),

    // Snack bar
    snackBarTheme: SnackBarThemeData(
      backgroundColor: NileColors.bgRaised,
      contentTextStyle: NileTextStyles.bodyMd(),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
      behavior: SnackBarBehavior.floating,
    ),

    // Icon
    iconTheme: const IconThemeData(color: NileColors.txtSecondary),

    // Time picker
    timePickerTheme: TimePickerThemeData(
      backgroundColor: NileColors.bgSurface,
      // Hour/minute input boxes
      hourMinuteColor: WidgetStateColor.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? NileColors.volt
              : NileColors.bgRaised),
      hourMinuteTextColor: WidgetStateColor.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? NileColors.bgPage
              : NileColors.txtPrimary),
      hourMinuteTextStyle: GoogleFonts.outfit(
        fontSize: 48,
        fontWeight: FontWeight.w700,
        height: 1.0,
      ),
      hourMinuteShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
      // AM / PM toggle
      dayPeriodColor: WidgetStateColor.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? NileColors.volt.withOpacity(0.15)
              : Colors.transparent),
      dayPeriodTextColor: WidgetStateColor.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? NileColors.volt
              : NileColors.txtSecondary),
      dayPeriodTextStyle: GoogleFonts.outfit(
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      dayPeriodShape: RoundedRectangleBorder(
        side: const BorderSide(color: NileColors.border),
        borderRadius: BorderRadius.circular(NileRadius.sm),
      ),
      // Dial
      dialBackgroundColor: NileColors.bgRaised,
      dialHandColor: NileColors.volt,
      dialTextColor: WidgetStateColor.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? NileColors.bgPage
              : NileColors.txtPrimary),
      dialTextStyle: GoogleFonts.outfit(fontSize: 13, fontWeight: FontWeight.w500),
      // Misc
      entryModeIconColor: NileColors.txtSecondary,
      helpTextStyle: GoogleFonts.outfit(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: NileColors.txtSecondary,
        letterSpacing: 0.8,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NileRadius.lg),
      ),
    ),
  );
}
