// Supabase Edge Function: notify-event-starting
//
// Cron-invoked. Fans out 'event_starting' notifications ~15 minutes before a
// scheduled event begins, to the host's followers and paid-ticket holders.
//
// Setup:
//   supabase functions deploy notify-event-starting --no-verify-jwt
//   (invoked by Supabase Cron with the service-role key — see CRON below)
//
// CRON (run every 5 minutes; the 15-min lead + per-event flag absorb jitter):
//   select cron.schedule(
//     'notify-event-starting',
//     '*/5 * * * *',
//     $$
//       select net.http_post(
//         url     := 'https://<PROJECT_REF>.functions.supabase.co/notify-event-starting',
//         headers := jsonb_build_object(
//           'Content-Type',  'application/json',
//           'Authorization', 'Bearer ' || '<SERVICE_ROLE_KEY>'
//         )
//       );
//     $$
//   );
//
// Idempotency lives in fanout_event_starting() (phase16_event_starting.sql):
// each event is stamped starting_notified_at on first fan-out, so overlapping
// or replayed runs are no-ops.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { failure } from "../_shared/errors.ts";
import { klaviyoEvent } from "../_shared/sponsorship.ts";

// Reminder lead time and how far past due we still bother notifying.
const LEAD_MINUTES = 15;
const GRACE_MINUTES = 5; // tolerate a slightly late cron tick.

serve(async (req) => {
  try {
    // Auth: cron proves it's us with a shared secret. Deployed --no-verify-jwt,
    // so without this gate anyone who knows the URL could fan out "starting
    // soon" push to every ticket holder on demand. Same pattern as send-push;
    // the cron side ships the header in migration 0103.
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

    const now = Date.now();
    // Notify when scheduled_at is within the next LEAD_MINUTES (and not already
    // GRACE_MINUTES past). Upper bound is the reminder horizon; lower bound
    // avoids reminding for events that started a while ago.
    const lowerIso = new Date(now - GRACE_MINUTES * 60_000).toISOString();
    const upperIso = new Date(now + LEAD_MINUTES * 60_000).toISOString();

    const { data: events, error } = await admin
      .from("events")
      .select("id")
      .eq("status", "scheduled")
      .is("starting_notified_at", null)
      .not("scheduled_at", "is", null)
      .gte("scheduled_at", lowerIso)
      .lte("scheduled_at", upperIso);

    if (error) return json({ error: error.message }, 500);

    let notified = 0;
    let emailed = 0;
    let events_processed = 0;
    for (const ev of events ?? []) {
      const { data: count, error: rpcErr } = await admin.rpc(
        "fanout_event_starting",
        { p_event_id: ev.id },
      );
      if (rpcErr) {
        console.error(`fanout failed for ${ev.id}:`, rpcErr.message);
        continue;
      }
      events_processed++;
      notified += (count as number) ?? 0;
      emailed += await emailUnreachableTicketHolders(admin, ev.id);
    }

    return json({ ok: true, events_processed, notified, emailed });
  } catch (err) {
    console.error(err);
    return json(failure(err, "notify-event-starting"), 500);
  }
});

// Email fallback (P4 #38, migration 0128). Push has always been the ONLY
// channel for this reminder, so a buyer who denied the notification permission
// simply misses a show they paid for — the one notification here where being
// unreachable costs the user money.
//
// unreachable_ticket_holders() returns only people push cannot reach: paid
// ticket holders, reminder not switched off, and no device token at all. An
// email that duplicates a push they already got is how people learn to ignore
// both.
//
// No-ops without KLAVIYO_API_KEY, so this is inert until the "Nile Event
// Starting" flow exists — one addition to the flow backlog, with the event
// already firing when it's built.
//
// deno-lint-ignore no-explicit-any
async function emailUnreachableTicketHolders(admin: any, eventId: string): Promise<number> {
  try {
    const { data: people, error } = await admin
      .rpc("unreachable_ticket_holders", { p_event_id: eventId });
    if (error) {
      console.error(`unreachable lookup failed for ${eventId}:`, error.message);
      return 0;
    }
    if (!people?.length) return 0;

    let sent = 0;
    // deno-lint-ignore no-explicit-any
    for (const p of people as any[]) {
      // unique_id keyed on (event, user) so a retry of this cron run — or the
      // same event caught in two overlapping windows — can't mail twice.
      await klaviyoEvent(
        "Nile Event Starting",
        p.email,
        `event-starting:${eventId}:${p.user_id}`,
        {
          event_title: p.event_title,
          scheduled_at: p.scheduled_at,
          display_name: p.display_name,
          reason: "no_push_token",
        },
      );
      sent++;
    }
    return sent;
  } catch (err) {
    // A mail failure must never stop the push fan-out for the next event.
    console.error(`email fallback error for ${eventId}:`, err);
    return 0;
  }
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
