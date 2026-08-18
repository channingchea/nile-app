// Supabase Edge Function: refund-ticket
//
// Refund of a single paid ticket, by either party:
//   • the HOST, at any time (the original behaviour — "refund this attendee");
//   • the BUYER, up to TICKET_REFUND_WINDOW_HOURS before the event starts.
//     That is the cancellation policy Nile states above the Stripe pay button;
//     see _shared/money.ts, which owns both the window and the wording.
//
// Setup:
//   supabase secrets set STRIPE_SECRET_KEY=sk_test_...
//   supabase functions deploy refund-ticket
//
// Also reads LIVEKIT_URL / LIVEKIT_API_KEY / LIVEKIT_API_SECRET (already set for
// the `livekit` function) to disconnect a refunded viewer from a show that is
// running. Missing credentials degrade to "refund without eject", never a 500.
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
// Shared with stripe-webhook's chargeback path — a revoked ticket has to leave
// the room whether the money went back voluntarily or was pulled.
import { ejectFromLiveRoom } from "../_shared/livekit_eject.ts";
import { TICKET_REFUND_WINDOW_HOURS } from "../_shared/money.ts";

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
      // Must stay one string literal — supabase-js infers the row type from it,
      // and a concatenated expression collapses every field to `unknown`.
      .select("id, status, buyer_id, stripe_payment_intent_id, split_status, events!tickets_event_id_fkey(host_id, status, livekit_room, scheduled_at)")
      .eq("id", ticket_id)
      .maybeSingle();

    if (!ticket) return json({ error: "Ticket not found" }, 404);

    // Authorize. Two callers, two rules (#37):
    //   • the host, at any time — this is the existing "refund an attendee"
    //     path and it stays unconditional;
    //   • the buyer, but only while the published cancellation window is still
    //     open. That window is the whole disclosed policy: TICKET_REFUND_POLICY
    //     is printed above the pay button by create-payment-intent, so this
    //     check and that sentence have to agree or we are advertising a refund
    //     we won't honour.
    const event = ticket.events as
      | { host_id?: string; status?: string; livekit_room?: string | null; scheduled_at?: string | null }
      | null;
    const isHost = event?.host_id === user.id;
    const isBuyer = ticket.buyer_id === user.id;
    if (!isHost && !isBuyer) return json({ error: "Forbidden" }, 403);

    if (!isHost) {
      // A show that is already running (or over) is delivered — there is
      // nothing left to cancel, whatever the clock says.
      if (event?.status !== "scheduled") {
        return json(
          { error: "This event has already started. Tickets can only be cancelled beforehand." },
          409,
        );
      }
      const startsAt = event?.scheduled_at ? Date.parse(event.scheduled_at) : NaN;
      if (!Number.isFinite(startsAt)) {
        return json({ error: "This event has no scheduled start, so it can't be cancelled here." }, 409);
      }
      const hoursOut = (startsAt - Date.now()) / 3_600_000;
      if (hoursOut < TICKET_REFUND_WINDOW_HOURS) {
        return json(
          {
            error:
              `Free cancellation closed ${TICKET_REFUND_WINDOW_HOURS} hours before the event. ` +
              "You'll still be refunded automatically if the host cancels or never goes live.",
          },
          409,
        );
      }
    }

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

    // If the show is running right now, cut them off. Refunding someone used to
    // take the money back and leave them watching, because the ticket is only
    // checked when their token is minted.
    if (event?.status === "live" || event?.status === "soundcheck") {
      await ejectFromLiveRoom(
        event.livekit_room ?? null,
        ticket.buyer_id as string,
        "refund-ticket",
      );
    }

    return json({ ok: true, refund_id: refund.id });
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});

