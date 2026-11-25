import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/brand_kit.dart';
import '../services/graphics_service.dart';
import '../services/studio_graphics.dart';
import '../theme.dart';
import 'nile_graphics_layer.dart';

/// Edit the account's brand kit. Null = cancelled; (kit: k) = saved;
/// (kit: null) = removed (graphics back to Nile style). [demo] (Studio
/// Preview) edits locally only: nothing is saved or uploaded.
Future<({BrandKit? kit})?> showBrandKitEditor(
  BuildContext context, {
  BrandKit? initial,
  bool demo = false,
}) => showDialog<({BrandKit? kit})>(
  context: context,
  builder: (_) => Dialog(
    backgroundColor: NileColors.bgSurface,
    insetPadding: const EdgeInsets.all(NileSpacing.s24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760),
      child: _BrandKitEditor(initial: initial, demo: demo),
    ),
  ),
);

/// Quick picks under each colour: Nile volt, white / near-blacks, and a
/// spread of common brand hues.
const _swatches = [
  '#C8FF00',
  '#FFFFFF',
  '#FAFAFA',
  '#18181B',
  '#0A0A0A',
  '#FF4D6D',
  '#FF7A00',
  '#FFB800',
  '#00B4FF',
  '#1D4ED8',
  '#8B5CF6',
  '#22C55E',
];

enum _Slot { accent, panel, text, onAccent }

class _BrandKitEditor extends StatefulWidget {
  const _BrandKitEditor({required this.initial, required this.demo});
  final BrandKit? initial;
  final bool demo;

  @override
  State<_BrandKitEditor> createState() => _BrandKitEditorState();
}

