import 'package:flutter/foundation.dart';

/// Which surface a Stripe Checkout session was started from.
///
/// Sent with every checkout request and recorded in the session's Stripe
/// metadata as `origin`. The Mac app is a direct download with no storefront
/// behind it, so macOS sales appear in no App Store or Play report — this tag
/// is the only place they can be told apart from phone sales.
///
/// The edge functions validate against the same set rather than echoing what
/// the client sends, so a tampered build writes `unknown`, not arbitrary
/// metadata. Keep this list and `_shared/checkout_origin.ts` in step.
class NileCheckoutOrigin {
  NileCheckoutOrigin._();

  static String get current {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'ios',
      TargetPlatform.android => 'android',
      TargetPlatform.macOS => 'macos',
      _ => 'unknown',
    };
  }
}
