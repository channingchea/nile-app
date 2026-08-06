// Supabase Edge Function: create-ad-payment
//
// Handles THREE checkout paths, all on the web ad portal — never in-app — so
// no iOS IAP:
//
//   1) HOST BOOST (A-2).  { event_id, budget_cents, duration_days }
//      Host boosts their own event. Campaign → active on payment (webhook).
//      Platform-ward (no Connect split).
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
//      Platform-ward (no Connect split).
//
//   3) EVENT SPONSORSHIP (0079 — Pre-Show lobby).
//      { advertiser_account_id, placement: "lobby", event_id, headline,
//        body?, click_url, image_url | (creative_kind:"video" + video_url,
//        thumb_url?, duration_ms) }
//      Brand sponsors a host's upcoming event; the creative plays in the
//      Pre-Show lobby. Price is server-derived from app_config (free vs
//      ticketed event tier) — the client sends no amount. Same manual-capture
//      review flow as (2), but as a Connect DESTINATION CHARGE: the host's
//      70% (app_config.sponsorship_host_share) transfers to their Connect
//      account at capture, the platform keeps application_fee_amount. Host
//      must be payable (charges_enabled) — no platform-fallback: don't sell
//      what you can't split. Event must be opted in (events.sponsorship_open),
//      still 'scheduled', ≥24h out (review window), and not already sponsored
//      (partial unique index locks the event on first purchase).
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

