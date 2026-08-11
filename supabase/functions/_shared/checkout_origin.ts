// Which surface a Stripe Checkout session was started from, recorded in the
// session's metadata as `origin` (macOS Phase 9).
//
// The Mac app is a direct download with no storefront behind it, so macOS sales
// show up in no App Store or Play report — Stripe metadata is the only place
// they can be told apart from phone sales.
//
// NOT the HTTP Origin header — that is `_shared/cors.ts`. This is a claim in
// the request body, so it is validated against the list rather than echoed: a
// tampered client gets `unknown`, never arbitrary metadata. Keep in step with
// lib/services/checkout_origin.dart.

const ALLOWED = new Set(["ios", "android", "macos", "web"]);

export function checkoutOrigin(raw: unknown, fallback = "unknown"): string {
  return typeof raw === "string" && ALLOWED.has(raw) ? raw : fallback;
}
