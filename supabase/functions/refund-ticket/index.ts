// Supabase Edge Function: refund-ticket
//
// Host-initiated refund of a single paid ticket.
//
// Setup:
//   supabase secrets set STRIPE_SECRET_KEY=sk_test_...
//   supabase functions deploy refund-ticket
//
// Request (POST, Bearer = user JWT):
//   { "ticket_id": "uuid" }
// Response:
//   { "ok": true, "refund_id": "re_..." }  or  { "error": "..." }
//
// The charge.refunded webhook also flips the ticket to 'refunded'; this
// function updates it optimistically so the host UI reflects the change at
// once. Both paths are idempotent.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14?target=deno";
import { corsHeaders as corsHeadersFor } from "../_shared/cors.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
  httpClient: Stripe.createFetchHttpClient(),
});

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
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) return json({ error: "Unauthorized" }, 401);

    const { ticket_id } = await req.json();
    if (!ticket_id) return json({ error: "Missing ticket_id" }, 400);

    const adminClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Fetch the ticket + its event's host in one query.
    const { data: ticket } = await adminClient
      .from("tickets")
      .select("id, status, stripe_payment_intent_id, split_status, events!tickets_event_id_fkey(host_id)")
      .eq("id", ticket_id)
      .maybeSingle();

    if (!ticket) return json({ error: "Ticket not found" }, 404);

    // Authorize: only the event host may refund.
    const hostId = (ticket.events as { host_id?: string } | null)?.host_id;
    if (hostId !== user.id) return json({ error: "Forbidden" }, 403);

    if (ticket.status !== "paid") {
      return json({ error: `Cannot refund a ${ticket.status} ticket` }, 409);
    }

    const pi = ticket.stripe_payment_intent_id as string | null;
    if (!pi || !pi.startsWith("pi_")) {
      return json({ error: "Ticket has no settled payment to refund" }, 409);
    }

    // Split tickets sent the creator's share to their Connect account at sale,
    // so the refund must also pull that transfer back and return the platform
    // fee. Fallback tickets were a plain platform charge → plain refund.
    const isSplit = ticket.split_status === "split";
    const refund = await stripe.refunds.create(
      isSplit
        ? { payment_intent: pi, reverse_transfer: true, refund_application_fee: true }
        : { payment_intent: pi },
    );

    // Optimistic update; webhook will confirm.
    await adminClient
      .from("tickets")
      .update({ status: "refunded" })
      .eq("id", ticket_id);

    return json({ ok: true, refund_id: refund.id });
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});

