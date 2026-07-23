import 'package:cloudflare_turnstile/cloudflare_turnstile.dart';
import 'package:firebase_app_check/firebase_app_check.dart';

import '../config.dart';

/// Bot-protection helpers used by the auth screens.
///
/// Two independent signals, both invisible to real users:
///  * [captchaToken] — Cloudflare Turnstile, passed as `captchaToken` to
///    Supabase Auth calls (signUp / signInWithPassword / resetPasswordForEmail).
///    Supabase verifies it server-side when captcha protection is enabled.
///  * [attestationToken] — Firebase App Check (App Attest on iOS, Play
///    Integrity on Android), proving the request comes from a genuine build of
///    the app on real hardware. Sent in signup metadata and verified by the
///    `before-user-created` edge function.
///
/// Both return null when unconfigured/unavailable so auth continues to work
/// before the Cloudflare/Firebase console setup is finished.
class HumanCheck {
  HumanCheck._();

  static Future<String?> captchaToken() async {
    if (turnstileSiteKey.isEmpty) return null;
    final turnstile = CloudflareTurnstile.invisible(
      siteKey: turnstileSiteKey,
      baseUrl: turnstileBaseUrl,
    );
    try {
      return await turnstile.getToken();
    } on TurnstileException {
      // Challenge failed — send nothing; Supabase decides whether to reject.
      return null;
    } finally {
      turnstile.dispose();
    }
  }

  static Future<String?> attestationToken() async {
    try {
      return await FirebaseAppCheck.instance.getToken();
    } catch (_) {
      // App Check not activated on this platform / provider not yet
      // registered in the Firebase console. The edge function treats a
      // missing token as allow-with-warning until enforcement is turned on.
      return null;
    }
  }
}
