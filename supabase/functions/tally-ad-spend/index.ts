// Supabase Edge Function: tally-ad-spend
//
// Phase A-3 — reporting & budget enforcement. Cron-invoked nightly. Calls the
// tally_ad_spend() RPC, which recomputes spent_cents from ad_events per pricing
// model and flips campaigns to 'completed' once their budget is exhausted or
// their flight window has ended. Idempotent (spend is derived, not incremented),
// so overlapping or replayed runs converge to the same value.
//
// Also fires a "Nile Ads Awaiting Review" digest (Part 2 of the hardening
// plan) when anything has sat in pending_review for more than 3 days, OR
// when there's at least one open/reviewing moderation report (Reported-
// Content Review Page, Phase 4) — same digest, same cadence, one fewer thing
// to check separately every morning. Env-gated on KLAVIYO_API_KEY +
// ADMIN_ALERT_EMAIL (shared with stripe-webhook's needs-review alert);
// no-ops cleanly if either is unset.
//
// A second, much faster path lives here too, selected by {"mode":"lobby-aging"}
// in the request body (or ?mode=lobby-aging): sponsorship offers run on a 72h
// fuse, so a lobby creative sitting unscreened for 12h needs an alert now, not
// in tomorrow's digest. It also runs the clock-driven offer sweep (so an offer
// never stays dead-but-open longer than two hours) and the two host-inaction
// defences: the 6h "you have an offer waiting" email and the 24-hours-left
// push. Same deployed function, second cron entry — a whole function for one
// query would be infrastructure for its own sake. The nightly run still does
// everything it always did; this path is additive.
//
// Setup:
//   supabase functions deploy tally-ad-spend --no-verify-jwt
//   (invoked by Supabase Cron with the service-role key — see CRON below)
//
// CRON (nightly at 03:10 UTC — off-peak; once a day is plenty for flat boosts):
//   select cron.schedule(
//     'tally-ad-spend',
//     '10 3 * * *',
//     $$
//       select net.http_post(
//         url     := 'https://<PROJECT_REF>.functions.supabase.co/tally-ad-spend',
//         headers := jsonb_build_object(
//           'Content-Type',  'application/json',
//           'Authorization', 'Bearer ' || '<SERVICE_ROLE_KEY>'
//         )
//       );
//     $$
//   );
//
// CRON (every 2 hours — lobby review aging only; skips the tally entirely):
//   select cron.schedule(
//     'tally-ad-spend-lobby-aging',
//     '5 */2 * * *',
//     $$
//       select net.http_post(
//         url     := 'https://<PROJECT_REF>.functions.supabase.co/tally-ad-spend',
//         headers := jsonb_build_object(
//           'Content-Type',  'application/json',
//           'Authorization', 'Bearer ' || '<SERVICE_ROLE_KEY>'
//         ),
//         body    := jsonb_build_object('mode', 'lobby-aging')
//       );
//     $$
//   );

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14?target=deno";
import {
  dollars,
  expireRecoverySession,
  formatWhen,
  klaviyoEvent,
} from "../_shared/sponsorship.ts";
import { failure } from "../_shared/errors.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
  httpClient: Stripe.createFetchHttpClient(),
});

