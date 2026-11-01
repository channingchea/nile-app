import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nile_app/services/brand_kit.dart';
import 'package:nile_app/services/studio_graphics.dart';
import 'package:nile_app/widgets/nile_graphics_layer.dart';
import 'package:nile_app/widgets/nile_studio.dart';
import 'package:qr_flutter/qr_flutter.dart';

String url(String p) => 'https://x/studio-graphics/$p';

const kit = BrandStyle(
  accent: '#FF0000',
  panel: '#000000',
  text: '#FFFFFF',
  font: 'Oswald',
);

Widget _frame(Widget child) => MaterialApp(
  home: Center(child: SizedBox(width: 800, height: 450, child: child)),
);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  group('brand kit', () {
    test('BrandStyle reads only valid hex and known fonts', () {
      expect(
        BrandStyle.fromJson({
          'accent': '#ff0000',
          'panel': '#000000',
          'text': '#ffffff',
        })?.accent,
        '#FF0000',
      );
      expect(
        BrandStyle.fromJson({
          'accent': 'red',
          'panel': '#000000',
          'text': '#ffffff',
        }),
        isNull,
      );
      expect(
        BrandStyle.fromJson({
          'accent': '#FF0000',
          'panel': '#000000',
          'text': '#FFFFFF',
          'font': 'Comic Sans',
        })?.font,
        isNull,
      );
    });

    test('contrast warnings are advisory', () {
      const muddy = BrandStyle(
        accent: '#777777',
        panel: '#666666',
        text: '#707070',
      );
      expect(muddy.contrastWarnings, hasLength(2));
      expect(kit.contrastWarnings, isEmpty);
    });

    test('forSlot attaches the kit; Nile-style graphics ignore it', () {
      final s = GraphicsState(
        all: const [
          LiveGraphic(id: 'a', kind: GraphicKind.lowerThird, title: 'A'),
          LiveGraphic(
            id: 'b',
            kind: GraphicKind.banner,
            text: 'B',
            nileStyle: true,
          ),
        ],
        brand: kit,
      );
      final drawn = s.forSlot(null);
      expect(drawn[0].brand, kit);
      expect(drawn[1].brand, isNull);
    });

    test('the kit survives every state change and the wire', () {
      final s = const GraphicsState(brand: kit)
          .withOn(
            null,
            const LiveGraphic(
              id: 'a',
              kind: GraphicKind.lowerThird,
              title: 'A',
            ),
          )
          .withoutEverywhere('zzz')
          .withoutExpired(0);
      expect(s.brand, kit);
      expect(GraphicsState.fromJson(s.toJson()).brand, kit);
      expect(GraphicsState.fromJson(s.toJson()), s);
    });
  });

  group('QR codes', () {
    test('validate: https link for custom, corner required, caption ≤ 40', () {
      expect(
        StudioGraphic.validate(GraphicKind.qr, {
          'source': 'custom',
          'url': 'https://a.co',
          'corner': 'br',
        }),
        isNull,
      );
      expect(
        StudioGraphic.validate(GraphicKind.qr, {
          'source': 'custom',
          'url': 'http://a.co',
          'corner': 'br',
        }),
        isNotNull,
      );
      expect(
        StudioGraphic.validate(GraphicKind.qr, {
          'source': 'event',
          'corner': 'br',
        }),
        isNull,
      );
      expect(
        StudioGraphic.validate(GraphicKind.qr, {'source': 'event'}),
        isNotNull,
      );
      expect(
        StudioGraphic.validate(GraphicKind.qr, {
          'source': 'event',
          'corner': 'br',
          'caption': 'x' * 41,
        }),
        isNotNull,
      );
    });

    test('event/profile links resolve when pushed', () {
      const g = StudioGraphic(
        id: 'q',
        kind: GraphicKind.qr,
        name: 'Show page',
        payload: {'source': 'event', 'corner': 'tr', 'caption': 'Scan'},
      );
      final live = LiveGraphic.snapshot(
        g,
        publicUrl: url,
        now: DateTime(2026),
        resolveLink: (s) =>
            s == 'event' ? 'https://links.joinnile.com/e/1' : null,
      );
      expect(live.url, 'https://links.joinnile.com/e/1');
      expect(live.caption, 'Scan');
      expect(live.tappable, isTrue);
      expect(live.capKey, 'qr:tr');
      expect(LiveGraphic.fromJson(live.toJson()), live);
    });

    test('a QR and a logo can share a corner', () {
      final s = GraphicsState.empty
          .withOn(
            null,
            const LiveGraphic(
              id: 'l',
              kind: GraphicKind.logo,
              imageUrl: 'u',
              corner: 'tr',
            ),
          )
          .withOn(
            null,
            const LiveGraphic(
              id: 'q',
              kind: GraphicKind.qr,
              url: 'https://a.co',
              corner: 'tr',
            ),
          );
      expect(s.all.map((g) => g.id), ['l', 'q']);
    });
  });

  group('sponsor', () {
    test('built in, never saved, shares the logo spot', () {
      final g = StudioGraphic.sponsor(
        campaignId: 'c1',
        sponsorName: 'Acme',
        logoUrl: 'https://x/l.png',
        corner: 'bl',
      );
      expect(g.isBuiltIn, isTrue);
      expect(StudioGraphic.validate(g.kind, g.payload), isNotNull);
      final live = LiveGraphic.snapshot(g, publicUrl: url, now: DateTime(2026));
      expect(live.title, 'Acme');
      expect(live.imageUrl, 'https://x/l.png');
      expect(live.campaignId, 'c1');
      expect(live.capKey, 'logo:bl');
    });
  });

  group('cue before air', () {
    const slate = StudioGraphic(
      id: 'cd',
      kind: GraphicKind.slate,
      name: 'Countdown',
      payload: {
        'title': 'Starting in',
        'countdown': {'mode': 'duration', 'seconds': 60},
        'autoHideSeconds': 30,
      },
    );

    test('countdown and auto-hide start at Apply, not at cue', () {
      final cue = GraphicCue.of(
        slate,
        targets: const GraphicTargets.all(),
        publicUrl: url,
      );
      final takenAt = DateTime(2026, 1, 1, 12, 0, 0);
      final on = cue.take(GraphicsState.empty, takenAt).all.single;
      expect(
        on.endsAt,
        takenAt.add(const Duration(seconds: 60)).millisecondsSinceEpoch,
      );
      expect(
        on.hideAt,
        takenAt.add(const Duration(seconds: 30)).millisecondsSinceEpoch,
      );
    });

    GraphicCue cueOf(StudioGraphic g, GraphicTargets t) =>
        GraphicCue.of(g, targets: t, publicUrl: url);
    const lt = StudioGraphic(
      id: 'lt',
      kind: GraphicKind.lowerThird,
      name: 'Name',
      payload: {'title': 'Jane'},
    );
    const lt2 = StudioGraphic(
      id: 'lt2',
      kind: GraphicKind.lowerThird,
      name: 'Other name',
      payload: {'title': 'Sam'},
    );

    test('several cues wait together and go on air in one Apply', () {
      final cues = CueSet.empty
          .adding(cueOf(slate, const GraphicTargets.all()))
          .adding(cueOf(lt, const GraphicTargets.only({'s1'})));
      expect(cues.length, 2);
      expect(cues.label, '2 graphics');
      expect(cues.lands('s1'), isTrue);
      final on = cues.take(GraphicsState.empty, DateTime(2026));
      expect(on.all.single.id, 'cd');
      expect(on.bySlot['s1']!.single.id, 'lt');
    });

    test('re-cueing replaces; a clash on the same spot drops the older', () {
      var cues = CueSet.empty
          .adding(cueOf(lt, const GraphicTargets.only({'s1'})))
          .adding(cueOf(lt, const GraphicTargets.only({'s2'})));
      expect(cues.items.single.targets, const GraphicTargets.only({'s2'}));
      // Two lower thirds on different cameras can both wait…
      cues = cues.adding(cueOf(lt2, const GraphicTargets.only({'s1'})));
      expect(cues.length, 2);
      // …but one for every camera would cover both.
      cues = cues.adding(cueOf(lt2, const GraphicTargets.all()));
      expect(cues.items.map((c) => c.id), ['lt2']);
    });

    test('a hotkey pressed twice un-cues', () {
      final c = cueOf(lt, const GraphicTargets.all());
      expect(CueSet.empty.toggled(c).toggled(c).isEmpty, isTrue);
    });

    test('the preview stays up and sends nothing by itself', () {
      final cue = GraphicCue.of(
        slate,
        targets: const GraphicTargets.only({'s2'}),
        publicUrl: url,
      );
      final preview = cue.preview(GraphicsState.empty, DateTime(2026));
      expect(preview.bySlot['s2']!.single.hideAt, isNull);
      expect(preview.all, isEmpty);
    });
  });

  group('drawing', () {
    testWidgets('a QR code is tappable only where taps are wanted', (t) async {
      const qr = LiveGraphic(
        id: 'q',
        kind: GraphicKind.qr,
        url: 'https://a.co',
        corner: 'br',
        caption: 'Scan me',
      );
      LiveGraphic? tapped;
      await t.pumpWidget(
        _frame(
          NileGraphicsLayer(graphics: const [qr], onTapLink: (g) => tapped = g),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.text('Scan me'), findsOneWidget);
      await t.tap(find.byType(QrImageView));
      expect(tapped?.id, 'q');

      tapped = null;
      await t.pumpWidget(_frame(const NileGraphicsLayer(graphics: [qr])));
      await t.pumpAndSettle();
      await t.tap(find.byType(QrImageView), warnIfMissed: false);
      expect(tapped, isNull);
    });

    testWidgets('a sponsor without a logo gets a "Sponsored by" badge', (
      t,
    ) async {
      await t.pumpWidget(
        _frame(
          const NileGraphicsLayer(
            graphics: [
              LiveGraphic(
                id: 's',
                kind: GraphicKind.sponsor,
                title: 'Acme',
                corner: 'tr',
              ),
            ],
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Sponsored by'), findsOneWidget);
      expect(find.text('Acme'), findsOneWidget);
    });

    testWidgets('lower thirds and banners draw in the kit', (t) async {
      const style = BrandStyle(
        accent: '#FF0000',
        panel: '#000000',
        text: '#00FF00',
        onAccent: '#0000FF',
      );
      final drawn = GraphicsState(
        all: const [
          LiveGraphic(id: 'lt', kind: GraphicKind.lowerThird, title: 'Jane'),
          LiveGraphic(id: 'b', kind: GraphicKind.banner, text: 'News'),
        ],
        brand: style,
      ).forSlot(null);
      await t.pumpWidget(_frame(NileGraphicsLayer(graphics: drawn)));
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.text('Jane')).style?.color, style.textColor);
      expect(
        t.widget<Text>(find.text('News')).style?.color,
        style.onAccentColor,
      );
    });

    testWidgets('the cue bar names the graphic and takes it', (t) async {
      var took = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NileStudioCueBar(
              name: 'Be right back',
              targets: 'All cameras',
              onTake: () => took++,
              onClear: () {},
            ),
          ),
        ),
      );
      expect(find.text('CUED'), findsOneWidget);
      await t.tap(find.text('Apply (Enter)'));
      expect(took, 1);
    });
  });
}
