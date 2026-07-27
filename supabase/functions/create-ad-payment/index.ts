// Supabase Edge Function: create-ad-payment
//
// Handles TWO checkout paths, both platform-ward (advertiser pays the platform;
// no Connect destination / application fee) and both on the web ad portal — never
// in-app — so no iOS IAP:
//
//   1) HOST BOOST (A-2).  { event_id, budget_cents, duration_days }
//      Host boosts their own event. Campaign → active on payment (webhook).
//
//   2) STANDALONE CREATIVE AD (A-4 Part 2).
//      { advertiser_account_id, headline, body, click_url, image_url,
//        topic_ids?, budget_cents, duration_days }
//      Currents VIDEO variant (0068): pass creative_kind: "video" with
//      { video_url, thumb_url?, duration_ms } instead of image_url; body is
//      optional. Same checkout/review flow; serves in the Currents player.
//      External brand runs a creative ad targeting neither event nor post.
//      This fn creates the campaign (pending_payment, advertiser_account_id set,
//      advertiser_id null) + ad_creatives + ad_targeting rows server-side, then a
//      Checkout Session with capture_method: manual — checkout only AUTHORIZES
//      the card (2026-07-01). The webhook flips it to pending_review (NOT
//      active); admin approval (review-ad-campaign fn) captures the
//      PaymentIntent, and rejection cancels the authorization so no money ever
//      moves. Stripe auth holds last ~7 days — that window is the review SLA.
//
// Setup:
//   supabase secrets set STRIPE_SECRET_KEY=sk_test_...
//   supabase secrets set AD_SUCCESS_URL=https://links.joinnile.com/boost-success
//   supabase secrets set AD_CANCEL_URL=https://links.joinnile.com/boost
//   supabase secrets set AD_PORTAL_URL=https://ads.joinnile.com   (standalone redirects; optional, this is the default)
//   supabase functions deploy create-ad-payment        (KEEP JWT on — reads the user session)
//
// Response: { "checkout_url": "https://checkout.stripe.com/..." }  or  { "error": "..." }

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14?target=deno";
import { corsHeaders as corsHeadersFor } from "../_shared/cors.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
  httpClient: Stripe.createFetchHttpClient(),
});

// Allowed budgets/durations — same presets for host boosts and standalone ads.
const ALLOWED_BUDGETS = new Set([1000, 2500, 5000]);
const ALLOWED_DURATIONS = new Set([3, 7, 14]);

const HEADLINE_MAX = 60;
const BODY_MAX = 150;

// Base URL of the advertiser web portal, for standalone success/cancel redirects.
// The portal is a single Vue island at /advertise/portal on the ads subdomain.
function portalUrl() {
  const base = (Deno.env.get("AD_PORTAL_URL") ?? "https://ads.joinnile.com").replace(/\/$/, "");
  return `${base}/advertise/portal`;
}

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

    const body = await req.json();
    const { budget_cents, duration_days } = body;
    if (!ALLOWED_BUDGETS.has(budget_cents) || !ALLOWED_DURATIONS.has(duration_days)) {
      return json({ error: "Invalid budget or duration" }, 400);
    }

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const now = new Date();
    const endsAt = new Date(now.getTime() + duration_days * 86_400_000);

    // Branch: standalone creative ad vs. host boost. advertiser_account_id present
    // ⇒ standalone; otherwise fall through to the legacy event-boost path.
    if (body.advertiser_account_id) {
      return await createStandaloneAd(admin, user.id, body, now, endsAt);
    }
    return await createHostBoost(admin, user.id, body, now, endsAt);
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});

