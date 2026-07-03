// Supabase Edge Function: review-ad-campaign
//
// Admin actions on ad campaigns (A-4 Part 3). Caller must be in the `admins`
// table (migration 0032). Standalone checkout authorizes only (manual capture,
// see create-ad-payment), so money moves HERE, on approval — and never moves at
// all for rejects.
//
//   { campaign_id, action: "approve" | "reject" | "pause" | "resume" | "withdraw",
//     note? }   — note: optional rejection reason (reject only, shown to advertiser)
//
//   approve  pending_review → active. Captures the PaymentIntent, then resets
//            starts_at/ends_at to NOW + the originally purchased duration —
//            the flight clock starts at activation, not checkout, so the brand
//            gets the full window they paid for.
//   reject   pending_review → rejected. Cancels the uncaptured authorization
//            (refunds instead if a legacy pre-manual-capture payment was
//            already captured). No out-of-band refund runbook needed.
//   withdraw OWNER action (not admin-gated): the advertiser hard-deletes their
//            own pending_review or rejected campaign. pending_review → cancel
//            the authorization first (same Stripe logic as reject); rejected →
//            hold already released. Then delete the campaign row (creative/
//            targeting/events cascade) and best-effort remove the creative
//            image from the ad-creatives bucket.
//   pause    active → paused.   (no Stripe involvement; flight dates unchanged)
//   resume   paused → active.
//
// Deploy: supabase functions deploy review-ad-campaign   (KEEP JWT on)

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14?target=deno";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
  httpClient: Stripe.createFetchHttpClient(),
});

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// action → { from: required current status, to: next status }
const TRANSITIONS: Record<string, { from: string; to: string }> = {
  approve: { from: "pending_review", to: "active" },
  reject:  { from: "pending_review", to: "rejected" },
  pause:   { from: "active",         to: "paused" },
  resume:  { from: "paused",         to: "active" },
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Missing Authorization header" }, 401);

    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );
    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) return json({ error: "Unauthorized" }, 401);

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const { campaign_id, action, note } = await req.json();

    // withdraw is owner-gated (advertiser deletes their own unapproved ad);
    // everything else stays admins-only.
    if (action === "withdraw") {
      return await withdraw(admin, user.id, campaign_id);
    }

    // Admin gate — service-role read of the admins table (RLS-independent).
    const { data: adminRow } = await admin
      .from("admins").select("user_id").eq("user_id", user.id).maybeSingle();
    if (!adminRow) return json({ error: "Admins only" }, 403);

    const t = TRANSITIONS[action];
    if (!campaign_id || !t) return json({ error: "Invalid campaign_id or action" }, 400);

    const { data: c } = await admin
      .from("ad_campaigns")
      .select("id, status, starts_at, ends_at, stripe_payment_intent_id")
      .eq("id", campaign_id)
      .maybeSingle();
    if (!c) return json({ error: "Campaign not found" }, 404);
    if (c.status !== t.from) {
      return json({ error: `Campaign is ${c.status}, expected ${t.from}` }, 409);
    }

    // ── Stripe: money moves only on approve/reject ──────────────────────────
    const piId = c.stripe_payment_intent_id ?? "";
    const hasPi = piId.startsWith("pi_"); // webhook stored the real PI on payment

    if (action === "approve") {
      if (!hasPi) return json({ error: "No PaymentIntent on campaign — was it paid?" }, 409);
      const pi = await stripe.paymentIntents.retrieve(piId);
      if (pi.status === "requires_capture") {
        try {
          await stripe.paymentIntents.capture(piId);
        } catch (err) {
          // Most likely the ~7-day auth window expired. Nothing was charged;
          // the brand must check out again.
          return json({ error: `Capture failed (authorization likely expired): ${err}` }, 409);
        }
      } else if (pi.status !== "succeeded") {
        return json({ error: `PaymentIntent not capturable (status ${pi.status})` }, 409);
      }
      // pi.status === "succeeded" ⇒ legacy auto-capture payment; nothing to do.
    }

    if (action === "reject" && hasPi) await releaseHold(piId);

    // ── DB transition (status-guarded against races) ────────────────────────
    const update: Record<string, string> = { status: t.to };
    if (action === "reject") {
      // Optional reason, shown to the advertiser on their dashboard.
      const trimmed = typeof note === "string" ? note.trim().slice(0, 300) : "";
      if (trimmed) update.review_note = trimmed;
    }
    if (action === "approve") {
      // Flight clock starts at activation: preserve the purchased duration but
      // shift the window to now (fixes daily-burn accruing before serving).
      const durationMs =
        new Date(c.ends_at).getTime() - new Date(c.starts_at).getTime();
      const now = new Date();
      update.starts_at = now.toISOString();
      update.ends_at = new Date(now.getTime() + durationMs).toISOString();
    }

    const { data: updated, error: updErr } = await admin
      .from("ad_campaigns")
      .update(update)
      .eq("id", campaign_id)
      .eq("status", t.from)
      .select("id, status, starts_at, ends_at")
      .single();
    if (updErr || !updated) return json({ error: "Update failed (status changed concurrently?)" }, 409);

    return json({ campaign: updated });
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});

