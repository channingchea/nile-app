// Supabase Edge Function: create-ad-payment
//
// Phase A-2 — host boosts. Creates a Stripe Checkout Session (hosted web page)
// that charges a host to boost their own event. Unlike create-payment-intent
// (ticket sales, which split to the host via Connect), this is PLATFORM-WARD:
// the host pays the platform, so there is NO Connect destination / application
// fee. All checkout happens on the web ad portal — never in-app — so no iOS IAP.
//
// Setup:
//   supabase secrets set STRIPE_SECRET_KEY=sk_test_...
//   supabase secrets set AD_SUCCESS_URL=https://links.nile.app/boost-success
//   supabase secrets set AD_CANCEL_URL=https://links.nile.app/boost
//   supabase functions deploy create-ad-payment        (KEEP JWT on — reads the user session)
//
// Request (POST, Bearer = user JWT):
//   { "event_id": "uuid", "budget_cents": 2500, "duration_days": 7 }
//
// Response:
//   { "checkout_url": "https://checkout.stripe.com/..." }  or  { "error": "..." }

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

// Allowed boost budgets (cents) — mirrors the portal's $10 / $25 / $50 presets.
const ALLOWED_BUDGETS = new Set([1000, 2500, 5000]);
const ALLOWED_DURATIONS = new Set([3, 7, 14]);

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Missing Authorization header" }, 401);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) return json({ error: "Unauthorized" }, 401);

    const { event_id, budget_cents, duration_days } = await req.json();
    if (!event_id || !ALLOWED_BUDGETS.has(budget_cents) || !ALLOWED_DURATIONS.has(duration_days)) {
      return json({ error: "Invalid request body" }, 400);
    }

    const adminClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // A host may only boost their OWN event. Verify ownership server-side.
    const { data: ev } = await adminClient
      .from("events")
      .select("id, host_id, title, status")
      .eq("id", event_id)
      .maybeSingle();
    if (!ev) return json({ error: "Event not found" }, 404);
    if (ev.host_id !== user.id) return json({ error: "Not your event" }, 403);
    if (ev.status === "ended") return json({ error: "Event has ended" }, 409);

    const now = new Date();
    const endsAt = new Date(now.getTime() + duration_days * 86_400_000);

    // Pre-create the campaign as pending_payment. The webhook flips it to active
    // and stores the real PaymentIntent id once Stripe confirms the charge.
    const { data: campaign, error: campErr } = await adminClient
      .from("ad_campaigns")
      .insert({
        advertiser_id: ev.host_id,
        name: `Boost: ${ev.title}`,
        event_id,
        pricing_model: "flat",
        budget_cents,
        starts_at: now.toISOString(),
        ends_at: endsAt.toISOString(),
        status: "pending_payment",
      })
      .select("id")
      .single();
    if (campErr || !campaign) return json({ error: "Could not create campaign" }, 500);

    const session = await stripe.checkout.sessions.create({
      payment_method_types: ["card"],
      line_items: [
        {
          price_data: {
            currency: "usd",
            unit_amount: budget_cents,
            product_data: { name: `Boost “${ev.title}” (${duration_days} days)` },
          },
          quantity: 1,
        },
      ],
      mode: "payment",
      success_url: `${Deno.env.get("AD_SUCCESS_URL")}?campaign_id=${campaign.id}&session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${Deno.env.get("AD_CANCEL_URL")}?event=${event_id}`,
      // type lets the shared stripe-webhook branch to the ad path; campaign_id
      // is matched on checkout.session.completed to flip status → active.
      metadata: {
        type: "ad_campaign",
        campaign_id: campaign.id,
        advertiser_id: ev.host_id,
      },
    });

    // Store session.id so the webhook can match (PaymentIntent is null here,
    // same pattern as create-payment-intent / stripe-webhook for tickets).
    await adminClient
      .from("ad_campaigns")
      .update({ stripe_payment_intent_id: session.id })
      .eq("id", campaign.id);

    return json({ checkout_url: session.url });
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
