import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'graphics_service.dart';
import 'supabase_client.dart';

/// The fonts a brand kit can use — Google Fonts every viewer's app can fetch.
/// Mirrors BRAND_FONTS in supabase/functions/_shared/graphics.ts and the
/// `brand_kits.font` check (migration 0135).
const brandFonts = [
  'Inter',
  'Montserrat',
  'Poppins',
  'Oswald',
  'Bebas Neue',
  'Playfair Display',
  'Merriweather',
  'Space Grotesk',
  'DM Serif Display',
  'Archivo Black',
  'Roboto Slab',
  'Caveat',
];

final _hex = RegExp(r'^#[0-9A-Fa-f]{6}$');

bool isBrandHex(Object? s) => s is String && _hex.hasMatch(s);

Color colorFromHex(String hex) =>
    Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));

String hexFromColor(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// WCAG contrast ratio between two colours (1–21).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// How graphics look on air when a brand kit is in use. Travels in room
/// metadata as `graphics.brand`; viewers draw with it. Null font = Nile's
/// own fonts.
@immutable
class BrandStyle {
  const BrandStyle({
    required this.accent,
    required this.panel,
    required this.text,
    this.onAccent,
    this.font,
  });

  /// `#RRGGBB` each. [onAccent] is text on the accent (the banner); null =
  /// [text].
  final String accent;
  final String panel;
  final String text;
  final String? onAccent;
  final String? font;

  Color get accentColor => colorFromHex(accent);
  Color get panelColor => colorFromHex(panel);
  Color get textColor => colorFromHex(text);
  Color get onAccentColor => colorFromHex(onAccent ?? text);

  /// Readability notes for the editor — warn only, never enforced.
  List<String> get contrastWarnings => [
    if (contrastRatio(textColor, panelColor) < 4.5)
      'Text may be hard to read on the panel colour.',
    if (contrastRatio(onAccentColor, accentColor) < 3)
      'Banner text may be hard to read on the accent colour.',
  ];

  static BrandStyle? fromJson(Object? j) {
    if (j is! Map) return null;
    final a = j['accent'], p = j['panel'], t = j['text'], f = j['font'];
    final o = j['onAccent'];
    if (!isBrandHex(a) || !isBrandHex(p) || !isBrandHex(t)) return null;
    return BrandStyle(
      accent: (a as String).toUpperCase(),
      panel: (p as String).toUpperCase(),
      text: (t as String).toUpperCase(),
      onAccent: isBrandHex(o) ? (o as String).toUpperCase() : null,
      font: f is String && brandFonts.contains(f) ? f : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'accent': accent,
    'panel': panel,
    'text': text,
    'onAccent': ?onAccent,
    'font': ?font,
  };

  @override
  bool operator ==(Object other) =>
      other is BrandStyle &&
      other.accent == accent &&
      other.panel == panel &&
      other.text == text &&
      other.onAccent == onAccent &&
      other.font == font;

  @override
  int get hashCode => Object.hash(accent, panel, text, onAccent, font);
}

/// The account's brand kit (`brand_kits`, owner-only): the on-air style plus
/// a default logo new logo graphics start from.
@immutable
class BrandKit {
  const BrandKit({required this.style, this.logoPath});

  /// What a new kit starts as — Nile's own look, so nothing changes until the
  /// host edits it.
  static const starter = BrandKit(
    style: BrandStyle(
      accent: '#C8FF00',
      panel: '#18181B',
      text: '#FAFAFA',
      onAccent: '#0A0A0A',
    ),
  );

  final BrandStyle style;
  final String? logoPath;

  factory BrandKit.fromRow(Map<String, dynamic> r) => BrandKit(
    style:
        BrandStyle.fromJson({
          'accent': r['accent'],
          'panel': r['panel'],
          'text': r['text_color'],
          'onAccent': r['accent_text'],
          'font': r['font'],
        }) ??
        starter.style,
    logoPath: r['logo_path'] as String?,
  );

  BrandKit copyWith({BrandStyle? style, String? logoPath, bool clearLogo = false}) =>
      BrandKit(
        style: style ?? this.style,
        logoPath: clearLogo ? null : logoPath ?? this.logoPath,
      );
}

class BrandKitService {
  static const _table = 'brand_kits';

  /// The caller's kit, or null when they have never saved one (graphics then
  /// draw in Nile style).
  static Future<BrandKit?> load() async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return null;
    final row = await supabase
        .from(_table)
        .select('accent, panel, text_color, accent_text, font, logo_path')
        .eq('owner_id', uid)
        .maybeSingle();
    return row == null ? null : BrandKit.fromRow(row);
  }

  static Future<void> save(BrandKit kit) async {
    await supabase.from(_table).upsert({
      'owner_id': supabase.auth.currentUser!.id,
      'accent': kit.style.accent,
      'panel': kit.style.panel,
      'text_color': kit.style.text,
      'accent_text': kit.style.onAccent,
      'font': kit.style.font,
      'logo_path': kit.logoPath,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Turn the brand kit off: graphics go back to Nile style.
  static Future<void> delete() async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return;
    await supabase.from(_table).delete().eq('owner_id', uid);
  }

  /// Same bucket, folder and limits as library images.
  static Future<String?> pickAndUploadLogo() => GraphicsService.pickAndUploadImage();
}
