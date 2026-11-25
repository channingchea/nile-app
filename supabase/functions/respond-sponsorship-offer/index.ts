// Supabase Edge Function: respond-sponsorship-offer
//
// The host half of host-approved sponsorships (migrations 0095–0097). Nile has
// already screened the creative for policy; this is where the host decides
// whether the brand and the money are right for their show.
//
//   { campaign_id, accept: boolean, note? }   — note: the host's comment,
//   shown to the advertiser on decline and stored on accept (≤300 chars)
//
//   accept   pending_host → active. Charges the card saved at offer time
//            OFF-SESSION as a Connect destination charge, freezes the split on
//            the row, and declines every competing offer on the same event.
//            A recoverable decline parks the offer in payment_pending for 6h;
//            a hard decline lands in 'rejected', which by design does not
//            count against the advertiser's three offers for this event.
//   decline  pending_host → declined, with the host's note emailed on.
//
// Callable only by the event's host — RLS hides ad_campaigns from hosts
// entirely, so ownership is re-derived here with the service role.
//
// Deploy: supabase functions deploy respond-sponsorship-offer   (KEEP JWT on)

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders as corsHeadersFor } from "../_shared/cors.ts";
import { failure } from "../_shared/errors.ts";
import { acceptSponsorshipOffer, dollars, klaviyoEvent } from "../_shared/sponsorship.ts";

// CORS headers are per-request, so the JSON responder is built per-request too.
type Json = (body: unknown, status?: number) => Response;
const makeJson = (cors: Record<string, string>): Json =>
  (body, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

serve(async (req) => {
  const corsHeaders = corsHeadersFor(req);
  const json = makeJson(corsHeaders);
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Missing Authorization header" }, 401);

    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) return json({ error: "Unauthorized" }, 401);

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { campaign_id, accept, note } = await req.json();
    if (!campaign_id || typeof accept !== "boolean") {
      return json({ error: "Invalid campaign_id or accept" }, 400);
    }
    const hostNote = typeof note === "string" ? note.trim().slice(0, 300) : "";

    const { data } = await admin
      .from("ad_campaigns")
      .select(
        "id, status, placement, offer_expires_at, budget_cents, " +
          "advertiser_accounts(name, contact_email), events(title, host_id)",
      )
      .eq("id", campaign_id)
      .maybeSingle();
    // deno-lint-ignore no-explicit-any
    const c = data as any;
    if (!c || c.placement !== "lobby") return json({ error: "Offer not found" }, 404);
    const ev = c.events;
    if (ev?.host_id !== user.id) return json({ error: "Not your event" }, 403);
    if (c.status !== "pending_host") {
      return json({ error: `Offer is ${c.status}, not awaiting your decision` }, 409);
    }
    if (c.offer_expires_at && new Date(c.offer_expires_at).getTime() < Date.now()) {
      return json({ error: "This offer has expired" }, 409);
    }

    if (accept) {
      const outcome = await acceptSponsorshipOffer(admin, campaign_id, { note: hostNote });
      if (outcome.result === "error") return json({ error: outcome.error }, outcome.status);
      // payment_pending and rejected are real, explained outcomes — not 500s.
      // The host UI reads them straight off `result`.
      return json({ campaign_id, result: outcome.result });
    }

    return await decline(admin, c, campaign_id, hostNote, ev?.title ?? "your event", json);
  } catch (err) {
    console.error(err);
    return json(failure(err, "respond-sponsorship-offer"), 500);
  }
});

// Decline: nothing was ever charged (the card is only saved), so this is a
// status flip plus an honest email. Status-guarded so it can't fight a
// concurrent accept or the expiry sweep.
// deno-lint-ignore no-explicit-any
async function decline(
  admin: any, c: any, campaignId: string, hostNote: string, eventTitle: string, json: Json,
) {
  const { data: updated, error } = await admin
    .from("ad_campaigns")
    .update({
      status: "declined",
      host_note: hostNote || null,
      host_decided_at: new Date().toISOString(),
    })
    .eq("id", campaignId)
    .eq("status", "pending_host")
    .select("id")
    .maybeSingle();
  if (error || !updated) {
    return json({ error: "Update failed (offer changed concurrently?)" }, 409);
  }

  await klaviyoEvent(
    "Nile Sponsorship Offer Declined",
    c.advertiser_accounts?.contact_email,
    `${campaignId}:offer_declined`,
    {
      brand: c.advertiser_accounts?.name ?? "there",
      event_title: eventTitle,
      amount: dollars(c.budget_cents),
      amount_cents: c.budget_cents,
      campaign_id: campaignId,
      host_note: hostNote,
    },
  );
  return json({ campaign_id: campaignId, result: "declined" });
}
