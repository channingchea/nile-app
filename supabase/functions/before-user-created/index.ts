// Supabase Auth Hook: before-user-created
//
// Device-attestation gate on signup. The app sends a Firebase App Check
// token (App Attest on iOS, Play Integrity on Android) in signup metadata;
// this hook verifies it against Firebase's public JWKS before the user row
// is created. A bot calling the auth API directly can't produce one.
//
// Modes (APP_CHECK_ENFORCE secret):
//   "false" / unset → monitor: missing/invalid tokens are logged but allowed.
//   "true"          → enforce: signups without a valid token are rejected.
//
// Setup (Dashboard → Auth → Hooks → "Before User Created" → HTTPS):
//   URL:    https://<ref>.supabase.co/functions/v1/before-user-created
//   Copy the generated hook secret, then:
//     supabase secrets set BEFORE_USER_CREATED_HOOK_SECRET="v1,whsec_..."
//     supabase secrets set APP_CHECK_ENFORCE="false"   (flip later)
//
// Deploy: supabase functions deploy before-user-created --no-verify-jwt
//   (Auth calls this hook with a webhook signature, not a user JWT.)

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { Webhook } from "https://esm.sh/standardwebhooks@1.0.0";
import * as jose from "https://esm.sh/jose@5.9.6";

const FIREBASE_PROJECT_NUMBER =
  Deno.env.get("FIREBASE_PROJECT_NUMBER") ?? "907048556625";
const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID") ?? "nile-35c48";
const ENFORCE = (Deno.env.get("APP_CHECK_ENFORCE") ?? "false") === "true";

// Firebase App Check public keys (cached by jose between invocations).
const JWKS = jose.createRemoteJWKSet(
  new URL("https://firebaseappcheck.googleapis.com/v1/jwks"),
);

serve(async (req) => {
  // ── 1. Verify this request really came from Supabase Auth ────────────────
  const hookSecret = Deno.env.get("BEFORE_USER_CREATED_HOOK_SECRET");
  if (!hookSecret) return reject(500, "Hook secret not configured");

  const payloadText = await req.text();
  let payload: Record<string, unknown>;
  try {
    const wh = new Webhook(hookSecret.replace("v1,whsec_", ""));
    payload = wh.verify(payloadText, {
      "webhook-id": req.headers.get("webhook-id") ?? "",
      "webhook-timestamp": req.headers.get("webhook-timestamp") ?? "",
      "webhook-signature": req.headers.get("webhook-signature") ?? "",
    }) as Record<string, unknown>;
  } catch {
    return reject(401, "Invalid webhook signature");
  }

  // ── 2. Pull the App Check token out of signup metadata ───────────────────
  const user = (payload.user ?? payload.record ?? {}) as Record<string, unknown>;
  const meta = (user.user_metadata ?? user.raw_user_meta_data ?? {}) as Record<
    string,
    unknown
  >;
  const token = typeof meta.app_check_token === "string"
    ? meta.app_check_token
    : null;

  if (!token) {
    console.warn(`Signup without App Check token (email: ${user.email ?? "?"})`);
    return ENFORCE
      ? reject(403, "Could not verify your device. Please sign up from the Nile app.")
      : allow();
  }

  // ── 3. Verify the token against Firebase ─────────────────────────────────
  try {
    const { payload: claims } = await jose.jwtVerify(token, JWKS, {
      issuer: `https://firebaseappcheck.googleapis.com/${FIREBASE_PROJECT_NUMBER}`,
    });
    const audOk = (claims.aud as string[] | string | undefined ?? [])
      .toString()
      .includes(`projects/${FIREBASE_PROJECT_NUMBER}`) ||
      (claims.aud ?? "").toString().includes(`projects/${FIREBASE_PROJECT_ID}`);
    if (!audOk) throw new Error("audience mismatch");
    return allow();
  } catch (e) {
    console.warn(`App Check verification failed: ${e?.message ?? e}`);
    return ENFORCE
      ? reject(403, "Could not verify your device. Please update the Nile app and try again.")
      : allow();
  }
});

function allow() {
  return new Response("{}", {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

function reject(code: number, message: string) {
  return new Response(
    JSON.stringify({ error: { http_code: code, message } }),
    { status: code, headers: { "Content-Type": "application/json" } },
  );
}
