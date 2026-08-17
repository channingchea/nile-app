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

// P3 #30 — age gate. Same two-stage rollout as APP_CHECK_ENFORCE, and for the
// same reason: builds already on people's phones send no birthdate, so
// enforcing on day one would break signup for everyone who hasn't updated.
//   "false" / unset → monitor: log the missing/underage birthdate, allow.
//   "true"          → enforce: reject the signup.
// Flip with `supabase secrets set AGE_GATE_ENFORCE=true` once the build
// carrying the signup date-of-birth field is the minimum supported version.
const AGE_ENFORCE = (Deno.env.get("AGE_GATE_ENFORCE") ?? "false") === "true";
const MIN_AGE = 13;

/// True when `birthdate` (YYYY-MM-DD) is at least MIN_AGE years ago. Anything
/// unparseable is not old enough — this is a gate, so it fails closed.
function isOldEnough(birthdate: string | null): boolean {
  if (!birthdate) return false;
  const dob = new Date(`${birthdate}T00:00:00Z`);
  if (Number.isNaN(dob.getTime())) return false;
  const cutoff = new Date();
  cutoff.setUTCFullYear(cutoff.getUTCFullYear() - MIN_AGE);
  return dob.getTime() <= cutoff.getTime();
}

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

  // OAuth signups (Google / Apple via signInWithIdToken) carry no App Check
  // token — the native flow can't attach one — and both providers run their
  // own fraud screening. Exempt them from attestation.
  const appMeta = (user.app_metadata ?? user.raw_app_meta_data ?? {}) as Record<
    string,
    unknown
  >;
  const provider = typeof appMeta.provider === "string"
    ? appMeta.provider
    : "email";
  if (provider === "google" || provider === "apple") {
    return allow();
  }

  const meta = (user.user_metadata ?? user.raw_user_meta_data ?? {}) as Record<
    string,
    unknown
  >;
  // ── 2a. Age gate ─────────────────────────────────────────────────────────
  // OAuth signups returned above: their providers hand us no birthdate, and
  // the in-app compliance gate collects one before they can reach anything.
  const birthdate = typeof meta.birthdate === "string" ? meta.birthdate : null;
  if (!isOldEnough(birthdate)) {
    console.warn(
      `Signup ${birthdate ? "under age" : "without a birthdate"} (email: ${
        user.email ?? "?"
      })`,
    );
    if (AGE_ENFORCE) {
      return reject(
        403,
        `You must be at least ${MIN_AGE} years old to use Nile.`,
      );
    }
  }

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
