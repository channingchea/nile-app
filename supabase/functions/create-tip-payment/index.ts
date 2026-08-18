// Supabase Edge Function: create-tip-payment
//
// A viewer tips the host during a live show. Unlike ticket/boost checkout, tips
// use an ATOMIC CONNECT SPLIT: a destination charge sends the tip (minus the
// platform application fee) straight to the host's connected account at
// checkout — no separate payout/reconciliation. Gated on the host having a
// payable Connect account. Ephemeral chat announcement + host notification are
// handled on webhook success (stripe-webhook), not here.
//
// Setup:
//   supabase secrets set STRIPE_SECRET_KEY=sk_test_...
//   supabase secrets set TIP_SUCCESS_URL=https://links.joinnile.com/tip-success
//   supabase secrets set TIP_CANCEL_URL=https://links.joinnile.com/tip
//   supabase functions deploy create-tip-payment        (KEEP JWT on — reads the user session)
//
// Request (POST, Bearer = tipper JWT):
//   { "event_id": "uuid", "amount_cents": 500, "origin": "macos" }
//   origin is optional and recorded in Stripe metadata (see
//   _shared/checkout_origin.ts) — omitted ⇒ "unknown".
//
// Response: { "checkout_url": "https://checkout.stripe.com/..." }  or  { "error": "..." }

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14?target=deno";
import { corsHeaders as corsHeadersFor } from "../_shared/cors.ts";
import { checkoutOrigin } from "../_shared/checkout_origin.ts";
import {
  CURRENCY, priceTaxParams, taxParams, TIP_REFUND_POLICY,
} from "../_shared/money.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
  httpClient: Stripe.createFetchHttpClient(),
});

// Platform tip fee is config-driven (app_config.tip_fee_share), defaulting to
// 10% if the row/column is missing. Read per-request below.
const DEFAULT_TIP_FEE_SHARE = 0.10;

// Preset amounts (cents). Custom amounts are allowed within [MIN, MAX].
const PRESETS = new Set([200, 500, 1000, 2000]);
const MIN_CENTS = 100;
const MAX_CENTS = 50000;

serve(async (req) => {
  // Per-request CORS (fix #4): allowlisted origins only — see _shared/cors.ts.
  const corsHeaders = corsHeadersFor(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Missing Authorization header" }, 401);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );

    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) return json({ error: "Unauthorized" }, 401);

    const { event_id, amount_cents, origin: rawOrigin } = await req.json();
    if (!event_id) return json({ error: "Missing event_id" }, 400);
    // Which app the tip came from. Older clients send nothing → "unknown".
    const origin = checkoutOrigin(rawOrigin);
    // Server-side amount validation — never trust the client.
    const amt = Number(amount_cents);
    const validAmount =
      Number.isInteger(amt) &&
      (PRESETS.has(amt) || (amt >= MIN_CENTS && amt <= MAX_CENTS));
    if (!validAmount) return json({ error: "Invalid tip amount" }, 400);

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Event must exist and be live; can't tip your own show.
    const { data: ev } = await admin
      .from("events")
      .select("id, host_id, title, status")
      .eq("id", event_id)
      .maybeSingle();
    if (!ev) return json({ error: "Event not found" }, 404);
    if (ev.host_id === user.id) return json({ error: "Cannot tip your own show" }, 400);
    if (ev.status === "ended") return json({ error: "Event has ended" }, 409);

    // Host must have a payable Connect account. Verify charges are enabled so we
    // never create a session Stripe will reject at capture.
    const { data: hostProfile } = await admin
      .from("profiles")
      .select("stripe_account_id")
      .eq("id", ev.host_id)
      .maybeSingle();
    const hostAccountId = hostProfile?.stripe_account_id as string | null;
    if (!hostAccountId) return json({ error: "host_not_payable" }, 409);

    const account = await stripe.accounts.retrieve(hostAccountId);
    if (!account.charges_enabled) return json({ error: "host_not_payable" }, 409);

    const { data: cfg } = await admin
      .from("app_config")
      .select("tip_fee_share")
      .eq("id", 1)
      .maybeSingle();
    const feeShare = Number(cfg?.tip_fee_share ?? DEFAULT_TIP_FEE_SHARE);
    const fee = Math.round(amt * feeShare);

    const session = await stripe.checkout.sessions.create({
      payment_method_types: ["card"],
      line_items: [{
        price_data: {
          currency: CURRENCY,
          unit_amount: amt,
          product_data: { name: `Tip for “${ev.title}”` },
          ...priceTaxParams(),
        },
        quantity: 1,
      }],
      mode: "payment",
      ...taxParams(),
      custom_text: { submit: { message: TIP_REFUND_POLICY } },
      // Atomic split: application fee to the platform, remainder to the host.
      payment_intent_data: {
        application_fee_amount: fee,
        transfer_data: { destination: hostAccountId },
      },
      success_url: `${Deno.env.get("TIP_SUCCESS_URL")}?event_id=${event_id}&session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${Deno.env.get("TIP_CANCEL_URL")}?event_id=${event_id}`,
      metadata: {
        type: "tip",
        event_id,
        tipper_id: user.id,
        host_id: ev.host_id,
        amount_cents: String(amt),
        fee_cents: String(fee),
        origin,
      },
    });

    // Pending ledger row keyed on session.id (PaymentIntent is null now); the
    // webhook flips it to paid and records the real PI id.
    await admin.from("tips").insert({
      event_id,
      tipper_id: user.id,
      host_id: ev.host_id,
      amount_cents: amt,
      fee_cents: fee,
      stripe_payment_intent_id: session.id,
      status: "pending",
    });

    return json({ checkout_url: session.url });
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});

