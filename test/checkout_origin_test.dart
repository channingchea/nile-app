// Phase 9 — the checkout origin tag.
//
// Every Stripe Checkout session carries the surface it was started from. The
// Mac app is a direct download with no storefront report behind it, so this tag
// is the only way macOS revenue is distinguishable from phone revenue — a
// silent regression to 'unknown' would be invisible until someone tried to read
// the numbers. Hence a test on a two-line getter.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nile_app/services/checkout_origin.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('names each shipping platform', () {
    const expected = {
      TargetPlatform.macOS: 'macos',
      TargetPlatform.iOS: 'ios',
      TargetPlatform.android: 'android',
    };
    expected.forEach((platform, origin) {
      debugDefaultTargetPlatformOverride = platform;
      expect(NileCheckoutOrigin.current, origin, reason: platform.name);
    });
  });

  test('falls back to unknown on a platform we do not ship', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(NileCheckoutOrigin.current, 'unknown');
  });

  test('every value it can return is one the edge functions accept', () {
    // Mirrors the ALLOWED set in supabase/functions/_shared/checkout_origin.ts.
    // A value missing there is recorded as 'unknown', silently losing the tag.
    const allowedServerSide = {'ios', 'android', 'macos', 'web'};
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      final origin = NileCheckoutOrigin.current;
      expect(
        origin == 'unknown' || allowedServerSide.contains(origin),
        isTrue,
        reason: '$platform → "$origin" is not in the server allowlist',
      );
    }
  });
}