serve(async (req) => {
  try {
    // Auth: cron proves it's us with a shared secret. This function is deployed
    // --no-verify-jwt, so without this gate anyone who knows the URL (it's in
    // 0085's committed migration body) could drive live Stripe refund/cancel
    // calls, the offer-expiry sweep, the abandoned-checkout delete, and every
    // Klaviyo + FCM send. Same pattern as send-push. The cron side ships the
    // header in migration 0103; the secret's twin lives in Vault.
    const expected = Deno.env.get("CRON_SHARED_SECRET");
    if (!expected || req.headers.get("x-cron-secret") !== expected) {
      return new Response(JSON.stringify({ error: "unauthorized" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    if (await isLobbyAgingRun(req)) {
      // The offer sweep rides along on this cadence too. Every one of its
      // transitions is a status-guarded flip, so running it twelve times a day
      // is free — and on the nightly clock alone an offer could sit dead for
      // most of a day after the moment it should have expired. Sweep first,
      // then alert, so the digest never names an offer we just expired.
      const offers = await sweepOffers(admin);
      // Host-inaction defences run AFTER the sweep: an offer that just expired
      // must not then be emailed about or nudged.
      const waiting = await emailWaitingOffers(admin);
      const nudged = await nudgeExpiringOffers(admin);
      return json({
        ok: true,
        ...offers,
        offers_waiting_emailed: waiting,
        offers_expiring_nudged: nudged,
        ...(await checkAgingLobbyOffers(admin)),
      });
    }

    const { data, error } = await admin.rpc("tally_ad_spend");
    if (error) return json({ error: error.message }, 500);

    // RPC returns a single { updated, completed } row.
    const row = Array.isArray(data) ? data[0] : data;

    // Review-SLA aging digest (Part 2 of the hardening plan). Piggybacks on
    // this fn's existing nightly cron rather than adding new infra.
    await checkAgingReviews(admin);

    // Sponsorship housekeeping: refund queue drained, dead offers expired.
    const refunds = await sweepSponsorships(admin);
    const offers = await sweepOffers(admin);

    return json({
      ok: true,
      updated: row?.updated ?? 0,
      completed: row?.completed ?? 0,
      sponsorship_refunds: refunds,
      ...offers,
    });
  } catch (err) {
    console.error(err);
    return json(failure(err, "tally-ad-spend"), 500);
  }
});

// ── Sponsorship refund sweep ─────────────────────────────────────────────────
// Event-death triggers (delete / cancel / never-started) enqueue rows in
// sponsorship_refunds; the DB can't call Stripe, so the money work happens
// here.
//
// On the STATUS paths the queue only ever receives CHARGED campaigns:
// sponsorship_on_event_status() enqueues from status = 'active', and under the
// offer model a lobby row only reaches 'active' by an accepted, confirmed
// PaymentIntent. Every uncharged status (pending_payment / pending_review /
// pending_host / payment_pending) is flipped straight to 'expired' by the same
// trigger with no refund row, because there is nothing to give back.
//
// The DELETE path is the exception (0124). A hard-deleted event cascade-deletes
// its campaign, so 'expired' has nowhere to live and review_note can never be
// read again — the advertiser would simply never hear. Those rows arrive here
// under reason 'event_deleted_uncharged': notify only, no Stripe call.
//
// The old "events that never started" block used to live here; migration 0084's
// auto_end_expired_events cron flips those to 'ended' within five minutes, and
// 0086/0096's trigger enqueues them from there. Nothing reaches this function
// that the trigger hasn't already seen.
//
// Never throws: a Stripe failure marks the row 'failed' for the next run.
// deno-lint-ignore no-explicit-any
async function sweepSponsorships(admin: any): Promise<number> {
  let processed = 0;
  try {
    const dayAgo = new Date(Date.now() - 86_400_000).toISOString();

    // Process the queue: cancel an uncaptured hold, refund a captured split.
    const { data: due } = await admin
      .from("sponsorship_refunds")
      .select("id, campaign_id, advertiser_account_id, stripe_payment_intent_id, split_status, event_title, reason")
      .eq("status", "due");
    // deno-lint-ignore no-explicit-any
    for (const r of (due ?? []) as any[]) {
      const piId = r.stripe_payment_intent_id as string | null;
      let ok = true;
      let note: string | null = null;
      try {
        if (r.reason === "event_deleted_uncharged") {
          // 0124: the offer never reached 'active', so nothing was ever
          // charged. The row exists only to carry the notification past the
          // cascade that deleted the campaign along with its event — there is
          // no Stripe object here to cancel, and asking would 404.
          note = "no charge was made";
        } else if (piId?.startsWith("pi_")) {
          const pi = await stripe.paymentIntents.retrieve(piId);
          if (pi.status === "requires_capture") {
            await stripe.paymentIntents.cancel(piId);
            note = "authorization cancelled";
          } else if (pi.status === "succeeded") {
            await stripe.refunds.create(
              r.split_status === "split"
                ? { payment_intent: piId, reverse_transfer: true, refund_application_fee: true }
                : { payment_intent: piId },
            );
            note = "payment refunded";
          } else {
            note = `no money to move (pi status ${pi.status})`;
          }
        } else {
          note = "no PaymentIntent on record";
        }
      } catch (err) {
        ok = false;
        note = String(err).slice(0, 300);
        console.error("sponsorship refund failed:", r.id, err);
      }
      await admin
        .from("sponsorship_refunds")
        .update({
          status: ok ? "done" : "failed",
          note,
          processed_at: new Date().toISOString(),
        })
        .eq("id", r.id);
      if (ok) {
        processed++;
        await notifySponsorRefunded(admin, r);
      }
    }

    // Abandoned checkouts: Checkout Sessions expire after 24h, so a lobby row
    // still in pending_payment with no saved card never will get one. The
    // payment-method guard is the whole test now — a completed setup flips the
    // row out of pending_payment, so anything left here is genuinely dead.
    // (Nothing to release: setup mode never authorized a cent. The creative
    // cascade-deletes.)
    await admin
      .from("ad_campaigns")
      .delete()
      .eq("placement", "lobby")
      .eq("status", "pending_payment")
      .is("stripe_payment_method_id", null)
      .lt("created_at", dayAgo);
  } catch (err) {
    console.error("sponsorship sweep error:", err);
  }
  return processed;
}

// Tell the advertiser their sponsorship was refunded/released. Reuses the
// "Nile Ad Rejected" metric (the existing flow carries a reason string), so no
// new Klaviyo flow is needed. Env-gated on KLAVIYO_API_KEY; never throws.
const REFUND_REASONS: Record<string, string> = {
  event_deleted: "The event was removed by its host — your payment has been refunded.",
  event_cancelled: "The event was cancelled — your payment has been refunded.",
  not_approved_in_time: "The event started before this sponsorship could be reviewed. Your card was not charged.",
  event_never_started: "The event never started — your payment has been refunded.",
  event_deleted_uncharged:
    "The event was removed by its host before your offer was accepted. You were not charged.",
};
// deno-lint-ignore no-explicit-any
async function notifySponsorRefunded(admin: any, r: any) {
  try {
    const key = Deno.env.get("KLAVIYO_API_KEY");
    if (!key || !r.advertiser_account_id) return;
    const { data: acct } = await admin
      .from("advertiser_accounts")
      .select("name, contact_email")
      .eq("id", r.advertiser_account_id)
      .maybeSingle();
    const to = acct?.contact_email as string | undefined;
    if (!to) return;
    const payload = {
      data: {
        type: "event",
        attributes: {
          unique_id: `${r.campaign_id}:sponsorship_refund`,
          properties: {
            brand: acct?.name ?? "there",
            headline: r.event_title ? `Sponsorship: ${r.event_title}` : "Your event sponsorship",
            campaign_id: r.campaign_id,
            reason: REFUND_REASONS[r.reason as string] ?? "Your payment has been refunded.",
            dashboard_url: "https://ads.joinnile.com/advertise/portal",
          },
          metric: { data: { type: "metric", attributes: { name: "Nile Ad Rejected" } } },
          profile: { data: { type: "profile", attributes: { email: to } } },
        },
      },
    };
    const res = await fetch("https://a.klaviyo.com/api/events/", {
      method: "POST",
      headers: {
        Authorization: `Klaviyo-API-Key ${key}`,
        revision: "2024-10-15",
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(payload),
    });
    if (!res.ok) console.error("sponsor refund notify failed:", res.status, await res.text());
  } catch (err) {
    console.error("sponsor refund notify error:", err);
  }
}

// Fires one "Nile Ads Awaiting Review" digest if anything has sat in
// pending_review for more than 3 days (half the ~7-day Stripe auth window)
// OR there's at least one open/reviewing moderation report. Fire-and-forget:
// never fails the tally response.
// admin is `any`: supabase-js infers a generated-types schema we don't have,
// and every column access lands on `never` without it.
// deno-lint-ignore no-explicit-any
async function checkAgingReviews(admin: any) {
  try {
    const threeDaysAgo = new Date(Date.now() - 3 * 86_400_000).toISOString();
    const [{ data: aging, error: agingErr }, { count: openReports, error: reportsErr }] = await Promise.all([
      admin
        .from("ad_campaigns")
        .select("created_at")
        .eq("status", "pending_review")
        .lt("created_at", threeDaysAgo)
        .order("created_at", { ascending: true }),
      admin
        .from("reports")
        .select("id", { count: "exact", head: true })
        .in("status", ["open", "reviewing"]),
    ]);
    if (agingErr) console.error("aging review query failed:", agingErr);
    if (reportsErr) console.error("open reports count query failed:", reportsErr);

    const agingList = aging ?? [];
    const openReportCount = openReports ?? 0;
    if (agingList.length === 0 && openReportCount === 0) return;

    const oldestDays = agingList.length
      ? Math.floor((Date.now() - new Date(agingList[0].created_at).getTime()) / 86_400_000)
      : 0;
    await notifyAdminAgingDigest(agingList.length, oldestDays, openReportCount);
  } catch (err) {
    console.error("aging review check error:", err);
  }
}

// Klaviyo digest event. Env-gated on KLAVIYO_API_KEY + ADMIN_ALERT_EMAIL
// (same secret stripe-webhook uses for the needs-review alert): no-ops
// cleanly when either is unset. unique_id keys on today's UTC date so this
// can never send more than once per day even on a retried cron run.
async function notifyAdminAgingDigest(count: number, oldestDays: number, openReports: number) {
  const key = Deno.env.get("KLAVIYO_API_KEY");
  const adminEmail = Deno.env.get("ADMIN_ALERT_EMAIL");
  if (!key || !adminEmail) return;
  const today = new Date().toISOString().slice(0, 10);
  const payload = {
    data: {
      type: "event",
      attributes: {
        unique_id: `${today}:pending_digest`,
        properties: {
          count,
          oldest_days: oldestDays,
          open_reports: openReports,
          portal_url: "https://ads.joinnile.com/advertise/portal?view=review",
          reports_url: "https://ads.joinnile.com/advertise/portal?view=reports",
        },
        metric: { data: { type: "metric", attributes: { name: "Nile Ads Awaiting Review" } } },
        profile: { data: { type: "profile", attributes: { email: adminEmail } } },
      },
    },
  };
  try {
    const res = await fetch("https://a.klaviyo.com/api/events/", {
      method: "POST",
      headers: {
        Authorization: `Klaviyo-API-Key ${key}`,
        revision: "2024-10-15",
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(payload),
    });
    if (!res.ok) console.error("aging digest event failed:", res.status, await res.text());
  } catch (err) {
    console.error("aging digest event error:", err);
  }
}

// ── Offer lifecycle sweep (0095–0097) ────────────────────────────────────────
// Three ways an offer runs out of road, none of which any trigger can see —
// they're all clock-driven, and Postgres has no clock of its own.
// deno-lint-ignore no-explicit-any
async function sweepOffers(admin: any) {
  const nowIso = new Date().toISOString();
  const screenBy = new Date(Date.now() + 24 * 3_600_000).toISOString();
  try {
    return {
      // The host never answered.
      expired_offers: await expireOffers(
        admin, "pending_host", "offer_expires_at", nowIso,
        "The host didn't respond before this offer expired. You were not charged.",
      ),
      // The 6h recovery window for a soft card decline closed.
      expired_payment_pending: await expireOffers(
        admin, "payment_pending", "payment_retry_until", nowIso,
        "We couldn't complete the payment in time, so this offer expired. You were not charged.",
      ),
      // We ran out of time to screen it. An offer must never die silently in
      // our own queue — expiring it a day before it would have lapsed leaves
      // the advertiser room to spend the money somewhere else.
      expired_unscreened: await expireOffers(
        admin, "pending_review", "offer_expires_at", screenBy,
        "We couldn't review this sponsorship in time for the event. You were not charged.",
      ),
    };
  } catch (err) {
    console.error("offer sweep error:", err);
    return { expired_offers: 0, expired_payment_pending: 0, expired_unscreened: 0 };
  }
}

// Flip every lobby row of `fromStatus` whose `col` is already behind `cutoff`,
// and tell its advertiser why. Status-guarded by construction: the UPDATE's own
// WHERE is the guard, so a host accepting mid-sweep simply wins.
// deno-lint-ignore no-explicit-any
async function expireOffers(
  admin: any, fromStatus: string, col: string, cutoff: string, reason: string,
): Promise<number> {
  const { data: rows, error } = await admin
    .from("ad_campaigns")
    .update({ status: "expired", review_note: reason, payment_recovery_url: null })
    .eq("placement", "lobby")
    .eq("status", fromStatus)
    .lt(col, cutoff)
    .select("id, budget_cents, stripe_payment_intent_id, advertiser_accounts(name, contact_email), events(title)");
  if (error) { console.error(`expire ${fromStatus} failed:`, error); return 0; }
  // deno-lint-ignore no-explicit-any
  for (const r of (rows ?? []) as any[]) {
    // A payment_pending row's recovery link is already in someone's inbox;
    // clearing the column doesn't make the Stripe session unpayable, expiring
    // it does. The webhook's status guard is the backstop if this fails.
    await expireRecoverySession(r.stripe_payment_intent_id);
    await klaviyoEvent(
      "Nile Sponsorship Offer Expired",
      r.advertiser_accounts?.contact_email,
      `${r.id}:offer_expired`,
      {
        brand: r.advertiser_accounts?.name ?? "there",
        event_title: r.events?.title ?? "an event",
        amount: dollars(r.budget_cents),
        amount_cents: r.budget_cents,
        campaign_id: r.id,
        // Already a complete human sentence — the email renders it verbatim.
        reason,
      },
    );
  }
  return rows?.length ?? 0;
}

// ── Host-inaction defence 1: the 6h email fallback (Phase 7) ─────────────────
// An offer sitting untouched 6h after Nile cleared it gets one email to the
// host's auth address. This one deliberately ignores notification_preferences:
// the hosts most likely to miss an offer are the ones who turned push off, and
// expiry — not the host's inbox settings — is what costs the advertiser money.
//
// There is no cleared_at column, so clearance is derived: ad_admin_audit's
// 'approve' row is the exact moment for a screened offer, and for a trusted
// advertiser (cleared by the webhook the instant checkout completes, with no
// audit row) the campaign's own created_at is within a minute of it. Send-once
// is enforced by Klaviyo's unique_id, not by a column — which is why this can
// run every two hours without turning into a drip campaign.
// deno-lint-ignore no-explicit-any
async function emailWaitingOffers(admin: any): Promise<number> {
  try {
    const { data: rows, error } = await admin
      .from("ad_campaigns")
      .select(
        "id, created_at, budget_cents, offer_expires_at, event_id, " +
          "advertiser_accounts(name), events(title, host_id), " +
          "ad_creatives(kind, image_url, thumb_path)",
      )
      .eq("placement", "lobby")
      .eq("status", "pending_host");
    if (error) { console.error("waiting offers query failed:", error); return 0; }
    // deno-lint-ignore no-explicit-any
    const list = (rows ?? []) as any[];
    if (list.length === 0) return 0;

    // One batched lookup rather than a query per offer.
    const { data: audits } = await admin
      .from("ad_admin_audit")
      .select("campaign_id, created_at")
      .eq("action", "approve")
      .in("campaign_id", list.map((r) => r.id));
    const clearedAt = new Map<string, number>();
    // deno-lint-ignore no-explicit-any
    for (const a of (audits ?? []) as any[]) {
      const t = new Date(a.created_at).getTime();
      const prev = clearedAt.get(a.campaign_id);
      if (prev === undefined || t > prev) clearedAt.set(a.campaign_id, t);
    }

    const { data: cfg } = await admin
      .from("app_config").select("sponsorship_host_share").eq("id", 1).maybeSingle();
    const hostShare = Number(cfg?.sponsorship_host_share ?? 0.70);
    const cutoff = Date.now() - 6 * 3_600_000;

    let sent = 0;
    for (const r of list) {
      const cleared = clearedAt.get(r.id) ?? new Date(r.created_at).getTime();
      if (cleared > cutoff) continue;
      const hostId = r.events?.host_id as string | undefined;
      if (!hostId) continue;
      const { data: userData } = await admin.auth.admin.getUserById(hostId);
      const to = userData?.user?.email as string | undefined;
      if (!to) continue;

      const amount = Number(r.budget_cents ?? 0);
      const deepLink = r.event_id ? `https://links.joinnile.com/e/${r.event_id}` : null;
      await klaviyoEvent("Nile Sponsorship Offer Waiting", to, `${r.id}:offer_waiting`, {
        brand: r.advertiser_accounts?.name ?? "A brand",
        event_title: r.events?.title ?? "your event",
        amount: dollars(amount),
        amount_cents: amount,
        host_net: dollars(Math.round(amount * hostShare)),
        thumbnail_url: creativeThumbUrl(r.ad_creatives?.[0]),
        offer_expires_at: formatWhen(r.offer_expires_at),
        offer_expires_at_iso: r.offer_expires_at,
        deep_link: deepLink,
        // Overrides klaviyoEvent's advertiser-portal default: nothing in a
        // host email should point at the advertiser dashboard.
        dashboard_url: deepLink,
        campaign_id: r.id,
      });
      sent++;
    }
    return sent;
  } catch (err) {
    console.error("waiting offer email error:", err);
    return 0;
  }
}

// ── Host-inaction defence 2: the 24-hours-left nudge (Phase 7) ───────────────
// In-app + push, so this one DOES respect notification_preferences — unlike the
// email above, it isn't the last line of defence.
//
// Migration 0090's partial unique indexes (event_live, event_ended,
// event_starting, event_no_show, replay_ready, replay_price_prompt,
// soundcheck_open, feedback_resolved) don't cover sponsorship_offer_expiring,
// so the "already nudged?" check is done by hand. It's a read per offer inside
// a 24h window, which is a handful of rows at most.
// deno-lint-ignore no-explicit-any
async function nudgeExpiringOffers(admin: any): Promise<number> {
  try {
    const nowIso = new Date().toISOString();
    const soon = new Date(Date.now() + 24 * 3_600_000).toISOString();
    const { data: rows, error } = await admin
      .from("ad_campaigns")
      .select("id, events(host_id)")
      .eq("placement", "lobby")
      .eq("status", "pending_host")
      .gt("offer_expires_at", nowIso)
      .lte("offer_expires_at", soon);
    if (error) { console.error("expiring offers query failed:", error); return 0; }

    let inserted = 0;
    // deno-lint-ignore no-explicit-any
    for (const r of (rows ?? []) as any[]) {
      const hostId = r.events?.host_id as string | undefined;
      if (!hostId) continue;

      const { data: already } = await admin
        .from("notifications")
        .select("id")
        .eq("recipient_id", hostId)
        .eq("type", "sponsorship_offer_expiring")
        .eq("entity_id", r.id)
        .maybeSingle();
      if (already) continue;

      const { data: enabled } = await admin.rpc("notif_enabled", {
        p_uid: hostId,
        p_type: "sponsorship_offer_expiring",
      });
      if (enabled === false) continue; // fail-open on null

      // actor_id is NOT NULL and FKs to profiles; an advertiser account has no
      // profile row, so the host stands in as their own actor — same shape as
      // the sponsorship_offer row written on clearance.
      const { error: insErr } = await admin.from("notifications").insert({
        recipient_id: hostId,
        actor_id: hostId,
        type: "sponsorship_offer_expiring",
        entity_id: r.id,
      });
      if (insErr) { console.error("expiring nudge insert failed:", insErr); continue; }
      inserted++;
    }
    return inserted;
  } catch (err) {
    console.error("expiring offer nudge error:", err);
    return 0;
  }
}

// Image creatives already store a public URL; video creatives store a
// bucket-relative thumb path in ad-videos (0068), so rebuild it.
// deno-lint-ignore no-explicit-any
function creativeThumbUrl(cr: any): string | null {
  if (!cr) return null;
  if (cr.kind === "video") {
    if (!cr.thumb_path) return null;
    const base = Deno.env.get("SUPABASE_URL")!.replace(/\/$/, "");
    return `${base}/storage/v1/object/public/ad-videos/${cr.thumb_path}`;
  }
  return (cr.image_url as string | null) ?? null;
}

// ── Lobby review aging alert (2-hourly) ──────────────────────────────────────
// The nightly digest fires at 3 days; a sponsorship offer only has 72 hours
// from submission to the host's deadline, so 3 days is the whole fuse. Anything
// lobby-shaped sitting unscreened for 12h gets an alert on its own cadence.
// deno-lint-ignore no-explicit-any
async function checkAgingLobbyOffers(admin: any) {
  const twelveHoursAgo = new Date(Date.now() - 12 * 3_600_000).toISOString();
  const { data: aging, error } = await admin
    .from("ad_campaigns")
    .select("id, created_at, offer_expires_at, advertiser_accounts(name)")
    .eq("placement", "lobby")
    .eq("status", "pending_review")
    .lt("created_at", twelveHoursAgo)
    .order("created_at", { ascending: true });
  if (error) { console.error("lobby aging query failed:", error); return { aging: 0 }; }
  const list = aging ?? [];
  if (list.length === 0) return { aging: 0 };

  const oldestHours = Math.floor(
    (Date.now() - new Date(list[0].created_at).getTime()) / 3_600_000,
  );
  // unique_id buckets on a 2-hour window so a retried cron delivery can't turn
  // one stalled queue into a stream of identical alerts.
  const now = new Date();
  const bucket = `${now.toISOString().slice(0, 10)}T${
    String(Math.floor(now.getUTCHours() / 2) * 2).padStart(2, "0")
  }`;
  await klaviyoEvent(
    "Nile Sponsorship Review Aging",
    Deno.env.get("ADMIN_ALERT_EMAIL"),
    `${bucket}:lobby_aging`,
    {
      count: list.length,
      oldest_hours: oldestHours,
      // deno-lint-ignore no-explicit-any
      oldest_brand: (list[0] as any).advertiser_accounts?.name ?? "Unknown",
      portal_url: "https://ads.joinnile.com/advertise/portal?view=review",
    },
  );
  return { aging: list.length, oldest_hours: oldestHours };
}

// The cron entry passes {"mode":"lobby-aging"}; a query string works too, so
// the fast path can be triggered by hand without a body.
async function isLobbyAgingRun(req: Request): Promise<boolean> {
  if (new URL(req.url).searchParams.get("mode") === "lobby-aging") return true;
  try {
    const body = await req.json();
    return body?.mode === "lobby-aging";
  } catch {
    return false; // no body at all — the nightly cron
  }
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
