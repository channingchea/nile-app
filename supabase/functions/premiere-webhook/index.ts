// Supabase Edge Function: premiere-webhook (docs/plans/studio-modes.md, phase 6)
//
// Two server-to-server callers, neither with a user JWT:
//   1. Cloudflare Stream, when a film or trailer finishes processing (or fails).
//      Verified with the Webhook-Signature header (CF_STREAM_WEBHOOK_SECRET).
//   2. pg_cron's hourly premiere-sweep (migration 0151), with x-cron-secret.
//      Sets delete_after once a show has ended, reminds the host two days
//      ahead, and deletes films from Stream when the window has passed.
//
// Deploy WITHOUT JWT verification:
//   supabase functions deploy premiere-webhook --no-verify-jwt

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { drainDeletions, ensureSigned, getVideo } from "../_shared/cloudflare_stream.ts";
import {
  deleteAfter,
  type MediaKind,
  REMINDER_LEAD_MS,
  reminderDue,
  type ReplayPolicy,
  showIsOver,
  streamStateOf,
  verifyWebhook,
} from "../_shared/premiere.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const ok = (body: unknown = { ok: true }, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

function log(level: "info" | "warn" | "error", fields: Record<string, unknown>) {
  console.log(JSON.stringify({ level, fn: "premiere-webhook", ...fields }));
}

const statusPatch = (kind: MediaKind, s: ReturnType<typeof streamStateOf> & object) => ({
  [`${kind}_status`]: s.status,
  [`${kind}_error`]: s.error,
  [`${kind}_duration_s`]: s.durationS,
  ...(s.host ? { playback_host: s.host } : {}),
});

async function onStreamEvent(raw: string): Promise<Response> {
  const v = JSON.parse(raw);
  const s = streamStateOf(v);
  if (!s) return ok({ ignored: true });
  // Belt and braces: never leave a playable-by-id video behind.
  if (s.status === "ready") await ensureSigned(v).catch((err) => log("warn", { event: "lock", error: String(err) }));
  for (const kind of ["film", "trailer"] as MediaKind[]) {
    const { data: row } = await admin.from("event_films").select("event_id").eq(`${kind}_uid`, s.uid).maybeSingle();
    if (!row) continue;
    const { error } = await admin.from("event_films").update(statusPatch(kind, s))
      .eq("event_id", row.event_id).eq(`${kind}_uid`, s.uid);
    if (error) throw error;
    log("info", { event: "stream", kind, status: s.status, eventId: row.event_id });
    return ok();
  }
  // Not ours (deleted or replaced since): it's queued or already gone.
  return ok({ unknown: true });
}

type SweepRow = Record<string, any> & {
  event_id: string;
  host_id: string;
  events: { status: string; ended_at: string | null; removed_at: string | null; scheduled_at: string | null };
};

async function sweepRow(r: SweepRow, now: number): Promise<"deleted" | "reminded" | null> {
  // Uploads quiet for a day: ask Stream what happened (only for that uid).
  for (const kind of ["film", "trailer"] as MediaKind[]) {
    const uid = r[`${kind}_uid`];
    if (!uid || !["uploading", "processing"].includes(r[`${kind}_status`])) continue;
    if (now - Date.parse(r.updated_at) < 24 * 3600_000) continue;
    const v = await getVideo(uid);
    const s = v ? streamStateOf(v) : null;
    await admin.from("event_films").update(s
      ? statusPatch(kind, s)
      : { [`${kind}_status`]: "error", [`${kind}_error`]: "The upload didn't finish. Start it again." })
      .eq("event_id", r.event_id).eq(`${kind}_uid`, uid);
  }

  const ev = r.events;
  if (!showIsOver(ev, now)) return null;
  let overAt = r.over_at ? Date.parse(r.over_at) : null;
  if (overAt === null) {
    const ended = ev.ended_at ? Date.parse(ev.ended_at) : NaN;
    overAt = isFinite(ended) && ended <= now ? ended : now;
    await admin.from("event_films").update({ over_at: new Date(overAt).toISOString() }).eq("event_id", r.event_id);
  }
  const at = deleteAfter(overAt, (r.replay_policy ?? "none") as ReplayPolicy);
  const atIso = at === null ? null : new Date(at).toISOString();
  if (atIso !== r.delete_after) {
    const prev = r.delete_after ? Date.parse(r.delete_after) : null;
    const resetReminder = at !== null && prev !== null && at - REMINDER_LEAD_MS > now;
    await admin.from("event_films").update({ delete_after: atIso, ...(resetReminder ? { reminder_sent_at: null } : {}) })
      .eq("event_id", r.event_id);
    if (resetReminder) r.reminder_sent_at = null;
  }
  if (at === null) return null;
  if (now >= at) {
    // Clearing the uids queues both videos for deletion (trigger, 0152).
    await admin.from("event_films").update({
      film_uid: null, film_status: "none", film_error: null, film_bytes: null, film_duration_s: null, captions: [],
      trailer_uid: null, trailer_status: "none", trailer_error: null, trailer_duration_s: null,
    }).eq("event_id", r.event_id);
    return "deleted";
  }
  if (r.film_uid && reminderDue(at, now, r.reminder_sent_at)) {
    const { data: enabled } = await admin.rpc("notif_enabled", { p_uid: r.host_id, p_type: "film_expiring" });
    if (enabled !== false) {
      await admin.from("notifications").insert({
        recipient_id: r.host_id,
        actor_id: r.host_id,
        type: "film_expiring",
        entity_id: r.event_id,
      });
    }
    await admin.from("event_films").update({ reminder_sent_at: new Date(now).toISOString() }).eq("event_id", r.event_id);
    return "reminded";
  }
  return null;
}

async function sweep(): Promise<Response> {
  const now = Date.now();
  const { data: rows, error } = await admin
    .from("event_films")
    .select("*, events!inner(status, ended_at, removed_at, scheduled_at)")
    .or("film_uid.not.is.null,trailer_uid.not.is.null");
  if (error) throw error;
  let reminded = 0, deleted = 0, failed = 0;
  for (const r of (rows ?? []) as SweepRow[]) {
    try {
      const done = await sweepRow(r, now);
      if (done === "deleted") deleted++;
      if (done === "reminded") reminded++;
    } catch (err) {
      failed++;
      log("warn", { event: "sweep-row", eventId: r.event_id, error: String(err) });
    }
  }
  const drained = await drainDeletions(admin, 100);
  log("info", { event: "sweep", films: rows?.length ?? 0, reminded, deleted, failed, drained });
  return ok({ reminded, deleted, failed, drained });
}

serve(async (req) => {
  if (req.method !== "POST") return ok({ error: "Method not allowed" }, 405);
  try {
    const cron = Deno.env.get("CRON_SHARED_SECRET");
    if (req.headers.has("x-cron-secret")) {
      if (!cron || req.headers.get("x-cron-secret") !== cron) return ok({ error: "Forbidden" }, 403);
      return await sweep();
    }
    const raw = await req.text();
    const secret = Deno.env.get("CF_STREAM_WEBHOOK_SECRET") ?? "";
    if (!(await verifyWebhook(req.headers.get("Webhook-Signature"), raw, secret, Math.floor(Date.now() / 1000)))) {
      log("warn", { event: "bad-signature" });
      return ok({ error: "Invalid signature" }, 403);
    }
    return await onStreamEvent(raw);
  } catch (err) {
    log("error", { error: String(err), stack: err instanceof Error ? err.stack : undefined });
    return ok({ error: "Internal error" }, 500);
  }
});
