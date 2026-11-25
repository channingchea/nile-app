// Supabase Edge Function: apple-iap (docs/plans/apple-iap-tickets.md, Phase 2)
//
// Deploy: npx -y supabase@latest functions deploy apple-iap --no-verify-jwt --project-ref jelmkkvyrliywcdkzhuu
// (JWT is checked by hand on /verify; /notifications is called by Apple.)
//
// POST /apple-iap/verify          Bearer = buyer's JWT
//   { "signed_transaction": "<JWS from StoreKit>" }
//   → { "status": "paid" | "already" | "duplicate", "ticket_id": "uuid" }
//   The app finishes the StoreKit transaction only after one of those.
//
// POST /apple-iap/notifications   App Store Server Notifications v2
//   (set as both the Production and Sandbox URL in App Store Connect)
//   ONE_TIME_CHARGE  → backup grant, in case the app never called /verify
//   REFUND           → ticket refunded, viewer removed from a running show
//   REFUND_REVERSED  → ticket restored

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders as corsHeadersFor } from "../_shared/cors.ts";
import { failure } from "../_shared/errors.ts";
import { ejectFromLiveRoom } from "../_shared/livekit_eject.ts";
import {
  AppleIapError, type AppleTransaction, BUNDLE_ID, checkTransaction, verifyAppleJws,
} from "../_shared/apple_iap.ts";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const log = (note: string, extra: Record<string, unknown> = {}) =>
  console.log(JSON.stringify({ fn: "apple-iap", note, ...extra }));

/** Settle a checked transaction. Returns the RPC's outcome. */
async function settle(tx: AppleTransaction): Promise<string> {
  const { ticketId, storeCents, environment } = checkTransaction(tx);
  const { data, error } = await admin.rpc("settle_apple_ticket", {
    p_ticket_id: ticketId,
    p_transaction_id: tx.transactionId,
    p_original_transaction_id: tx.originalTransactionId ?? tx.transactionId,
    p_store_price_cents: storeCents,
    p_environment: environment,
  });
  if (error) throw new Error(`settle_apple_ticket: ${error.message}`);
  if (data === "duplicate") {
    // Apple charged a buyer who already held this ticket. They can ask Apple
    // for the money back from My Tickets; logged so support can see it.
    log("duplicate purchase", { ticket: ticketId, transaction: tx.transactionId });
  }
  return data as string;
}

async function verify(req: Request, json: (b: unknown, s?: number) => Response) {
  const auth = req.headers.get("Authorization");
  if (!auth) return json({ error: "Missing Authorization header" }, 401);
  const userClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: auth } } },
  );
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "Unauthorized" }, 401);

  const { signed_transaction } = await req.json().catch(() => ({}));
  const tx = await verifyAppleJws<AppleTransaction>(signed_transaction);
  const { ticketId } = checkTransaction(tx);

  const { data: ticket } = await admin
    .from("tickets").select("id, buyer_id").eq("id", ticketId).maybeSingle();
  if (!ticket) return json({ error: "not_found" }, 404);
  // The ticket id rides inside Apple's signed payload, so only the account that
  // started the purchase can claim it.
  if (ticket.buyer_id !== user.id) return json({ error: "Forbidden" }, 403);

  const status = await settle(tx);
  if (status === "not_found") return json({ error: "not_found" }, 404);
  return json({ status, ticket_id: ticketId });
}

async function notifications(req: Request) {
  const { signedPayload } = await req.json().catch(() => ({}));
  const n = await verifyAppleJws<{
    notificationType: string;
    subtype?: string;
    notificationUUID?: string;
    data?: { bundleId?: string; environment?: string; signedTransactionInfo?: string };
  }>(signedPayload);
  const ok = () => new Response("ok");

  if (n.data?.bundleId !== BUNDLE_ID || !n.data?.signedTransactionInfo) {
    log("ignored", { type: n.notificationType, bundle: n.data?.bundleId });
    return ok();
  }
  const tx = await verifyAppleJws<AppleTransaction>(n.data.signedTransactionInfo);
  log("received", { type: n.notificationType, subtype: n.subtype, transaction: tx.transactionId, env: tx.environment });

  switch (n.notificationType) {
    case "ONE_TIME_CHARGE": {
      try {
        await settle(tx);
      } catch (e) {
        // Not one of our show products, or no ticket id: nothing to grant.
        if (e instanceof AppleIapError) log("charge not settled", { reason: e.message });
        else throw e;
      }
      break;
    }
    case "REFUND": {
      const { data: ticketId, error } = await admin.rpc("refund_apple_ticket", {
        p_transaction_id: tx.transactionId,
      });
      if (error) throw new Error(`refund_apple_ticket: ${error.message}`);
      if (ticketId) {
        const { data: t } = await admin
          .from("tickets")
          .select("buyer_id, events!tickets_event_id_fkey(status, livekit_room)")
          .eq("id", ticketId)
          .maybeSingle();
        const ev = t?.events as { status?: string; livekit_room?: string | null } | null;
        if (t?.buyer_id && (ev?.status === "live" || ev?.status === "soundcheck")) {
          await ejectFromLiveRoom(ev.livekit_room ?? null, t.buyer_id as string, "apple-iap");
        }
      }
      break;
    }
    case "REFUND_REVERSED": {
      const { error } = await admin
        .from("tickets")
        .update({ status: "paid", refunded_at: null })
        .eq("apple_transaction_id", tx.transactionId)
        .eq("status", "refunded");
      if (error) throw new Error(`refund reversal: ${error.message}`);
      break;
    }
  }
  return ok();
}

serve(async (req) => {
  const corsHeaders = corsHeadersFor(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const route = new URL(req.url).pathname.split("/").pop();
  try {
    if (route === "verify") return await verify(req, json);
    if (route === "notifications") return await notifications(req);
    return json({ error: "Not found" }, 404);
  } catch (err) {
    if (err instanceof AppleIapError) {
      log("rejected", { route, reason: err.message });
      return json({ error: err.message }, 400);
    }
    // 500 → the app retries later, and Apple retries the notification.
    console.error(err);
    return json(failure(err, "apple-iap"), 500);
  }
});