// ── Host boost (A-2) — unchanged behavior ────────────────────────────────────
async function createHostBoost(
  admin: ReturnType<typeof createClient>,
  userId: string,
  body: any,
  now: Date,
  endsAt: Date,
) {
  const { event_id, budget_cents, duration_days } = body;
  if (!event_id) return json({ error: "Missing event_id" }, 400);

  const { data: ev } = await admin
    .from("events")
    .select("id, host_id, title, status")
    .eq("id", event_id)
    .maybeSingle();
  if (!ev) return json({ error: "Event not found" }, 404);
  if (ev.host_id !== userId) return json({ error: "Not your event" }, 403);
  if (ev.status === "ended") return json({ error: "Event has ended" }, 409);

  const { data: campaign, error: campErr } = await admin
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
    line_items: [{
      price_data: {
        currency: "usd",
        unit_amount: budget_cents,
        product_data: { name: `Boost “${ev.title}” (${duration_days} days)` },
      },
      quantity: 1,
    }],
    mode: "payment",
    success_url: `${Deno.env.get("AD_SUCCESS_URL")}?campaign_id=${campaign.id}&session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${Deno.env.get("AD_CANCEL_URL")}?event=${event_id}`,
    // standalone:"0" ⇒ webhook activates immediately.
    metadata: { type: "ad_campaign", standalone: "0", campaign_id: campaign.id },
  });

  await admin.from("ad_campaigns")
    .update({ stripe_payment_intent_id: session.id })
    .eq("id", campaign.id);

  return json({ checkout_url: session.url });
}

