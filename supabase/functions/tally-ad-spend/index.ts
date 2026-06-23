// Supabase Edge Function: tally-ad-spend
//
// Phase A-3 — reporting & budget enforcement. Cron-invoked nightly. Calls the
// tally_ad_spend() RPC, which recomputes spent_cents from ad_events per pricing
// model and flips campaigns to 'completed' once their budget is exhausted or
// their flight window has ended. Idempotent (spend is derived, not incremented),
// so overlapping or replayed runs converge to the same value.
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
    return json({ ok: true, updated: row?.updated ?? 0, completed: row?.completed ?? 0 });
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
