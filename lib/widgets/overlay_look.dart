import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/brand_kit.dart';
import '../theme.dart';

/// Colours and fonts for anything drawn over the video — a graphic or a live
/// element: its brand style, or Nile's own when it has none (then everything
/// resolves to exactly the Nile tokens).
class OverlayLook {
  const OverlayLook(this.brand);

  final BrandStyle? brand;

  /// Replaces volt: lower-third stripe, banner fill, countdown numbers.
  Color get accent => brand?.accentColor ?? NileColors.volt;

  /// Card backgrounds (lower third, chat card, QR frame, elements).
  Color get panel => brand?.panelColor ?? NileColors.bgSurface;

  /// Full-screen backgrounds (slate, an element shown full screen).
  Color get page => brand?.panelColor ?? NileColors.bgPage;
  Color get text => brand?.textColor ?? NileColors.txtPrimary;
  Color get textDim =>
      brand?.textColor.withValues(alpha: 0.7) ?? NileColors.txtSecondary;

  /// Text on the accent colour (the banner).
  Color get onAccent => brand?.onAccentColor ?? NileColors.onVolt;

  /// [s] in the kit's font, sizes and weights kept. Only fonts on the
  /// [brandFonts] list are fetched; anything else keeps the Nile font.
  TextStyle font(TextStyle s) {
    final f = brand?.font;
    return f == null || !brandFonts.contains(f)
        ? s
        : GoogleFonts.getFont(f, textStyle: s);
  }
}
