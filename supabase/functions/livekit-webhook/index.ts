// Supabase Edge Function: livekit-webhook
//
// Receives LiveKit Cloud webhooks. Today it handles one event: egress_ended,
// which is how a replay recording (started in the `livekit` fn's start-show)
// becomes playable. LiveKit egress is async — the MP4 isn't finalized when the
// show ends — so this webhook is the moment we flip the replay row to
// 'ready' (with playback path + duration) or 'failed'.
//
// LiveKit signs each webhook with the API key/secret (NOT a Supabase JWT), so
// deploy WITHOUT JWT verification and validate the signature ourselves:
//   supabase functions deploy livekit-webhook --no-verify-jwt
//
// Secrets reused from the `livekit` fn: LIVEKIT_API_KEY, LIVEKIT_API_SECRET.
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-injected.
//
// Idempotency: LiveKit retries on any non-2xx, so this handler must tolerate
// re-delivery. The replay-row update is naturally idempotent (same egress_id →
// same end state), and notify_replay_ready is guarded by a partial unique index
// (migration 0023) so a redelivery can't duplicate notifications.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { WebhookReceiver } from "https://esm.sh/livekit-server-sdk@2.9.7?target=deno";

const receiver = new WebhookReceiver(
  Deno.env.get("LIVEKIT_API_KEY")!,
  Deno.env.get("LIVEKIT_API_SECRET")!,
);

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

function log(level: "info" | "warn" | "error", fields: Record<string, unknown>) {
  console.log(JSON.stringify({ level, fn: "livekit-webhook", ...fields }));
}

serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  let event;
  try {
    // receive() verifies the Authorization signature against the raw body.
    const body = await req.text();
    event = await receiver.receive(body, req.headers.get("Authorization") ?? undefined);
  } catch (err) {
    log("warn", { error: "signature verification failed", detail: String(err) });
    return new Response("invalid signature", { status: 401 });
  }

  if (event.event === "egress_ended" && event.egressInfo) {
    const e = event.egressInfo;
    const egressId = e.egressId;
    const ok = e.status === 3; // EGRESS_COMPLETE; 4/5 = failed/aborted
    // file result carries the finalized location + duration (nanoseconds → ms).
    const file = e.fileResults?.[0];
    const durationMs = file?.duration ? Number(file.duration) / 1_000_000 : null;

    const { data: updated, error } = await admin
      .from("replays")
      .update({
        status: ok ? "ready" : "failed",
        duration_ms: ok ? durationMs : null,
      })
      .eq("egress_id", egressId)
      .select("event_id")
      .maybeSingle();

    if (error) {
      log("error", { egressId, error: error.message });
      return new Response("db error", { status: 500 });
    }

    // Fan out replay_ready notifications (followers + paid-ticket holders), gated
    // server-side by each recipient's preference and deduped by the partial
    // unique index. Non-fatal — a failed fanout must not make LiveKit retry the
    // whole webhook (which would otherwise re-run the update needlessly).
    if (ok && updated?.event_id) {
      const { error: rpcErr } = await admin.rpc("notify_replay_ready", {
        p_event_id: updated.event_id,
      });
      if (rpcErr) log("warn", { egressId, fanout_error: rpcErr.message });
    }

    log("info", { event: "egress_ended", egressId, status: ok ? "ready" : "failed" });
  }

  return new Response("ok", { status: 200 });
});
