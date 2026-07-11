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

    return json({ ok: true, updated: row?.updated ?? 0, completed: row?.completed ?? 0 });
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});

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
