// Supabase Edge Function: live-chat
//
// Server side of live chat (P1 #16, phase 1). Until now a message went straight
// from the sender's client onto the Realtime broadcast channel: no length cap,
// no rate limit, no record, and nothing a host could actually remove.
//
// Action-routed on `action` in the body, same shape as `livekit`:
//   send    viewer  → { id }            ← the only path that may author chat
//   remove  host    → { success: true } ← soft-delete one message, silently
//   ban     host    → { success: true, removed } ← ban for this event + eject
//
// Auth: verify-jwt is ON at the gateway. The sender is always derived from the
// JWT, never from the body — and so, now, is the display name: `send` reads the
// username and avatar from `profiles` rather than trusting what the client
// passed, which is what stops one viewer chatting as another.
//
// Entitlement reuses `can_join_live_chat` (migration 0104) by calling it as the
// *user*, so the rule that decides who may be in the room is stated once and
// this function cannot drift from the Realtime policy.
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
// floor passes the build that sends through here. Same shape of problem as the
// `lobbySafe` flag from P1 #7.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { RoomServiceClient } from "https://esm.sh/livekit-server-sdk@2.9.7?target=deno";
import { corsHeaders as corsHeadersFor } from "../_shared/cors.ts";

// Long enough for a real thought, short enough that one person cannot own the
// scrollback. The viewer's own input already truncates at 250; this is the
// backstop for a client that does not.
const MAX_MESSAGE_LENGTH = 500;

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
    return json({ error: String(err) }, 500);
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
    default:
      return json({ error: `Unknown action: ${body.action}` }, 400);
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

interface EventRow {
  id: string;
  host_id: string;
  livekit_room: string | null;
}

/**
 * Resolve the event from the client-side LiveKit slug (`events.livekit_room`),
 * which is what every live-time screen carries — never the events PK.
 */
// deno-lint-ignore no-explicit-any
async function findEvent(slug: string, admin: any): Promise<EventRow | null> {
  const { data } = await admin
    .from("events")
    .select("id, host_id, livekit_room")
    .eq("livekit_room", slug)
    .maybeSingle();
  return (data as EventRow | null) ?? null;
}

/**
 * Host-only gate for the moderation actions. Host only in v1 by decision —
 * `event_operators` crew publish cameras but do not police the room. Widening
 * this to crew later is a change to this one function.
 */
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
    return json({ error: "Forbidden — only the host can moderate this chat" }, 403);
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

  const { data: ok, error: rateError } = await admin.rpc("consume_live_chat_token", {
    p_event_id: event.id,
    p_user_id: userId,
  });
  if (rateError) return json({ error: "Could not check rate limit" }, 500);
  if (ok !== true) return json({ error: "You're sending messages too quickly" }, 429);

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
 * remove — soft-delete one message and tell every client to drop it.
 *
 * Soft, not hard: the row is the evidence a report is built on, and hard-
 * deleting it would mean a host could erase what they are being reported for.
 * The audience sees a silent disappearance either way.
 */
// deno-lint-ignore no-explicit-any
async function remove(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const slug = body.eventId as string | undefined;
  const messageId = body.messageId as string | undefined;
  if (!messageId) return json({ error: "messageId is required" }, 400);

  const gate = await requireHost(slug ?? "", userId, admin, json);
  if (gate instanceof Response) return gate;

  // Scoped to this event so a host cannot reach into another show's chat with
  // a borrowed message id.
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

  const gate = await requireHost(slug ?? "", userId, admin, json);
  if (gate instanceof Response) return gate;
  if (targetId === gate.host_id) {
    return json({ error: "You can't ban the host" }, 400);
  }

  // Idempotent: banning someone already banned is a host clicking twice, not an
  // error worth surfacing mid-show.
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
