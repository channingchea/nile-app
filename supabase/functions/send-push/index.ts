// Supabase Edge Function: send-push
//
// Invoked by the trg_on_notification_push trigger (phase20_push_notifications.sql)
// once per notification row. Resolves the recipient's device tokens and sends a
// push via FCM HTTP v1. Dead tokens (UNREGISTERED / INVALID_ARGUMENT) are pruned.
//
// Setup:
//   supabase functions deploy send-push --no-verify-jwt
//   (JWT verification OFF — managed Postgres can't pass a service-role JWT from the
//    trigger, and the new sb_secret_ keys aren't JWTs. Instead the trigger sends a
//    shared secret in the x-push-secret header, which this function verifies below.)
//
// Secrets (supabase secrets set ...):
//   SUPABASE_URL                  — auto-injected
//   SUPABASE_SERVICE_ROLE_KEY     — auto-injected
//   PUSH_SHARED_SECRET            — must match the push_shared_secret Vault entry
//   FCM_PROJECT_ID                — Firebase project id
//   FCM_CLIENT_EMAIL              — service-account client_email
//   FCM_PRIVATE_KEY               — service-account private_key (PEM, with \n)

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface Payload {
  notification_id: string;
  recipient_id: string;
  actor_id: string;
  actor_username: string;
  actor_avatar: string | null;
  type: string;
  entity_id: string | null;
}

// ── Notification copy ─────────────────────────────────────────────────────────

function buildMessage(p: Payload): { title: string; body: string } {
  const who = p.actor_username;
  switch (p.type) {
    case "post_like":
      return { title: "New like", body: `${who} liked your post` };
    case "post_comment":
      return { title: "New comment", body: `${who} commented on your post` };
    case "follow":
      return { title: "New follower", body: `${who} started following you` };
    case "event_starting":
      return { title: "Starting soon", body: `${who}'s event starts in 15 minutes` };
    case "event_live":
      return { title: "Live now", body: `${who} is live` };
    case "event_ended":
      return { title: "Event ended", body: `${who}'s event has ended` };
    case "operator_assigned":
      return { title: "You're on the crew", body: `${who} added you as a camera operator` };
    case "new_message":
      return { title: who, body: "Sent you a message" };
    case "message_reaction":
      return { title: who, body: "Reacted to your message" };
    default:
      return { title: "Nile", body: "You have a new notification" };
  }
}

// ── FCM OAuth2 (service-account JWT → access token) ───────────────────────────

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const bin = atob(b64);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

function b64url(data: string | Uint8Array): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

let cachedToken: { value: string; exp: number } | null = null;

async function getAccessToken(): Promise<string> {
  // Reuse the token until ~1 min before expiry.
  if (cachedToken && cachedToken.exp - 60 > Date.now() / 1000) {
    return cachedToken.value;
  }

  const clientEmail = Deno.env.get("FCM_CLIENT_EMAIL")!;
  const privateKey = Deno.env.get("FCM_PRIVATE_KEY")!.replace(/\\n/g, "\n");

  const now = Math.floor(Date.now() / 1000);
  const claim = {
    iss: clientEmail,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };
  const header = { alg: "RS256", typ: "JWT" };
  const unsigned = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claim))}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(privateKey),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  const jwt = `${unsigned}.${b64url(new Uint8Array(sig))}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  if (!res.ok) throw new Error(`token exchange failed: ${await res.text()}`);
  const json = await res.json();
  cachedToken = { value: json.access_token, exp: now + json.expires_in };
  return cachedToken.value;
}

// ── FCM send ──────────────────────────────────────────────────────────────────

// Returns "ok" | "stale" | "error" so the caller can prune dead tokens.
async function sendToToken(
  projectId: string,
  accessToken: string,
  token: string,
  msg: { title: string; body: string },
  data: Record<string, string>,
): Promise<"ok" | "stale" | "error"> {
  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token,
          notification: { title: msg.title, body: msg.body },
          data,
          android: { priority: "high" },
          apns: {
            payload: { aps: { sound: "default", badge: 1 } },
          },
        },
      }),
    },
  );

  if (res.ok) return "ok";
  // 404 UNREGISTERED or 400 INVALID_ARGUMENT → token is dead, prune it.
  if (res.status === 404 || res.status === 400) return "stale";
  return "error";
}

// ── Handler ───────────────────────────────────────────────────────────────────

serve(async (req) => {
  try {
    // Auth: the trigger proves it's us via a shared secret (the gateway no longer
    // checks a JWT since we deploy --no-verify-jwt).
    const expected = Deno.env.get("PUSH_SHARED_SECRET");
    if (!expected || req.headers.get("x-push-secret") !== expected) {
      return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 });
    }

    const p = (await req.json()) as Payload;

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: tokens, error } = await admin
      .from("device_tokens")
      .select("token")
      .eq("user_id", p.recipient_id);
    if (error) throw error;
    if (!tokens || tokens.length === 0) {
      return new Response(JSON.stringify({ sent: 0 }), { status: 200 });
    }

    const projectId = Deno.env.get("FCM_PROJECT_ID")!;
    const accessToken = await getAccessToken();
    const msg = buildMessage(p);
    const data: Record<string, string> = {
      type: p.type,
      entity_id: p.entity_id ?? "",
      actor_id: p.actor_id,
      notification_id: p.notification_id,
    };

    const stale: string[] = [];
    let sent = 0;
    await Promise.all(
      tokens.map(async (row) => {
        const result = await sendToToken(
          projectId,
          accessToken,
          row.token,
          msg,
          data,
        );
        if (result === "ok") sent++;
        else if (result === "stale") stale.push(row.token);
      }),
    );

    if (stale.length > 0) {
      await admin.from("device_tokens").delete().in("token", stale);
    }

    return new Response(JSON.stringify({ sent, pruned: stale.length }), {
      status: 200,
    });
  } catch (e) {
    console.error("send-push error:", e);
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});
