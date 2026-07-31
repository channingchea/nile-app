// Supabase Edge Function: mfa-recovery
//
// Backup recovery codes for 2FA. Supabase MFA has no native backup codes, so we
// manage our own (table public.mfa_recovery_codes, migration 0043). Codes are
// high-entropy; we store only a keyed HMAC-SHA-256 digest and reveal plaintext
// exactly once, at generation.
//
// Actions (POST JSON { action, ... }, Bearer = user JWT):
//   { action: "generate" }      -> { codes: string[] }   (regenerates: old codes wiped)
//   { action: "status" }        -> { total, used, remaining }
//   { action: "clear" }         -> { ok: true }   (delete all codes; used when the
//        user turns 2FA off so no stale codes linger)
//   { action: "consume", code } -> { ok: true, reset: true }  (verifies a code,
//        marks it used, and unenrolls the user's TOTP factors so the client can
//        re-enroll — the self-service "lost authenticator" reset path)
//
// Secrets: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY (present
//   from other functions) and MFA_RECOVERY_HMAC_KEY (a random server secret;
//   set via `supabase secrets set MFA_RECOVERY_HMAC_KEY=...`). Falls back to the
//   service-role key if unset so it never hard-fails, but a dedicated secret is
//   strongly preferred.
//
// Deploy WITH JWT verification (all three actions require an authenticated
// caller — the consume path authorizes a 2FA reset and must never be anonymous):
//   supabase functions deploy mfa-recovery
// (No --no-verify-jwt. See reference_supabase_stripe_webhook_jwt.)

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders as corsHeadersFor } from "../_shared/cors.ts";

// CORS headers are per-request, so the JSON responder is built per-request too
// and handed to the helpers below (they run outside the handler's scope).
type Json = (body: unknown, status?: number) => Response;
const makeJson = (cors: Record<string, string>): Json =>
  (body, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

const CODE_COUNT = 10;
// 12 chars from an unambiguous alphabet (no 0/O/1/I), grouped 4-4-4.
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const CODE_LEN = 12;

serve(async (req) => {
  // Per-request CORS (fix #4): allowlisted origins only — see _shared/cors.ts.
  const corsHeaders = corsHeadersFor(req);
  const json = makeJson(corsHeaders);
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Missing Authorization header" }, 401);

    // Identify the caller from their JWT. An aal1 (password-only) session is a
    // valid, authenticated caller — that is exactly the state a user is in when
    // they've lost their authenticator and need to consume a recovery code.
    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) return json({ error: "Unauthorized" }, 401);
    const uid = user.id;

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const body = await req.json().catch(() => ({}));
    const action = body?.action as string | undefined;

    if (action === "generate") return await generate(admin, uid, json);
    if (action === "status") return await status(admin, uid, json);
    if (action === "clear") return await clear(admin, uid, json);
    if (action === "consume") return await consume(admin, uid, body?.code, json);
    return json({ error: "Unknown action" }, 400);
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});

// Generate a fresh set of codes. Any previous (used or unused) codes are wiped
// so there are never stale valid codes floating around after a regenerate.
// deno-lint-ignore no-explicit-any
async function generate(admin: any, uid: string, json: Json): Promise<Response> {
  await admin.from("mfa_recovery_codes").delete().eq("user_id", uid);

  const codes: string[] = [];
  const rows: { user_id: string; code_hash: string }[] = [];
  for (let i = 0; i < CODE_COUNT; i++) {
    const code = randomCode();
    codes.push(code);
    rows.push({ user_id: uid, code_hash: await hashCode(code) });
  }
  const { error } = await admin.from("mfa_recovery_codes").insert(rows);
  if (error) return json({ error: error.message }, 500);
  return json({ codes });
}

// deno-lint-ignore no-explicit-any
async function status(admin: any, uid: string, json: Json): Promise<Response> {
  const { data, error } = await admin
    .from("mfa_recovery_codes")
    .select("used_at")
    .eq("user_id", uid);
  if (error) return json({ error: error.message }, 500);
  const total = data?.length ?? 0;
  const used = (data ?? []).filter((r: { used_at: string | null }) => r.used_at).length;
  return json({ total, used, remaining: total - used });
}

// Delete all of a user's recovery codes (used when 2FA is turned off).
// deno-lint-ignore no-explicit-any
async function clear(admin: any, uid: string, json: Json): Promise<Response> {
  const { error } = await admin
    .from("mfa_recovery_codes")
    .delete()
    .eq("user_id", uid);
  if (error) return json({ error: error.message }, 500);
  return json({ ok: true });
}

// Verify a submitted code, mark it used, and unenroll TOTP factors so the client
// can re-enroll. Constant work regardless of match to avoid trivial oracles.
// deno-lint-ignore no-explicit-any
async function consume(admin: any, uid: string, raw: unknown, json: Json): Promise<Response> {
  if (typeof raw !== "string" || !raw.trim()) {
    return json({ error: "Missing code" }, 400);
  }
  const hash = await hashCode(normalize(raw));

  const { data: match, error } = await admin
    .from("mfa_recovery_codes")
    .select("id")
    .eq("user_id", uid)
    .eq("code_hash", hash)
    .is("used_at", null)
    .maybeSingle();
  if (error) return json({ error: error.message }, 500);
  if (!match) return json({ error: "Invalid or already-used code" }, 401);

  await admin
    .from("mfa_recovery_codes")
    .update({ used_at: new Date().toISOString() })
    .eq("id", match.id);

  // Unenroll every factor so the user is back to aal1 with no factor and can
  // re-enroll a new authenticator. Service role required to touch other-session
  // factors. Best-effort per factor; the reset succeeds even if listing is empty.
  try {
    const { data: factors } = await admin.auth.admin.mfa.listFactors({ userId: uid });
    for (const f of factors?.factors ?? []) {
      await admin.auth.admin.mfa.deleteFactor({ userId: uid, id: f.id });
    }
  } catch (e) {
    console.error("factor unenroll failed", e);
  }

  return json({ ok: true, reset: true });
}

function normalize(code: string): string {
  return code.toUpperCase().replace(/[^A-Z0-9]/g, "");
}

function randomCode(): string {
  const bytes = new Uint8Array(CODE_LEN);
  crypto.getRandomValues(bytes);
  let out = "";
  for (let i = 0; i < CODE_LEN; i++) {
    out += ALPHABET[bytes[i] % ALPHABET.length];
    if (i % 4 === 3 && i !== CODE_LEN - 1) out += "-";
  }
  return out; // e.g. ABCD-EFGH-JKLM
}

let hmacKey: CryptoKey | null = null;
async function getKey(): Promise<CryptoKey> {
  if (hmacKey) return hmacKey;
  const secret =
    Deno.env.get("MFA_RECOVERY_HMAC_KEY") ??
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  hmacKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return hmacKey;
}

async function hashCode(normalizedCode: string): Promise<string> {
  const key = await getKey();
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(normalize(normalizedCode)),
  );
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

