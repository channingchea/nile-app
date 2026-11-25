import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nile_app/services/iap_service.dart';
import 'package:nile_app/services/pricing_service.dart';
import 'package:nile_app/widgets/payout_preview_card.dart';

/// docs/plans/apple-iap-tickets.md, Phase 1. The table is the one migration
/// 0157's `compute_iap_price_cents` returned on the database (2026-11-24), so
/// the app and the server quote the same iPhone price.
void main() {
  const c = PricingConfig.fallback;

  test('iPhone price matches compute_iap_price_cents', () {
    const table = <int, int?>{
      1: 199,
      100: 199,
      300: 499,
      500: 799,
      699: 999,
      700: 1099,
      1000: 1499,
      1050: 1599,
      2500: 3599,
      6990: 9999,
      6999: 9999,
      7000: null,
      10000: null,
    };
    for (final e in table.entries) {
      expect(c.iapPriceCentsFor(e.key), e.value, reason: '${e.key}¢ on web');
    }
    expect(c.iapPriceCentsFor(null), isNull);
    expect(c.iapPriceCentsFor(0), isNull);
  });

  test('product ids follow the App Store ladder', () {
    expect(PricingConfig.iapProductId(199), 'com.nilestreaming.app.ppv.0199');
    expect(PricingConfig.iapProductId(1499), 'com.nilestreaming.app.ppv.1499');
    expect(PricingConfig.iapProductId(9999), 'com.nilestreaming.app.ppv.9999');
  });

  test('in-app prices only on iPhone/iPad', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(IapService.enabled, isTrue);
    expect(IapService.displayCents(1000), 1499);
    expect(IapService.displayCents(8000), 8000); // above the ladder → web price
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(IapService.enabled, isFalse);
    expect(IapService.displayCents(1000), 1000);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(IapService.storeCentsFor(1000), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('host preview shows both prices in neutral words', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PayoutPreviewCard(
            priceCents: 1000,
            minCents: 300,
            cameraCount: 1,
            config: PricingConfig.fallback,
          ),
        ),
      ),
    );
    expect(find.text('Card checkout'), findsOneWidget);
    expect(find.text('\$10.00'), findsOneWidget);
    expect(find.text('App store purchases'), findsOneWidget);
    expect(find.text('\$14.99'), findsOneWidget);
    expect(find.text('The same on every device.'), findsOneWidget);
    expect(find.textContaining('Apple'), findsNothing);
    expect(find.textContaining('Android'), findsNothing);
  });
}
