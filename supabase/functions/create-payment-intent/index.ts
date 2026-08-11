// Supabase Edge Function: create-payment-intent
//
// Setup:
//   supabase secrets set STRIPE_SECRET_KEY=sk_test_...
//   supabase secrets set STRIPE_SUCCESS_URL=https://your-app.com/ticket-success
//   supabase secrets set STRIPE_CANCEL_URL=https://your-app.com/ticket-cancel
//   supabase functions deploy create-payment-intent
//
// Request (POST, Bearer = user JWT):
//   { "event_id": "uuid", "kind": "live" | "replay", "origin": "macos" }
//   kind defaults to "live"; origin is optional and recorded in Stripe
//   metadata (see _shared/checkout_origin.ts) — omitted ⇒ "unknown".
//   Price and title are read server-side from events — the client cannot set
//   them. kind "replay" prices from events.replay_price and requires the replay
//   to be published (Phase 2 VOD pricing); kind "live" prices from events.price.
//
// Response:
//   { "checkout_url": "https://checkout.stripe.com/..." }
//   or { "error": "..." }

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14?target=deno";
import { corsHeaders as corsHeadersFor } from "../_shared/cors.ts";
import { checkoutOrigin } from "../_shared/checkout_origin.ts";

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

    const { event_id, kind: rawKind, origin: rawOrigin } = await req.json();
    const kind = rawKind === "replay" ? "replay" : "live";
    // Which app the sale came from. Older clients send nothing → "unknown".
    const origin = checkoutOrigin(rawOrigin);
    if (!event_id) {
      return json({ error: "Invalid request body" }, 400);
    }

    // Service role for all trusted reads/writes below.
    const adminClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Price and title come from the DB — never the client. A tampered client
    // can no longer buy a ticket for an arbitrary amount. Free events (price
    // null/0) aren't sold through Stripe.
    const { data: event } = await adminClient
      .from("events")
      .select("host_id, price, title, status, replay_price, replay_published_at")
      .eq("id", event_id)
      .maybeSingle();

    if (!event) {
      return json({ error: "Event not found" }, 404);
    }

    let amount_cents: number;
    let event_title: string;
    if (kind === "replay") {
      // Replay purchase: only after the host (or the 48h cron) publishes.
      if (!event.replay_published_at) {
        return json({ error: "Replay is not available yet" }, 409);
      }
      amount_cents = event.replay_price ?? 0;
      if (amount_cents <= 0) {
        return json({ error: "This replay is free — no payment required" }, 400);
      }
      // Don't sell a replay about to expire (30-day retention, 0024): require
      // ≥48h of watch window left, measured from the replay row's created_at.
      const { data: replay } = await adminClient
        .from("replays")
        .select("created_at")
        .eq("event_id", event_id)
        .eq("status", "ready")
        .order("created_at", { ascending: false })
        .maybeSingle();
      if (!replay) return json({ error: "Replay is not available yet" }, 409);
      const expiresAt = new Date(replay.created_at).getTime() + 30 * 24 * 3600 * 1000;
      if (expiresAt - Date.now() < 48 * 3600 * 1000) {
        return json({ error: "This replay is no longer for sale" }, 409);
      }
      event_title = `${event.title ?? "Event"} — Replay`;
    } else {
      // Live ticket: not for ended shows (the replay path covers those).
      if (event.status === "ended") {
        return json({ error: "This event has ended — get the replay instead" }, 409);
      }
      amount_cents = event.price ?? 0;
      if (amount_cents <= 0) {
        return json({ error: "This event is free — no payment required" }, 400);
      }
      event_title = event.title ?? "Event Ticket";

      const { data: remaining } = await adminClient.rpc("tickets_remaining", {
        p_event_id: event_id,
      });

      if (remaining !== null && remaining <= 0) {
        return json({ error: "Sold out" }, 409);
      }
    }

    // Check if buyer already has a paid ticket
    const { data: existing } = await adminClient
      .from("tickets")
      .select("id, status")
      .eq("event_id", event_id)
      .eq("buyer_id", user.id)
      .maybeSingle();

    // One paid row per (event, buyer) — a live ticket already unlocks the
    // replay, and a replay purchase can't be bought twice.
    if (existing?.status === "paid") {
      return json({ error: "Already purchased" }, 409);
    }

    // Revenue split: the creator's share is deposited to their Connect account
    // at checkout via a destination charge; the platform keeps the remainder as
    // an application fee. Share is config-driven (fail closed to 50%). Each
    // ticket freezes its own fee so earnings stay accurate if the share changes.
    const { data: cfg } = await adminClient
      .from("app_config")
      .select("creator_revenue_share")
      .eq("id", 1)
      .maybeSingle();
    const share = Number(cfg?.creator_revenue_share ?? 0.5);
    const creatorCents = Math.floor(amount_cents * share);
    const feeCents = amount_cents - creatorCents; // platform's cut, always < amount

    // Host must have a payable Connect account for the split; if not (or Stripe
    // is unreachable), fall back to a plain platform charge so the sale still
    // completes — flagged for a later manual transfer.
    let destination: string | null = null;
    const { data: hostProfile } = await adminClient
      .from("profiles")
      .select("stripe_account_id")
      .eq("id", event.host_id)
      .maybeSingle();
    const hostAccountId = hostProfile?.stripe_account_id as string | null;
    if (hostAccountId) {
      try {
        const acct = await stripe.accounts.retrieve(hostAccountId);
        if (acct.charges_enabled) destination = hostAccountId;
      } catch (_) {/* Stripe unreachable → fallback, don't fail the sale */}
    }
    if (!destination) {
      console.warn(
        `payout_fallback: event=${event_id} host=${event.host_id} — no payable Connect account, charging platform (manual transfer owed)`,
      );
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
      // Atomic split when the host is payable; plain charge otherwise.
      ...(destination
        ? {
            payment_intent_data: {
              application_fee_amount: feeCents,
              transfer_data: { destination },
            },
          }
        : {}),
      success_url: `${Deno.env.get("STRIPE_SUCCESS_URL")}?event_id=${event_id}&session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${Deno.env.get("STRIPE_CANCEL_URL")}?event_id=${event_id}`,
      metadata: {
        event_id,
        buyer_id: user.id,
        kind,
        origin,
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
        kind,
        split_status: destination ? "split" : "platform_fallback",
        application_fee_cents: destination ? feeCents : null,
      },
      { onConflict: "event_id,buyer_id", ignoreDuplicates: false }
    );

    return json({ checkout_url: session.url });
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});

