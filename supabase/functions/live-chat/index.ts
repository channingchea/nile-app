// Supabase Edge Function: live-chat
//
// Server side of live chat (P1 #16). Until phase 1 a message went straight from
// the sender's client onto the Realtime broadcast channel: no length cap, no
// rate limit, no record, and nothing a host could actually remove.
//
// Action-routed on `action` in the body, same shape as `livekit`:
//   send      viewer     → { id }            ← the only path that may author chat
//   remove    moderator  → { success: true } ← soft-delete one message, silently
//   ban       moderator  → { success: true, removed } ← ban for this event + eject
//   settings  host       → { success: true } ← slow mode / who may speak / crew
//
// Auth: verify-jwt is ON at the gateway. The sender is always derived from the
// JWT, never from the body — and so is the display name: `send` reads the
// username and avatar from `profiles` rather than trusting what the client
// passed, which is what stops one viewer chatting as another.
//
// Entitlement reuses `can_join_live_chat` (migration 0104) by calling it as the
// *user*, so the rule that decides who may be in the room is stated once and
// this function cannot drift from the Realtime policy.
//
// "Moderator" is the host, plus assigned crew when the host has switched
// `events.chat_crew_moderation` on for that show (phase 5). Default is off,
// which keeps the v1 decision — host only — as the behaviour nobody opts into.
//
// Secrets: SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY are
// auto-injected. LIVEKIT_* are already set project-wide for `livekit`.
//
// Deploy with JWT verification ON (the default — do NOT pass --no-verify-jwt):
//   supabase functions deploy live-chat
//
// CLIENT-VERSION NOTE: shipped builds still broadcast directly and will keep
// doing so until they update. This function is purely additive — the
// realtime.messages INSERT policy from 0104 stays as it is. Tightening it to
// service-role only is a separate change, and only safe once the force-update
// floor passes the build that adopts it. Same shape of problem as the
// `lobbySafe` flag from P1 #7. Until then the word filter, slow mode and the
// speak-access rules only bind clients that send through here.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { RoomServiceClient } from "https://esm.sh/livekit-server-sdk@2.9.7?target=deno";
import { corsHeaders as corsHeadersFor } from "../_shared/cors.ts";
import { failure } from "../_shared/errors.ts";

// Long enough for a real thought, short enough that one person cannot own the
// scrollback. The viewer's own input already truncates at 250; this is the
// backstop for a client that does not.
const MAX_MESSAGE_LENGTH = 500;

// Default bucket: 5 messages per 10 seconds sustained, burst 10. Slow mode
// replaces it with a capacity of 1 refilling once per slow-mode second.
const DEFAULT_BUCKET = { capacity: 10, refillPerSecond: 0.5 };
const MAX_SLOW_MODE_SECONDS = 300;

// Same LiveKit credentials the `livekit` function uses — Supabase secrets are
// project-wide, so nothing new needs setting. Null when unset so a missing
// secret degrades the eject step rather than breaking the ban.
const LIVEKIT_URL = Deno.env.get("LIVEKIT_URL") ?? "";
const roomService = LIVEKIT_URL
  ? new RoomServiceClient(
    LIVEKIT_URL.replace(/^wss:/, "https:").replace(/^ws:/, "http:"),
    Deno.env.get("LIVEKIT_API_KEY")!,
    Deno.env.get("LIVEKIT_API_SECRET")!,
  )
  : null;