// Release an authorization: cancel if still a hold, refund if a legacy
// pre-manual-capture payment already moved money.
async function releaseHold(piId: string) {
  const pi = await stripe.paymentIntents.retrieve(piId);
  if (pi.status === "requires_capture") {
    await stripe.paymentIntents.cancel(piId); // releases the hold, no charge
  } else if (pi.status === "succeeded") {
    await stripe.refunds.create({ payment_intent: piId });
  }
}

// Owner hard-delete of an unapproved (pending_review/rejected) campaign.
// deno-lint-ignore no-explicit-any
async function withdraw(admin: any, userId: string, campaignId: string) {
  if (!campaignId) return json({ error: "Invalid campaign_id" }, 400);

  const { data: c } = await admin
    .from("ad_campaigns")
    .select("id, status, stripe_payment_intent_id, advertiser_account_id, ad_creatives(image_url)")
    .eq("id", campaignId)
    .maybeSingle();
  if (!c) return json({ error: "Campaign not found" }, 404);

  // Owner gate: caller must own the advertiser account on the campaign.
  const { data: owner } = await admin
    .from("advertiser_accounts")
    .select("id")
    .eq("id", c.advertiser_account_id ?? "00000000-0000-0000-0000-000000000000")
    .eq("auth_user_id", userId)
    .maybeSingle();
  if (!owner) return json({ error: "Not your campaign" }, 403);

  if (c.status !== "pending_review" && c.status !== "rejected") {
    return json({ error: `Campaign is ${c.status} — only in-review or rejected ads can be deleted` }, 409);
  }

  // 1) Release the card hold first (rejected ads already had it released).
  const piId = c.stripe_payment_intent_id ?? "";
  if (c.status === "pending_review" && piId.startsWith("pi_")) {
    await releaseHold(piId);
  }

  // 2) Delete the campaign (creative/targeting/events cascade), guarded
  //    against a concurrent status change.
  const imageUrl: string | undefined = c.ad_creatives?.[0]?.image_url;
  const { data: deleted, error: delErr } = await admin
    .from("ad_campaigns")
    .delete()
    .eq("id", campaignId)
    .eq("status", c.status)
    .select("id");
  if (delErr || !deleted?.length) {
    return json({ error: "Delete failed (status changed concurrently?)" }, 409);
  }

  // 3) Best-effort creative image cleanup — an orphaned object is cosmetic.
  const path = imageUrl?.split("/ad-creatives/")[1];
  if (path) {
    const { error: rmErr } = await admin.storage
      .from("ad-creatives")
      .remove([decodeURIComponent(path)]);
    if (rmErr) console.error("creative cleanup failed:", rmErr);
  }

  return json({ deleted: campaignId });
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
