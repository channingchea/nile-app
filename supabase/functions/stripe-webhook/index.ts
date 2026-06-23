// Supabase Edge Function: stripe-webhook
//
// Setup:
//   supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_...
//   supabase functions deploy stripe-webhook --no-verify-jwt
//
// IMPORTANT: deploy with --no-verify-jwt. Stripe signs with the webhook
// secret, not a Supabase JWT — with JWT verification on, Supabase's gateway
// rejects every delivery with 401 UNAUTHORIZED_NO_AUTH_HEADER before this
// function runs. Auth is still enforced via constructEventAsync (the
// signature check below). This applies ONLY to the webhook; stripe-connect
// and refund-ticket DO need JWT verification (they read the user's session).
//
// In Stripe Dashboard → Webhooks → Add endpoint:
//   URL: https://<project>.supabase.co/functions/v1/stripe-webhook
//   Events: checkout.session.completed, charge.refunded

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14?target=deno";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
  httpClient: Stripe.createFetchHttpClient(),
});

const adminClient = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

serve(async (req) => {
  const body = await req.text();
  const sig = req.headers.get("stripe-signature");
  const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, sig!, webhookSecret);
  } catch (err) {
    return new Response(`Webhook error: ${err}`, { status: 400 });
  }

  if (event.type === "checkout.session.completed") {
    const session = event.data.object as Stripe.Checkout.Session;
    const piId = (session.payment_intent as string) ?? session.id;

    // Ad-platform boost (A-2): the host paid to boost an event. Activate the
    // campaign and record the real PI id. Branched by create-ad-payment's
    // metadata.type so it never collides with ticket sales.
    if (session.metadata?.type === "ad_campaign") {
      const campaignId = session.metadata.campaign_id;
      if (campaignId) {
        await adminClient
          .from("ad_campaigns")
          .update({ status: "active", stripe_payment_intent_id: piId })
          .eq("id", campaignId);
      }
    } else {
      // Ticket sale (default). The pending row was stored under session.id
      // (PaymentIntent is null at session creation). Mark paid by session.id and
      // record the real PI id so a later refund (which carries only the PI id)
      // can match.
      await adminClient
        .from("tickets")
        .update({ status: "paid", stripe_payment_intent_id: piId })
        .eq("stripe_payment_intent_id", session.id);
    }
  }

  if (event.type === "charge.refunded") {
    const charge = event.data.object as Stripe.Charge;
    const paymentIntentId = charge.payment_intent as string;
    if (paymentIntentId) {
      await adminClient.rpc("confirm_ticket", {
        p_payment_intent_id: paymentIntentId,
        p_status: "refunded",
      });
    }
  }

  return new Response(JSON.stringify({ received: true }), {
    headers: { "Content-Type": "application/json" },
  });
});