// CORS headers are per-request, so the JSON responder is built per-request too
// and handed to the helpers below (they run outside the handler's scope).
type Json = (body: unknown, status?: number) => Response;
const makeJson = (cors: Record<string, string>): Json =>
  (body, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

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
  const json = makeJson(corsHeaders);
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

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Event sponsorship (lobby placement): price comes from app_config, not
    // the client, so it skips the preset budget/duration validation entirely.
    if (body.placement === "lobby") {
      return await createSponsorship(admin, user.id, body, json);
    }

    const { budget_cents, duration_days } = body;
    if (!ALLOWED_BUDGETS.has(budget_cents) || !ALLOWED_DURATIONS.has(duration_days)) {
      return json({ error: "Invalid budget or duration" }, 400);
    }

    const now = new Date();
    const endsAt = new Date(now.getTime() + duration_days * 86_400_000);

    // Branch: standalone creative ad vs. host boost. advertiser_account_id present
    // ⇒ standalone; otherwise fall through to the legacy event-boost path.
    if (body.advertiser_account_id) {
      return await createStandaloneAd(admin, user.id, body, now, endsAt, json);
    }
    return await createHostBoost(admin, user.id, body, now, endsAt, json);
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
  json: Json,
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

// ── Shared creative validation (standalone ads + sponsorships) ───────────────
// Returns the validated/normalized creative, or a Response (already-built 4xx)
// on failure. Body is required for image creatives, optional for video (the
// video carries the message). Review finding #4: creative assets must point at
// OUR buckets, inside THIS account's folder (the portal uploads to
// {account_id}/{uuid}.{ext} — the same convention the buckets' insert RLS
// enforces). Rejects arbitrary external URLs and other accounts' creatives;
// manual review stays the content backstop.
type Creative = {
  isVideo: boolean;
  hl: string;
  bd: string;
  click_url: string;
  image_url: string | null;
  videoPath: string | null;
  thumbPath: string | null;
  durMs: number;
};
function validateCreative(accountId: string, body: any, json: Json): Creative | Response {
  const { headline, body: adBody, click_url, image_url, creative_kind, video_url, thumb_url, duration_ms } = body;
  const isVideo = creative_kind === "video";

  const hl = (headline ?? "").trim();
  const bd = (adBody ?? "").trim();
  if (!hl || hl.length > HEADLINE_MAX) return json({ error: "Invalid headline" }, 400);
  if (bd.length > BODY_MAX) return json({ error: "Invalid body" }, 400);
  if (!isVideo && !bd) return json({ error: "Invalid body" }, 400);
  if (!isVideo && !image_url) return json({ error: "Missing creative image" }, 400);
  let url: URL;
  try { url = new URL(click_url); } catch { return json({ error: "Invalid click URL" }, 400); }
  if (url.protocol !== "https:") return json({ error: "Click URL must be https" }, 400);

  // Video-specific validation (mirrors the 0068 CHECKs so failures are 400s,
  // not opaque insert errors).
  const durMs = Number(duration_ms);
  if (isVideo) {
    if (!video_url) return json({ error: "Missing creative video" }, 400);
    if (!Number.isFinite(durMs) || durMs <= 0 || durMs > 61000) {
      return json({ error: "Video must be 60 seconds or shorter" }, 400);
    }
  }

  const supaBase = Deno.env.get("SUPABASE_URL")!.replace(/\/$/, "");
  const creativePrefix =
    `${supaBase}/storage/v1/object/public/ad-creatives/${accountId}/`;
  const videoPrefix =
    `${supaBase}/storage/v1/object/public/ad-videos/${accountId}/`;
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

  return { isVideo, hl, bd, click_url, image_url: isVideo ? null : image_url, videoPath, thumbPath, durMs };
}

// Insert the ad_creatives row for a validated creative. Returns the insert error.
// deno-lint-ignore no-explicit-any
function insertCreative(admin: any, campaignId: string, cr: Creative) {
  return admin.from("ad_creatives").insert(
    cr.isVideo
      ? {
          campaign_id: campaignId,
          kind: "video",
          video_path: cr.videoPath,
          thumb_path: cr.thumbPath,
          duration_ms: Math.round(cr.durMs),
          headline: cr.hl,
          body: cr.bd || null,
          click_url: cr.click_url,
        }
      : {
          campaign_id: campaignId,
          image_url: cr.image_url,
          headline: cr.hl,
          body: cr.bd,
          click_url: cr.click_url,
        },
  );
}

// ── Standalone creative ad (A-4 Part 2) ──────────────────────────────────────
async function createStandaloneAd(
  admin: ReturnType<typeof createClient>,
  userId: string,
  body: any,
  now: Date,
  endsAt: Date,
  json: Json,
) {
  const { advertiser_account_id, topic_ids, budget_cents, duration_days } = body;

  const creative = validateCreative(advertiser_account_id, body, json);
  if (creative instanceof Response) return creative;
  const { hl } = creative;
  const topics: string[] = Array.isArray(topic_ids) ? topic_ids.filter(Boolean) : [];

  // Verify the caller owns this advertiser account.
  const { data: account } = await admin
    .from("advertiser_accounts")
    .select("id, name, auth_user_id")
    .eq("id", advertiser_account_id)
    .maybeSingle();
  if (!account) return json({ error: "Advertiser account not found" }, 404);
  if (account.auth_user_id !== userId) return json({ error: "Not your account" }, 403);

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
  const { error: crErr } = await insertCreative(admin, campaign.id, creative);
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

// ── Event sponsorship (0079 — Pre-Show lobby) ────────────────────────────────
// deno-lint-ignore no-explicit-any
async function createSponsorship(admin: any, userId: string, body: any, json: Json) {
  const { advertiser_account_id, event_id } = body;
  if (!advertiser_account_id || !event_id) {
    return json({ error: "Missing advertiser_account_id or event_id" }, 400);
  }

  const creative = validateCreative(advertiser_account_id, body, json);
  if (creative instanceof Response) return creative;

  // Verify the caller owns this advertiser account.
  const { data: account } = await admin
    .from("advertiser_accounts")
    .select("id, name, auth_user_id")
    .eq("id", advertiser_account_id)
    .maybeSingle();
  if (!account) return json({ error: "Advertiser account not found" }, 404);
  if (account.auth_user_id !== userId) return json({ error: "Not your account" }, 403);

  // Event eligibility — server-side, mirroring get_sponsorable_events.
  const { data: ev } = await admin
    .from("events")
    .select("id, host_id, title, status, scheduled_at, price, removed_at, sponsorship_open")
    .eq("id", event_id)
    .maybeSingle();
  if (!ev || ev.removed_at) return json({ error: "Event not found" }, 404);
  if (!ev.sponsorship_open) return json({ error: "Event is not open to sponsorship" }, 409);
  if (ev.status !== "scheduled") return json({ error: "Event is no longer sponsorable" }, 409);
  if (!ev.scheduled_at || new Date(ev.scheduled_at).getTime() < Date.now() + 24 * 3_600_000) {
    return json({ error: "Events must be at least 24 hours out to be sponsored" }, 409);
  }

  // Host must be payable (Connect destination charge — no platform fallback:
  // don't sell what you can't split). Same live check as create-tip-payment.
  const { data: hostProfile } = await admin
    .from("profiles")
    .select("stripe_account_id")
    .eq("id", ev.host_id)
    .maybeSingle();
  const hostAccountId = hostProfile?.stripe_account_id as string | null;
  if (!hostAccountId) return json({ error: "host_not_payable" }, 409);
  const hostAccount = await stripe.accounts.retrieve(hostAccountId);
  if (!hostAccount.charges_enabled) return json({ error: "host_not_payable" }, 409);

  // Price + split are server-derived from config and FROZEN on the campaign row
  // (same pattern as tickets): retuning config never changes a sold sponsorship.
  const { data: cfg } = await admin
    .from("app_config")
    .select("sponsorship_price_free_cents, sponsorship_price_ticketed_cents, sponsorship_host_share")
    .eq("id", 1)
    .maybeSingle();
  const ticketed = ev.price != null && ev.price > 0;
  const price = Number(
    (ticketed ? cfg?.sponsorship_price_ticketed_cents : cfg?.sponsorship_price_free_cents) ??
      (ticketed ? 5000 : 2500),
  );
  const hostShare = Number(cfg?.sponsorship_host_share ?? 0.70);
  const fee = Math.round(price * (1 - hostShare)); // platform's cut

  // The flight is the event itself; starts_at/ends_at are informational (lobby
  // campaigns are excluded from tally_ad_spend's daily burn / auto-complete).
  const now = new Date();
  const endsAt = new Date(new Date(ev.scheduled_at).getTime() + 24 * 3_600_000);

  // Insert locks the event: the 0079 partial unique index rejects a second
  // in-pipeline lobby campaign for the same event.
  const { data: campaign, error: campErr } = await admin
    .from("ad_campaigns")
    .insert({
      advertiser_account_id,
      name: `Sponsor: ${ev.title}`,
      event_id,
      placement: "lobby",
      pricing_model: "flat",
      budget_cents: price,
      application_fee_cents: fee,
      split_status: "split",
      starts_at: now.toISOString(),
      ends_at: endsAt.toISOString(),
      status: "pending_payment",
    })
    .select("id")
    .single();
  if (campErr || !campaign) {
    if (campErr?.code === "23505") {
      return json({ error: "This event already has a sponsor" }, 409);
    }
    console.error(campErr);
    return json({ error: "Could not create campaign" }, 500);
  }

  const { error: crErr } = await insertCreative(admin, campaign.id, creative);
  if (crErr) {
    await admin.from("ad_campaigns").delete().eq("id", campaign.id);
    console.error(crErr);
    return json({ error: "Could not save creative" }, 500);
  }
  // No ad_targeting row: a sponsorship targets one event, not topics.

  const session = await stripe.checkout.sessions.create({
    payment_method_types: ["card"],
    line_items: [{
      price_data: {
        currency: "usd",
        unit_amount: price,
        product_data: { name: `Sponsor “${ev.title}”` },
      },
      quantity: 1,
    }],
    mode: "payment",
    // Authorize only (review gate), as a Connect destination charge: capture
    // (in review-ad-campaign, on approval) moves the host's share atomically.
    payment_intent_data: {
      capture_method: "manual",
      application_fee_amount: fee,
      transfer_data: { destination: hostAccountId },
    },
    success_url: `${portalUrl()}?campaign_id=${campaign.id}&session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: portalUrl(),
    // standalone:"1" ⇒ the webhook flips to pending_review (human approval).
    metadata: { type: "ad_campaign", standalone: "1", placement: "lobby", campaign_id: campaign.id },
  });

  await admin.from("ad_campaigns")
    .update({ stripe_payment_intent_id: session.id })
    .eq("id", campaign.id);

  return json({ checkout_url: session.url });
}