// ── Standalone creative ad (A-4 Part 2) ──────────────────────────────────────
async function createStandaloneAd(
  admin: ReturnType<typeof createClient>,
  userId: string,
  body: any,
  now: Date,
  endsAt: Date,
) {
  const {
    advertiser_account_id, headline, body: adBody, click_url, image_url,
    topic_ids, budget_cents, duration_days,
    creative_kind, video_url, thumb_url, duration_ms,
  } = body;
  const isVideo = creative_kind === "video"; // Currents video ad (0068)

  // Validate creative fields. Body is required for image creatives, optional
  // for video (the video carries the message).
  const hl = (headline ?? "").trim();
  const bd = (adBody ?? "").trim();
  if (!hl || hl.length > HEADLINE_MAX) return json({ error: "Invalid headline" }, 400);
  if (bd.length > BODY_MAX) return json({ error: "Invalid body" }, 400);
  if (!isVideo && !bd) return json({ error: "Invalid body" }, 400);
  if (!isVideo && !image_url) return json({ error: "Missing creative image" }, 400);
  let url: URL;
  try { url = new URL(click_url); } catch { return json({ error: "Invalid click URL" }, 400); }
  if (url.protocol !== "https:") return json({ error: "Click URL must be https" }, 400);
  const topics: string[] = Array.isArray(topic_ids) ? topic_ids.filter(Boolean) : [];

  // Video-specific validation (mirrors the 0068 CHECKs so failures are 400s,
  // not opaque insert errors).
  const durMs = Number(duration_ms);
  if (isVideo) {
    if (!video_url) return json({ error: "Missing creative video" }, 400);
    if (!Number.isFinite(durMs) || durMs <= 0 || durMs > 61000) {
      return json({ error: "Video must be 60 seconds or shorter" }, 400);
    }
  }

  // Verify the caller owns this advertiser account.
  const { data: account } = await admin
    .from("advertiser_accounts")
    .select("id, name, auth_user_id")
    .eq("id", advertiser_account_id)
    .maybeSingle();
  if (!account) return json({ error: "Advertiser account not found" }, 404);
  if (account.auth_user_id !== userId) return json({ error: "Not your account" }, 403);

  // Review finding #4: creative assets must point at OUR buckets, inside THIS
  // account's folder (the portal uploads to {account_id}/{uuid}.{ext} — the
  // same convention the buckets' insert RLS enforces). Rejects arbitrary
  // external URLs and other accounts' creatives; manual review stays the
  // content backstop, this closes the abuse hole cheaply.
  const supaBase = Deno.env.get("SUPABASE_URL")!.replace(/\/$/, "");
  const creativePrefix =
    `${supaBase}/storage/v1/object/public/ad-creatives/${advertiser_account_id}/`;
  const videoPrefix =
    `${supaBase}/storage/v1/object/public/ad-videos/${advertiser_account_id}/`;
  let videoPath: string | null = null;
  let thumbPath: string | null = null;
  if (isVideo) {
    if (typeof video_url !== "string" || !video_url.startsWith(videoPrefix)) {
      return json({ error: "Creative video must be uploaded through the portal" }, 400);
    }
    // ad_creatives stores bucket-relative paths for video assets — i.e.
    // "{account_id}/{uuid}.mp4", everything after "/ad-videos/" (the app
    // rebuilds public URLs from the ad-videos bucket).
    videoPath = decodeURIComponent(video_url.split("/ad-videos/")[1]);
    if (typeof thumb_url === "string" && thumb_url.startsWith(videoPrefix)) {
      thumbPath = decodeURIComponent(thumb_url.split("/ad-videos/")[1]);
    }
  } else if (typeof image_url !== "string" || !image_url.startsWith(creativePrefix)) {
    return json({ error: "Creative image must be uploaded through the portal" }, 400);
  }

  // Create campaign (advertiser_id null; owned via advertiser_account_id).
  const { data: campaign, error: campErr } = await admin
    .from("ad_campaigns")
    .insert({
      advertiser_account_id,
      name: hl,
      pricing_model: "flat",
      budget_cents,
      starts_at: now.toISOString(),
      ends_at: endsAt.toISOString(),
      status: "pending_payment",
    })
    .select("id")
    .single();
  if (campErr || !campaign) {
    console.error(campErr);
    return json({ error: "Could not create campaign" }, 500);
  }

  // Creative + targeting. On failure, roll back the campaign so no orphan sits in
  // pending_payment forever (get_feed_ads already guards creative-less rows, but
  // cleanliness matters for the review queue).
  const { error: crErr } = await admin.from("ad_creatives").insert(
    isVideo
      ? {
          campaign_id: campaign.id,
          kind: "video",
          video_path: videoPath,
          thumb_path: thumbPath,
          duration_ms: Math.round(durMs),
          headline: hl,
          body: bd || null,
          click_url,
        }
      : {
          campaign_id: campaign.id,
          image_url,
          headline: hl,
          body: bd,
          click_url,
        },
  );
  if (crErr) {
    await admin.from("ad_campaigns").delete().eq("id", campaign.id);
    console.error(crErr);
    return json({ error: "Could not save creative" }, 500);
  }

  const { error: tgErr } = await admin.from("ad_targeting").insert({
    campaign_id: campaign.id,
    topic_ids: topics, // empty ⇒ broad targeting (intended fallback)
  });
  if (tgErr) {
    await admin.from("ad_creatives").delete().eq("campaign_id", campaign.id);
    await admin.from("ad_campaigns").delete().eq("id", campaign.id);
    console.error(tgErr);
    return json({ error: "Could not save targeting" }, 500);
  }

  const session = await stripe.checkout.sessions.create({
    payment_method_types: ["card"],
    line_items: [{
      price_data: {
        currency: "usd",
        unit_amount: budget_cents,
        product_data: { name: `Nile ad: “${hl}” (${duration_days} days)` },
      },
      quantity: 1,
    }],
    mode: "payment",
    // Authorize only — the review-ad-campaign fn captures on approve or cancels
    // on reject. Host boosts (no review step) keep automatic capture.
    payment_intent_data: { capture_method: "manual" },
    // Standalone checkout returns into the advertiser portal (not the host-boost
    // page). AD_PORTAL_URL defaults to https://ads.joinnile.com.
    success_url: `${portalUrl()}?campaign_id=${campaign.id}&session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: portalUrl(),
    // standalone:"1" ⇒ webhook flips to pending_review (human approval), not active.
    metadata: { type: "ad_campaign", standalone: "1", campaign_id: campaign.id },
  });

  await admin.from("ad_campaigns")
    .update({ stripe_payment_intent_id: session.id })
    .eq("id", campaign.id);

  return json({ checkout_url: session.url });
}

