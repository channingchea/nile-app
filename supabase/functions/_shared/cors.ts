// Shared CORS helper (security hardening fix #4).
//
// Replaces the wildcard "Access-Control-Allow-Origin: *" previously baked into
// every function. Only origins in the allowlist get their Origin echoed back;
// anything else receives the site origin, which browsers then refuse to share
// cross-origin. Non-browser clients (the Flutter iOS/Android app) send no
// Origin header and ignore CORS entirely, so they are unaffected.
//
// NOTE: if/when the Flutter *web* build goes live, add its origin here.

const ALLOWED_ORIGINS = new Set([
  "https://ads.joinnile.com",
  "https://links.joinnile.com",
]);

export function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("Origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ALLOWED_ORIGINS.has(origin)
      ? origin
      : "https://joinnile.com",
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Vary": "Origin",
  };
}
