/// Central configuration for the Nile app.
/// Replace the Supabase placeholders with your project values from:
///   Supabase Dashboard → Settings → API
///
/// (LiveKit room/token management now runs in the `livekit` Edge Function,
/// reached via supabase.functions.invoke — there is no standalone backend URL.)
library;

import 'package:flutter/foundation.dart' show kIsWeb;

// ── Auth email redirects ──────────────────────────────────────────────────────
// Where Supabase auth emails (confirm signup, password reset) send the user
// back to. Native uses the `nile://` custom scheme registered in Info.plist /
// AndroidManifest; web uses whatever origin the app is served from. Both values
// must be listed in Supabase Dashboard → Authentication → URL Configuration →
// Redirect URLs — otherwise Supabase silently falls back to the Site URL.
String get emailConfirmRedirect =>
    kIsWeb ? Uri.base.origin : 'nile://login-callback';
String get passwordResetRedirect =>
    kIsWeb ? Uri.base.origin : 'nile://reset-callback';

// ── Supabase ──────────────────────────────────────────────────────────────────
const String supabaseUrl =
    'https://jelmkkvyrliywcdkzhuu.supabase.co'; // https://xxxx.supabase.co
const String supabaseAnonKey =
    'sb_publishable_5CL1YQYinwBJrVM0FPvUsQ_eIAgrsRE'; // safe for client use

// ── Cloudflare Turnstile (bot protection on auth) ─────────────────────────────
// Site key is public (like the Supabase anon key). Create the widget at
// Cloudflare Dashboard → Turnstile, mode "Invisible". The SECRET key goes in
// Supabase Dashboard → Auth → Attack Protection (enable captcha, Turnstile).
// While this is empty, no captcha token is sent — leave Supabase captcha
// protection OFF until this is filled in, or all sign-ins will fail.
const String turnstileSiteKey = '';
// Must match a hostname on the Turnstile widget's domain list.
const String turnstileBaseUrl = 'https://joinnile.com';

// ── Google / Apple sign-in ────────────────────────────────────────────────────
// OAuth client IDs from Google Cloud project nile-35c48 (public identifiers,
// like the Supabase anon key). The web client ID is the ID-token audience for
// BOTH mobile platforms (`serverClientId`); the iOS client ID also appears
// reversed in Info.plist as a URL scheme.
const String googleWebClientId =
    '907048556625-jt3a7h1ddm8gi648eea9j6hddvvimqb6.apps.googleusercontent.com';
const String googleIosClientId =
    '907048556625-1cl82rkemt4g164mtuj6448r3aujnasc.apps.googleusercontent.com';

// ── Legal / compliance ────────────────────────────────────────────────────────
// App Store Guideline 1.2 requires a UGC EULA the user agrees to, reachable
// from inside the app. Nile's Terms of Service is that EULA; these are the
// canonical copies on the marketing site, so an update never needs a build.
const String nileWebsiteUrl = 'https://joinnile.com';
const String termsUrl = '$nileWebsiteUrl/terms';
const String privacyUrl = '$nileWebsiteUrl/privacy';
const String cookiesUrl = '$nileWebsiteUrl/cookies';
const String guidelinesUrl = '$nileWebsiteUrl/guidelines';
const String contactUrl = '$nileWebsiteUrl/contact';
const String appealUrl = '$nileWebsiteUrl/appeal';

/// Stamped into `profiles.terms_version` when a user accepts. Bump this on the
/// same day the published Terms change and every account is asked again.
const String termsVersion = '2026-08-17';

/// Nile's minimum age, matching the published Terms and enforced server-side in
/// `record_compliance_consent` and the `before-user-created` auth hook.
const int minimumAge = 13;

// ── Sentry (crash / error reporting) ──────────────────────────────────────────
// Injected at build time so the DSN never lives in the repo:
//   flutter run --dart-define=SENTRY_DSN=https://...@oXXXX.ingest.sentry.io/XXXX
// When absent (plain `flutter run`), Sentry is skipped entirely — zero overhead.
const String sentryDsn = String.fromEnvironment('SENTRY_DSN');