class _BrandKitEditorState extends State<_BrandKitEditor> {
  late final BrandKit _start = widget.initial ?? BrandKit.starter;
  late final Map<_Slot, String> _colors = {
    _Slot.accent: _start.style.accent,
    _Slot.panel: _start.style.panel,
    _Slot.text: _start.style.text,
    // A kit without its own banner text colour uses the text colour.
    _Slot.onAccent: _start.style.onAccent ?? _start.style.text,
  };
  late final Map<_Slot, TextEditingController> _hex = {
    for (final e in _colors.entries) e.key: TextEditingController(text: e.value),
  };
  // An unlisted font (shouldn't happen) would break the dropdown: Nile default.
  late String? _font = brandFonts.contains(_start.style.font)
      ? _start.style.font
      : null;
  late String? _logoPath = _start.logoPath;
  bool _busy = false;
  bool _uploading = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _hex.values) {
      c.dispose();
    }
    super.dispose();
  }

  BrandStyle get _style => BrandStyle(
    accent: _colors[_Slot.accent]!,
    panel: _colors[_Slot.panel]!,
    text: _colors[_Slot.text]!,
    onAccent: _colors[_Slot.onAccent]!,
    font: _font,
  );

  BrandKit get _kit => BrandKit(style: _style, logoPath: _logoPath);

  /// "c8ff00" / "#c8ff00" → "#C8FF00", or null when it isn't a colour.
  static String? _normalise(String raw) {
    final v = raw.trim().startsWith('#') ? raw.trim() : '#${raw.trim()}';
    return isBrandHex(v) ? v.toUpperCase() : null;
  }

  bool get _allValid => _hex.values.every((c) => _normalise(c.text) != null);

  void _typed(_Slot s, String raw) {
    final hex = _normalise(raw);
    setState(() {
      if (hex != null) _colors[s] = hex;
    });
  }

  void _picked(_Slot s, String hex) => setState(() {
    _colors[s] = hex;
    _hex[s]!.text = hex;
  });

  Future<void> _uploadLogo() async {
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final path = await BrandKitService.pickAndUploadLogo();
      if (!mounted) return;
      setState(() {
        if (path != null) _logoPath = path;
        _uploading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _error = 'Couldn’t upload that image. Try another one.';
      });
    }
  }

  Future<void> _save() async {
    if (_busy || !_allValid) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final kit = _kit;
    try {
      if (!widget.demo) await BrandKitService.save(kit);
      if (mounted) Navigator.pop(context, (kit: kit));
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Couldn’t save your brand kit. Try again.';
        });
      }
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NileColors.bgSurface,
        title: Text('Remove your brand kit?', style: NileTextStyles.headingMd()),
        content: Text(
          'Your graphics go back to Nile’s own style, including any on screen '
          'right now.',
          style: NileTextStyles.bodyMd(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Remove', style: TextStyle(color: NileColors.error)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!widget.demo) await BrandKitService.delete();
      if (mounted) Navigator.pop(context, (kit: null));
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Couldn’t remove your brand kit. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = _style;
    final warnings = style.contrastWarnings;
    return ListView(
      padding: const EdgeInsets.all(NileSpacing.s24),
      children: [
        Text('Brand kit', style: NileTextStyles.headingMd()),
        const SizedBox(height: NileSpacing.s4),
        Text(
          'Your colours and font on every graphic, for every viewer.',
          style: NileTextStyles.bodySm(),
        ),
        const SizedBox(height: NileSpacing.s16),
        _preview(style),
        if (warnings.isNotEmpty) ...[
          const SizedBox(height: NileSpacing.s8),
          for (final w in warnings)
            Padding(
              padding: const EdgeInsets.only(top: NileSpacing.s4),
              child: Row(
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: NileColors.warning,
                  ),
                  const SizedBox(width: NileSpacing.s6),
                  Expanded(
                    child: Text(
                      w,
                      style: NileTextStyles.bodySm().copyWith(
                        color: NileColors.warning,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
        const SizedBox(height: NileSpacing.s16),
        _colorRow(_Slot.accent, 'Accent', 'Banner, lower-third stripe, countdown'),
        _colorRow(_Slot.panel, 'Panel', 'Behind lower thirds, cards and slates'),
        _colorRow(_Slot.text, 'Text', 'Words on panels and slates'),
        _colorRow(_Slot.onAccent, 'Banner text', 'Text on the accent colour'),
        _fontRow(),
        const SizedBox(height: NileSpacing.s16),
        _logoRow(),
        if (_error != null) ...[
          const SizedBox(height: NileSpacing.s12),
          Text(
            _error!,
            style: NileTextStyles.bodySm().copyWith(color: NileColors.error),
          ),
        ],
        const SizedBox(height: NileSpacing.s24),
        Row(
          children: [
            if (widget.initial != null)
              TextButton(
                onPressed: _busy ? null : _remove,
                child: Text('Remove kit', style: TextStyle(color: NileColors.error)),
              ),
            const Spacer(),
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: NileSpacing.s8),
            FilledButton(
              onPressed: _busy || _uploading || !_allValid ? null : _save,
              style: FilledButton.styleFrom(
                backgroundColor: NileColors.volt,
                foregroundColor: NileColors.onVolt,
              ),
              child: _busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: NileColors.onVolt,
                      ),
                    )
                  : const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }

  /// A sample lower third and banner (plus the default logo) on a dark
  /// stand-in for video. Always the dark palette — video is dark in both themes.
  Widget _preview(BrandStyle style) {
    final sample = [
      const LiveGraphic(
        id: 'preview:lower-third',
        kind: GraphicKind.lowerThird,
        title: 'Your name',
        subtitle: 'Your title',
      ),
      const LiveGraphic(
        id: 'preview:banner',
        kind: GraphicKind.banner,
        text: 'Thanks for watching — follow for the next show',
      ),
      if (_logoPath != null)
        LiveGraphic(
          id: 'preview:logo',
          kind: GraphicKind.logo,
          imageUrl: GraphicsService.publicUrl(_logoPath!),
          corner: 'tr',
          size: 's',
        ),
    ];
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(NileRadius.md),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [NilePalette.dark.bgRaised, NilePalette.dark.bgPage],
            ),
          ),
          child: NileGraphicsLayer(
            graphics: [for (final g in sample) g.withBrand(style)],
          ),
        ),
      ),
    );
  }

  Widget _colorRow(_Slot s, String label, String hint) {
    final valid = _normalise(_hex[s]!.text) != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: NileSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                margin: const EdgeInsets.only(top: NileSpacing.s4),
                decoration: BoxDecoration(
                  color: colorFromHex(_colors[s]!),
                  borderRadius: BorderRadius.circular(NileRadius.sm),
                  border: Border.all(color: NileColors.borderStrong),
                ),
              ),
              const SizedBox(width: NileSpacing.s12),
              Expanded(
                child: TextField(
                  controller: _hex[s],
                  maxLength: 7,
                  style: NileTextStyles.bodyLg(),
                  decoration: InputDecoration(
                    labelText: label,
                    helperText: hint,
                    counterText: '',
                    errorText: valid ? null : 'Use a hex colour like #C8FF00',
                  ),
                  onChanged: (v) => _typed(s, v),
                ),
              ),
            ],
          ),
          const SizedBox(height: NileSpacing.s8),
          Wrap(
            spacing: NileSpacing.s6,
            runSpacing: NileSpacing.s6,
            children: [
              for (final hex in _swatches)
                _Swatch(
                  color: colorFromHex(hex),
                  selected: _colors[s] == hex,
                  tooltip: hex,
                  onTap: () => _picked(s, hex),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _fontRow() => DropdownButtonFormField<String?>(
    initialValue: _font,
    isExpanded: true,
    dropdownColor: NileColors.bgRaised,
    decoration: const InputDecoration(labelText: 'Font'),
    items: [
      DropdownMenuItem<String?>(
        value: null,
        child: Text('Nile default', style: NileTextStyles.bodyLg()),
      ),
      for (final f in brandFonts)
        DropdownMenuItem<String?>(
          value: f,
          // Only listed fonts reach here, so getFont never sees an unknown name.
          child: Text(
            f,
            style: GoogleFonts.getFont(f, textStyle: NileTextStyles.bodyLg()),
          ),
        ),
    ],
    onChanged: (v) => setState(() => _font = v),
  );

  Widget _logoRow() {
    final path = _logoPath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Default logo', style: NileTextStyles.labelMd()),
        const SizedBox(height: NileSpacing.s4),
        Text(
          'New logo graphics start with this image.',
          style: NileTextStyles.bodySm(),
        ),
        const SizedBox(height: NileSpacing.s8),
        Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: NileColors.bgRaised,
                borderRadius: BorderRadius.circular(NileRadius.sm),
                border: Border.all(color: NileColors.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: path == null
                  ? Icon(Icons.image_outlined, color: NileColors.txtTertiary)
                  : Image.network(
                      GraphicsService.publicUrl(path),
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => Icon(
                        Icons.broken_image_outlined,
                        color: NileColors.txtTertiary,
                      ),
                    ),
            ),
            const SizedBox(width: NileSpacing.s12),
            OutlinedButton.icon(
              onPressed: widget.demo || _busy || _uploading ? null : _uploadLogo,
              icon: _uploading
                  ? const SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_outlined, size: 16),
              label: Text(path == null ? 'Upload' : 'Replace'),
            ),
            if (path != null) ...[
              const SizedBox(width: NileSpacing.s8),
              TextButton(
                onPressed: _busy || _uploading
                    ? null
                    : () => setState(() => _logoPath = null),
                child: const Text('Remove'),
              ),
            ],
          ],
        ),
        if (widget.demo) ...[
          const SizedBox(height: NileSpacing.s8),
          Text(
            'Logo upload isn’t available in Studio Setup — nothing here is saved.',
            style: NileTextStyles.caption(),
          ),
        ],
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.tooltip,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? NileColors.txtPrimary : NileColors.border,
            width: selected ? 2 : 1,
          ),
        ),
      ),
    ),
  );
}
