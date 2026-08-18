// Supabase Edge Function: livekit-sweep
//
// One scheduled job that keeps LiveKit and the events table agreeing with each
// other. It replaces work the clients used to do badly, and does work nobody
// was doing at all.
//
//   1. Viewer counts (P1 #13). Every viewer used to run its own unjittered 30s
//      timer that asked the server to recount the room and write the result to
//      one hot events row, which realtime then fanned back out to every viewer.
//      That is O(N) invocations and O(N²) messages for a number that moves by
//      two: at 1,000 viewers, ~33 function calls a second and ~33,000 realtime
//      messages a second, with row-lock contention peaking exactly when the
//      show is busiest. One sweep per live event replaces all of it — clients
//      now just read the row they were already subscribed to.
//
//   2. Abandoned rooms (P1 #17). auto_end_expired_events is pure SQL: it closes
//      the events row and never tells LiveKit. If the host's device is offline
//      at the cap, the room stays up with cameras publishing and egress
//      recording until emptyTimeout (30 min) expires — billed egress, and half
//      an hour of dead air appended to the replay the host is about to sell.
//      Deleting the room here ends both immediately.
//
// Deploy WITHOUT JWT verification — cron has no user JWT — and gate on the
// shared secret instead, exactly like notify-event-starting and tally-ad-spend:
//   supabase functions deploy livekit-sweep --no-verify-jwt
//
// Secrets: CRON_SHARED_SECRET, LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET
// (all already set project-wide). Scheduled from migration 0106.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  EgressClient,
  RoomServiceClient,
} from "https://esm.sh/livekit-server-sdk@2.9.7?target=deno";
import { failure } from "../_shared/errors.ts";

const LIVEKIT_HTTP_URL = Deno.env.get("LIVEKIT_URL")!
  .replace(/^wss:/, "https:")
  .replace(/^ws:/, "http:");
const roomService = new RoomServiceClient(
  LIVEKIT_HTTP_URL,
  Deno.env.get("LIVEKIT_API_KEY")!,
  Deno.env.get("LIVEKIT_API_SECRET")!,
);
const egressClient = new EgressClient(
  LIVEKIT_HTTP_URL,
  Deno.env.get("LIVEKIT_API_KEY")!,
  Deno.env.get("LIVEKIT_API_SECRET")!,
);

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const roomNameFor = (slug: string) => `nile-event-${slug}`;

function log(level: "info" | "warn" | "error", fields: Record<string, unknown>) {
  console.log(JSON.stringify({ level, fn: "livekit-sweep", ...fields }));
}

function parseMeta(raw: string | undefined): Record<string, unknown> {
  try {
    return JSON.parse(raw || "{}");
  } catch {
    return {};
  }
}

/**
 * Recount one live event's viewers from LiveKit and write it to the row.
 *
 * Counting is by the userId in participant metadata, never by identity:
 * identities carry a per-connection suffix, so one person watching on a phone
 * and a laptop is one viewer.
 *
 * A LiveKit read failure throws to the caller, which leaves the stored count
 * alone rather than writing 0. The old client-side path learned this the hard
 * way — one transient API error zeroed the viewer count mid-show for everyone.
 */
async function sweepViewerCount(event: { id: string; livekit_room: string }) {
  const participants = await roomService.listParticipants(
    roomNameFor(event.livekit_room),
  );
  const viewers = new Set<string>();
  for (const p of participants) {
    const meta = parseMeta(p.metadata);
    if (meta.role !== "viewer") continue;
    viewers.add((meta.userId as string | undefined) ?? p.identity);
  }
  await admin.rpc("set_viewer_count", {
    p_event_id: event.id,
    p_count: viewers.size,
  });
  return viewers.size;
}

/**
 * Tear down the LiveKit room behind an event that has already ended.
 *
 * Order matters: stop the egress first so the recording finalizes where the
 * show actually stopped, then delete the room. Deleting also emits
 * room_finished, which livekit-webhook uses to finalize the replay row — but
 * egress is stopped explicitly here rather than relying on that webhook being
 * delivered, because the cost of a missed delivery is a recording that runs on.
 *
 * Both calls are idempotent: stopping a stopped egress and deleting a room that
 * is already gone are no-ops.
 */
async function closeRoom(event: { id: string; livekit_room: string }) {
  const { data: recording } = await admin
    .from("replays")
    .select("egress_id")
    .eq("event_id", event.id)
    .eq("status", "recording")
    .maybeSingle();

  if (recording?.egress_id) {
    try {
      await egressClient.stopEgress(recording.egress_id as string);
    } catch (err) {
      log("warn", { step: "stop-egress", eventId: event.id, error: String(err) });
    }
  }

  await roomService.deleteRoom(roomNameFor(event.livekit_room));
}

serve(async (req) => {
  const expected = Deno.env.get("CRON_SHARED_SECRET");
  if (!expected || req.headers.get("x-cron-secret") !== expected) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  const t0 = Date.now();
  let counted = 0;
  let closed = 0;

  try {
    // 1. Live and Sound Check events: refresh the viewer count.
    const { data: liveEvents } = await admin
      .from("events")
      .select("id, livekit_room")
      .in("status", ["live", "soundcheck"])
      .not("livekit_room", "is", null);

    for (const ev of liveEvents ?? []) {
      try {
        await sweepViewerCount(ev as { id: string; livekit_room: string });
        counted++;
      } catch (err) {
        // Room not up yet — the normal state of a Sound Check nobody has
        // joined. Logged, not fatal, and deliberately does not write a count.
        log("warn", { step: "count", eventId: ev.id, error: String(err) });
      }
    }

    // 2. Recently ended events: make sure LiveKit knows. Bounded to the last
    //    two hours so this stays a short list — anything older has long since
    //    hit emptyTimeout on its own, and re-deleting a deleted room every
    //    minute forever would be pointless traffic.
    const since = new Date(Date.now() - 2 * 60 * 60_000).toISOString();
    const { data: endedEvents } = await admin
      .from("events")
      .select("id, livekit_room")
      .eq("status", "ended")
      .gte("ended_at", since)
      .not("livekit_room", "is", null);

    for (const ev of endedEvents ?? []) {
      try {
        await closeRoom(ev as { id: string; livekit_room: string });
        closed++;
      } catch {
        // Already gone, which is the desired end state.
      }
    }

    log("info", { counted, closed, ms: Date.now() - t0 });
    return new Response(JSON.stringify({ ok: true, counted, closed }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    log("error", { error: String(err), ms: Date.now() - t0 });
    return new Response(JSON.stringify(failure(err, "livekit-sweep")), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
