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

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14?target=deno";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
  httpClient: Stripe.createFetchHttpClient(),
});

serve(async (_req) => {
  try {
    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data, error } = await admin.rpc("tally_ad_spend");
    if (error) return json({ error: error.message }, 500);

    // RPC returns a single { updated, completed } row.
    const row = Array.isArray(data) ? data[0] : data;

    // Review-SLA aging digest (Part 2 of the hardening plan). Piggybacks on
    // this fn's existing nightly cron rather than adding new infra.
    await checkAgingReviews(admin);

    // Sponsorship housekeeping (0079): dead events → refunds, stale locks freed.
    const refunds = await sweepSponsorships(admin);

    return json({
      ok: true,
      updated: row?.updated ?? 0,
      completed: row?.completed ?? 0,
      sponsorship_refunds: refunds,
    });
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});

// ── Sponsorship sweep (0079) ──────────────────────────────────────────────────
// Event-death triggers (delete / cancel / started-unreviewed) enqueue rows in
// sponsorship_refunds; the DB can't call Stripe, so the money work happens
// here. This sweep also catches the one death no trigger sees — an event that
// simply never started — and frees event locks held by abandoned checkouts.
// Never throws: a Stripe failure marks the row 'failed' for the next run.
// deno-lint-ignore no-explicit-any
async function sweepSponsorships(admin: any): Promise<number> {
  let processed = 0;
  try {
    // 1) Events that never started: still 'scheduled' 24h+ past their slot,
    //    with a paid lobby campaign. Reject + enqueue, then process below.
    const dayAgo = new Date(Date.now() - 86_400_000).toISOString();
    const { data: zombies } = await admin
      .from("ad_campaigns")
      .select("id, advertiser_account_id, stripe_payment_intent_id, split_status, status, events!inner(status, scheduled_at, title)")
      .eq("placement", "lobby")
      .in("status", ["pending_review", "active"])
      .eq("events.status", "scheduled")
      .lt("events.scheduled_at", dayAgo);
    // deno-lint-ignore no-explicit-any
    for (const c of (zombies ?? []) as any[]) {
      const { data: flipped } = await admin
        .from("ad_campaigns")
        .update({
          status: "rejected",
          review_note: "The event never started — your payment has been refunded.",
        })
        .eq("id", c.id)
        .eq("status", c.status)
        .select("id")
        .maybeSingle();
      if (flipped) {
        await admin.from("sponsorship_refunds").insert({
          campaign_id: c.id,
          advertiser_account_id: c.advertiser_account_id,
          stripe_payment_intent_id: c.stripe_payment_intent_id,
          split_status: c.split_status,
          event_title: (c as any).events?.title ?? null,
          reason: "event_never_started",
        });
      }
    }

    // 2) Process the queue: cancel an uncaptured hold, refund a captured split.
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
        if (piId?.startsWith("pi_")) {
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

    // 3) Abandoned checkouts: a pending_payment lobby row locks its event, and
    //    Checkout Sessions expire after 24h — delete stale ones to free the
    //    lock (nothing was authorized; the creative cascade-deletes).
    await admin
      .from("ad_campaigns")
      .delete()
      .eq("placement", "lobby")
      .eq("status", "pending_payment")
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
async function checkAgingReviews(admin: ReturnType<typeof createClient>) {
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

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
