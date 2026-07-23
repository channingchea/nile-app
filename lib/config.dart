/// Central configuration for the Nile app.
/// Replace the Supabase placeholders with your project values from:
///   Supabase Dashboard → Settings → API
///
/// (LiveKit room/token management now runs in the `livekit` Edge Function,
/// reached via supabase.functions.invoke — there is no standalone backend URL.)
library;

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

// ── Sentry (crash / error reporting) ──────────────────────────────────────────
// Injected at build time so the DSN never lives in the repo:
//   flutter run --dart-define=SENTRY_DSN=https://...@oXXXX.ingest.sentry.io/XXXX
// When absent (plain `flutter run`), Sentry is skipped entirely — zero overhead.
const String sentryDsn = String.fromEnvironment('SENTRY_DSN');