type Json = (body: unknown, status?: number) => Response;
const makeJson = (cors: Record<string, string>): Json =>
  (body, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

function log(level: "info" | "warn" | "error", fields: Record<string, unknown>) {
  console.log(JSON.stringify({ level, fn: "live-chat", ...fields }));
}

// ── Broadcast ─────────────────────────────────────────────────────────────────

/**
 * Put messages on a Realtime topic as the service role, the same way
 * stripe-webhook announces a tip.
 *
 * Never throws. A message that is written but not broadcast is recoverable —
 * the record is what moderation runs on. A 500 back to the sender because the
 * broadcast hiccuped is not.
 */
async function broadcast(
  messages: Array<{ topic: string; event: string; payload: Record<string, unknown> }>,
): Promise<void> {
  if (messages.length === 0) return;
  try {
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/realtime/v1/api/broadcast`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: key,
        Authorization: `Bearer ${key}`,
      },
      body: JSON.stringify({
        messages: messages.map((m) => ({ ...m, private: true })),
      }),
    });
    if (!res.ok) log("warn", { action: "broadcast", status: res.status, body: await res.text() });
  } catch (err) {
    log("warn", { action: "broadcast", error: String(err) });
  }
}

// ── Handler ───────────────────────────────────────────────────────────────────

serve(async (req) => {
  const corsHeaders = corsHeadersFor(req);
  const json = makeJson(corsHeaders);
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const reqId = crypto.randomUUID().slice(0, 8);
  const t0 = Date.now();
  try {
    const res = await handle(req, json);
    log(res.status < 400 ? "info" : "warn", { reqId, status: res.status, ms: Date.now() - t0 });
    return res;
  } catch (err) {
    log("error", {
      reqId,
      status: 500,
      ms: Date.now() - t0,
      error: String(err),
      stack: err instanceof Error ? err.stack : undefined,
    });
    return json(failure(err, "live-chat"), 500);
  }
});

async function handle(req: Request, json: Json): Promise<Response> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "Missing Authorization header" }, 401);

  const userClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return json({ error: "Unauthorized" }, 401);

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const body = await req.json().catch(() => ({}));
  switch (body.action as string | undefined) {
    case "send":
      return await send(body, user.id, userClient, admin, json);
    case "remove":
      return await remove(body, user.id, admin, json);
    case "ban":
      return await ban(body, user.id, admin, json);
    case "settings":
      return await settings(body, user.id, admin, json);
    default:
      return json({ error: `Unknown action: ${body.action}` }, 400);
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

interface EventRow {
  id: string;
  host_id: string;
  livekit_room: string | null;
  price: number | null;
  chat_crew_moderation: boolean;
  chat_slow_mode_seconds: number;
  chat_access: string;
}

const EVENT_COLS =
  "id, host_id, livekit_room, price, chat_crew_moderation, chat_slow_mode_seconds, chat_access";

/**
 * Resolve the event from the client-side LiveKit slug (`events.livekit_room`),
 * which is what every live-time screen carries — never the events PK.
 */
// deno-lint-ignore no-explicit-any
async function findEvent(slug: string, admin: any): Promise<EventRow | null> {
  const { data } = await admin
    .from("events")
    .select(EVENT_COLS)
    .eq("livekit_room", slug)
    .maybeSingle();
  return (data as EventRow | null) ?? null;
}

/** Is `userId` assigned crew on this event? */
// deno-lint-ignore no-explicit-any
async function isCrew(eventId: string, userId: string, admin: any): Promise<boolean> {
  const { data } = await admin
    .from("event_operators")
    .select("id")
    .eq("event_id", eventId)
    .eq("operator_id", userId)
    .maybeSingle();
  return !!data;
}

/**
 * Gate for the moderation actions.
 *
 * The host always. Assigned crew only when the host has turned
 * `chat_crew_moderation` on for this show — phase 5, opt-in per event, so the
 * "host only in v1" decision stays the default rather than being overwritten by
 * shipping the capability.
 */
// deno-lint-ignore no-explicit-any
async function requireModerator(
  slug: string,
  userId: string,
  admin: any,
  json: Json,
): Promise<EventRow | Response> {
  if (!slug) return json({ error: "eventId is required" }, 400);
  const event = await findEvent(slug, admin);
  if (!event) return json({ error: "Event not found" }, 404);
  if (event.host_id === userId) return event;
  if (event.chat_crew_moderation && await isCrew(event.id, userId, admin)) return event;
  return json({ error: "Forbidden — you can't moderate this chat" }, 403);
}

/** Host-only, for the settings that decide how the room behaves. */
// deno-lint-ignore no-explicit-any
async function requireHost(
  slug: string,
  userId: string,
  admin: any,
  json: Json,
): Promise<EventRow | Response> {
  if (!slug) return json({ error: "eventId is required" }, 400);
  const event = await findEvent(slug, admin);
  if (!event) return json({ error: "Event not found" }, 404);
  if (event.host_id !== userId) {
    return json({ error: "Forbidden — only the host can do this" }, 403);
  }
  return event;
}

/**
 * Disconnect a banned viewer from the room they were just banned from.
 *
 * Their identity carries a per-connection suffix and they may be on more than
 * one device, so match on the userId stamped into token metadata rather than
 * trying to reconstruct an identity string — the same approach refund-ticket
 * takes. Best-effort: the ban is already recorded and viewer-token will refuse
 * them on any rejoin, so a room that is not up is not a failure.
 */
async function ejectFromRoom(slug: string, targetId: string): Promise<void> {
  if (!roomService || !slug || !targetId) return;
  try {
    const roomName = `nile-event-${slug}`;
    const participants = await roomService.listParticipants(roomName);
    await Promise.all(
      participants
        .filter((p) => {
          try {
            return JSON.parse(p.metadata || "{}").userId === targetId;
          } catch {
            return false;
          }
        })
        .map((p) => roomService.removeParticipant(roomName, p.identity)),
    );
  } catch (err) {
    log("warn", { action: "eject", slug, error: String(err) });
  }
}

// ── Actions ───────────────────────────────────────────────────────────────────

/**
 * send — validate, record, then broadcast. In that order: a message the
 * audience saw but we cannot produce later is exactly the gap this whole tier
 * exists to close.
 *
 * Check order is deliberate. Ban and entitlement first because they are cheap
 * and final. The rate limit next, so everything after it is bounded — including
 * the word filter, which would otherwise be a free oracle anyone could probe
 * the blocklist with.
 */
async function send(
  // deno-lint-ignore no-explicit-any
  body: any,
  userId: string,
  // deno-lint-ignore no-explicit-any
  userClient: any,
  // deno-lint-ignore no-explicit-any
  admin: any,
  json: Json,
): Promise<Response> {
  const slug = body.eventId as string | undefined;
  if (!slug) return json({ error: "eventId is required" }, 400);

  const text = String(body.content ?? "").trim();
  if (!text) return json({ error: "Message is empty" }, 400);
  if (text.length > MAX_MESSAGE_LENGTH) {
    return json({ error: `Messages are limited to ${MAX_MESSAGE_LENGTH} characters` }, 400);
  }

  const event = await findEvent(slug, admin);
  if (!event) return json({ error: "Event not found" }, 404);

  // Banned first: cheapest check, and the one whose answer the sender has
  // already earned. Deliberately vague back to the client — "you are banned
  // from this chat" invites an argument in someone else's show.
  const { data: banned } = await admin
    .from("live_chat_bans")
    .select("user_id")
    .eq("event_id", event.id)
    .eq("user_id", userId)
    .maybeSingle();
  if (banned) return json({ error: "You can't send messages in this chat" }, 403);

  // Same gate the Realtime write policy applies, asked as the caller so
  // auth.uid() is set inside the SECURITY DEFINER function. Stating the rule
  // once is the point — a second copy of "who may be in this chat" would drift.
  const { data: allowed, error: gateError } = await userClient.rpc("can_join_live_chat", {
    p_topic: `live_chat:${slug}`,
  });
  if (gateError) return json({ error: "Could not verify chat access" }, 500);
  if (allowed !== true) return json({ error: "You don't have access to this chat" }, 403);

  // Crew and the host are exempt from every restriction below — a host cannot
  // lock themselves out of their own show by turning slow mode on.
  const privileged = event.host_id === userId || await isCrew(event.id, userId, admin);

  if (!privileged) {
    const denied = await accessDenial(event, userId, admin);
    if (denied) return json({ error: denied }, 403);
  }

  // Slow mode replaces the default bucket rather than stacking on it: capacity
  // 1, refilling once every N seconds. `least(capacity, …)` inside the function
  // clamps a bucket that was filled under the old settings, so a host can turn
  // this on mid-show and it binds immediately.
  const slow = Math.min(MAX_SLOW_MODE_SECONDS, Math.max(0, event.chat_slow_mode_seconds ?? 0));
  const bucket = slow > 0
    ? { capacity: 1, refillPerSecond: 1 / slow }
    : DEFAULT_BUCKET;

  if (!privileged) {
    const { data: ok, error: rateError } = await admin.rpc("consume_live_chat_token", {
      p_event_id: event.id,
      p_user_id: userId,
      p_capacity: bucket.capacity,
      p_refill_per_second: bucket.refillPerSecond,
    });
    if (rateError) return json({ error: "Could not check rate limit" }, 500);
    if (ok !== true) {
      return json({
        error: slow > 0
          ? `Slow mode is on — one message every ${slow} seconds`
          : "You're sending messages too quickly",
      }, 429);
    }
  }

  // Word filter (phase 4). Rejected out loud, not shadow-dropped: a message
  // that silently vanishes teaches the sender nothing and generates a support
  // ticket instead of a corrected sentence. Crew and host skip it — a host
  // being filtered on their own show is the worst version of a false positive.
  if (!privileged) {
    const { data: hit } = await admin.rpc("live_chat_filter_hit", { p_text: text });
    if (typeof hit === "string" && hit.length > 0) {
      // The matched word and who tripped it, never the message. Best-effort:
      // failing a send because the tuning log was unavailable would be absurd.
      await admin
        .from("live_chat_filter_hits")
        .insert({ event_id: event.id, user_id: userId, matched: hit })
        .then(
          (r: { error?: unknown }) =>
            r.error && log("warn", { action: "filter-log", error: String(r.error) }),
        );
      return json({ error: "That message can't be sent in this chat" }, 422);
    }
  }

  // Identity comes from the database, not the body. The old client-side path
  // put the sender's own username in the payload because a broadcast carries no
  // profile join; from the server there is no reason to trust it, and trusting
  // it let anyone chat under anyone else's name.
  const { data: profile } = await admin
    .from("profiles")
    .select("username, avatar_url")
    .eq("id", userId)
    .maybeSingle();

  const { data: row, error: insertError } = await admin
    .from("live_chat_messages")
    .insert({ event_id: event.id, sender_id: userId, body: text })
    .select("id, created_at")
    .single();
  if (insertError || !row) return json({ error: "Could not send message" }, 500);

  await broadcast([{
    topic: `live_chat:${slug}`,
    event: "msg",
    payload: {
      id: row.id,
      sender_id: userId,
      username: profile?.username ?? "viewer",
      avatar_url: profile?.avatar_url ?? null,
      content: text,
      sent_at: row.created_at,
      kind: "user",
    },
  }]);

  return json({ id: row.id });
}

/**
 * Who may speak, when the host has narrowed it (phase 5). Returns the wording
 * to send back, or null when they're allowed.
 *
 * Reading is deliberately untouched — a follower gate that also hid the
 * conversation would make a restricted room indistinguishable from a broken
 * one, and the whole point of #15's client half was to stop chat failing
 * silently.
 */
async function accessDenial(
  event: EventRow,
  userId: string,
  // deno-lint-ignore no-explicit-any
  admin: any,
): Promise<string | null> {
  if (event.chat_access === "followers") {
    const { data } = await admin
      .from("follows")
      .select("follower_id")
      .eq("follower_id", userId)
      .eq("following_id", event.host_id)
      .maybeSingle();
    return data ? null : "Only followers can chat in this show";
  }
  if (event.chat_access === "ticket_holders") {
    const { data } = await admin
      .from("tickets")
      .select("status")
      .eq("event_id", event.id)
      .eq("buyer_id", userId)
      .maybeSingle();
    return data?.status === "paid" ? null : "Only ticket holders can chat in this show";
  }
  return null;
}

/**
 * remove — soft-delete one message and tell every client to drop it.
 *
 * Soft, not hard: the row is the evidence a report is built on, and hard-
 * deleting it would mean a moderator could erase what they are being reported
 * for. The audience sees a silent disappearance either way.
 */
// deno-lint-ignore no-explicit-any
async function remove(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const slug = body.eventId as string | undefined;
  const messageId = body.messageId as string | undefined;
  if (!messageId) return json({ error: "messageId is required" }, 400);

  const gate = await requireModerator(slug ?? "", userId, admin, json);
  if (gate instanceof Response) return gate;

  // Scoped to this event so a moderator cannot reach into another show's chat
  // with a borrowed message id.
  const { error } = await admin
    .from("live_chat_messages")
    .update({ removed_at: new Date().toISOString(), removed_by: userId })
    .eq("id", messageId)
    .eq("event_id", gate.id)
    .is("removed_at", null);
  if (error) return json({ error: "Could not remove message" }, 500);

  await broadcast([{
    topic: `live_chat:${slug}`,
    event: "rm",
    payload: { id: messageId },
  }]);

  return json({ success: true });
}

/**
 * ban — bar someone from this event's chat, wipe what they already said, and
 * disconnect them.
 *
 * All three matter together. Without the wipe the ban leaves the abuse on
 * screen; without the eject they keep watching and can still tip, react and
 * rejoin; and without the row, `viewer-token` has nothing to refuse them with
 * on a free event — the hole P1 #11's remove-participant left open.
 */
// deno-lint-ignore no-explicit-any
async function ban(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const slug = body.eventId as string | undefined;
  const targetId = body.targetId as string | undefined;
  if (!targetId) return json({ error: "targetId is required" }, 400);

  const gate = await requireModerator(slug ?? "", userId, admin, json);
  if (gate instanceof Response) return gate;
  if (targetId === gate.host_id) {
    return json({ error: "You can't ban the host" }, 400);
  }
  // Crew are off limits too, now that crew can moderate. Removing someone from
  // the crew is a roster decision on the event page, not something one operator
  // does to another mid-show.
  if (await isCrew(gate.id, targetId, admin)) {
    return json({ error: "You can't ban someone on the crew" }, 400);
  }

  // Idempotent: banning someone already banned is a moderator clicking twice,
  // not an error worth surfacing mid-show.
  const { error: banError } = await admin
    .from("live_chat_bans")
    .upsert(
      { event_id: gate.id, user_id: targetId, banned_by: userId },
      { onConflict: "event_id,user_id", ignoreDuplicates: true },
    );
  if (banError) return json({ error: "Could not ban this viewer" }, 500);

  const { data: wiped } = await admin
    .from("live_chat_messages")
    .update({ removed_at: new Date().toISOString(), removed_by: userId })
    .eq("event_id", gate.id)
    .eq("sender_id", targetId)
    .is("removed_at", null)
    .select("id");

  // One `rm_user` rather than an `rm` per message: a prolific troll would
  // otherwise mean dozens of broadcasts, and every client already has to handle
  // "drop everything from this sender" for the ban to look instant.
  await broadcast([{
    topic: `live_chat:${slug}`,
    event: "rm_user",
    payload: { sender_id: targetId },
  }]);

  await ejectFromRoom(slug ?? "", targetId);

  return json({ success: true, removed: (wiped ?? []).length });
}

/**
 * settings — the host's three chat controls (phase 5).
 *
 * Written here rather than straight from the client so the validation and the
 * "only the host" rule live next to the code that enforces them at send time,
 * and so the ticket-holders/free-event CHECK comes back as a sentence rather
 * than a Postgres constraint name.
 *
 * Partial: only the keys present in the body are written, so a client that
 * predates one control cannot blank it.
 */
// deno-lint-ignore no-explicit-any
async function settings(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const slug = body.eventId as string | undefined;
  const gate = await requireHost(slug ?? "", userId, admin, json);
  if (gate instanceof Response) return gate;

  const patch: Record<string, unknown> = {};

  if (body.crewModeration !== undefined) {
    if (typeof body.crewModeration !== "boolean") {
      return json({ error: "crewModeration must be true or false" }, 400);
    }
    patch.chat_crew_moderation = body.crewModeration;
  }

  if (body.slowModeSeconds !== undefined) {
    const n = Number(body.slowModeSeconds);
    if (!Number.isInteger(n) || n < 0 || n > MAX_SLOW_MODE_SECONDS) {
      return json({ error: `slowModeSeconds must be 0-${MAX_SLOW_MODE_SECONDS}` }, 400);
    }
    patch.chat_slow_mode_seconds = n;
  }

  if (body.access !== undefined) {
    if (!["everyone", "followers", "ticket_holders"].includes(body.access)) {
      return json({ error: "access must be everyone, followers or ticket_holders" }, 400);
    }
    // Free events create no ticket rows at all, so this setting would mute the
    // entire room. The DB CHECK refuses it too; this is the readable version.
    if (body.access === "ticket_holders" && !(gate.price && gate.price > 0)) {
      return json({
        error: "This show is free, so there are no ticket holders to limit chat to",
      }, 400);
    }
    patch.chat_access = body.access;
  }

  if (Object.keys(patch).length === 0) return json({ error: "Nothing to update" }, 400);

  const { error } = await admin.from("events").update(patch).eq("id", gate.id);
  if (error) return json({ error: "Could not update chat settings" }, 500);

  return json({ success: true, ...patch });
}
