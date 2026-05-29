// Supabase Edge Function: create-payment-intent
//
// Setup:
//   supabase secrets set STRIPE_SECRET_KEY=sk_test_...
//   supabase secrets set STRIPE_SUCCESS_URL=https://your-app.com/ticket-success
//   supabase secrets set STRIPE_CANCEL_URL=https://your-app.com/ticket-cancel
//   supabase functions deploy create-payment-intent
//
// Request (POST, Bearer = user JWT):
//   { "event_id": "uuid", "event_title": "string", "amount_cents": 1000 }
//
// Response:
//   { "checkout_url": "https://checkout.stripe.com/..." }
//   or { "error": "..." }

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

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // Auth
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return json({ error: "Missing Authorization header" }, 401);
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) {
      return json({ error: "Unauthorized" }, 401);
    }

    const { event_id, event_title, amount_cents } = await req.json();
    if (!event_id || !amount_cents || amount_cents <= 0) {
      return json({ error: "Invalid request body" }, 400);
    }

    // Check ticket availability using service role
    const adminClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const { data: remaining } = await adminClient.rpc("tickets_remaining", {
      p_event_id: event_id,
    });

    if (remaining !== null && remaining <= 0) {
      return json({ error: "Sold out" }, 409);
    }

    // Check if buyer already has a paid ticket
    const { data: existing } = await adminClient
      .from("tickets")
      .select("id, status")
      .eq("event_id", event_id)
      .eq("buyer_id", user.id)
      .maybeSingle();

    if (existing?.status === "paid") {
      return json({ error: "Already purchased" }, 409);
    }

    // Create Stripe Checkout Session (hosted page — no native SDK needed)
    const session = await stripe.checkout.sessions.create({
      payment_method_types: ["card"],
      line_items: [
        {
          price_data: {
            currency: "usd",
            unit_amount: amount_cents,
            product_data: { name: event_title ?? "Event Ticket" },
          },
          quantity: 1,
        },
      ],
      mode: "payment",
      success_url: `${Deno.env.get("STRIPE_SUCCESS_URL")}?event_id=${event_id}&session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${Deno.env.get("STRIPE_CANCEL_URL")}?event_id=${event_id}`,
      metadata: {
        event_id,
        buyer_id: user.id,
      },
    });

    // Pre-create a pending ticket row (upsert in case of retry)
    await adminClient.from("tickets").upsert(
      {
        event_id,
        buyer_id: user.id,
        stripe_payment_intent_id: session.payment_intent as string ?? session.id,
        amount_cents,
        status: "pending",
      },
      { onConflict: "event_id,buyer_id", ignoreDuplicates: false }
    );

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
