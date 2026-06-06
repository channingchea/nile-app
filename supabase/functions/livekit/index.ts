// Supabase Edge Function: livekit
//
// Consolidates the former Express backend (nile-backend) into one action-routed
// Edge Function. Handles LiveKit room creation and access-token minting for the
// multicam streaming experience: switchable, synchronized camera angles with a
// master-audio source, plus ticket-gated viewer access.
//
// One function, routed on `action` in the request body (section 3.1):
//   create-room       host    → { roomName, eventName }
//   camera-token      host    → { token, wsUrl, isMasterAudio }
//   audio-token       host    → { token, wsUrl }
//   list-cameras      host    → { cameras: [{ identity, name, cameraName, cameraId }] }
//   set-master-audio  host    → { success: true }
//   start-show        host    → { success: true }   ← stamps showStartedAt anchor
//   viewer-token      viewer  → { mode: "webrtc", token, wsUrl }   ← typed descriptor (3.2)
//
// Auth (section 3.3): verify-jwt is ON at the gateway. Every action requires a
// valid user JWT. viewer-token derives the user id FROM the JWT (never the body)
// — this fixes the userId-spoofing weakness in the old Express /viewer-token.
// Operator actions route through requireOperator(); today that means host-only,
// but it's the single seam to widen when camera-operator invites ship.
//
// Secrets (section 3.4):
//   supabase secrets set LIVEKIT_URL=wss://... LIVEKIT_API_KEY=... LIVEKIT_API_SECRET=...
//   (SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY are auto-injected.)
//
// Deploy with JWT verification ON (the default — do NOT pass --no-verify-jwt):
//   supabase functions deploy livekit

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  AccessToken,
  RoomServiceClient,
} from "https://esm.sh/livekit-server-sdk@2.9.7?target=deno";

const LIVEKIT_URL = Deno.env.get("LIVEKIT_URL")!;
const LIVEKIT_API_KEY = Deno.env.get("LIVEKIT_API_KEY")!;
const LIVEKIT_API_SECRET = Deno.env.get("LIVEKIT_API_SECRET")!;

// RoomServiceClient needs an http(s) URL; the app connects over wss.
const LIVEKIT_HTTP_URL = LIVEKIT_URL.replace(/^wss:/, "https:").replace(/^ws:/, "http:");
const roomService = new RoomServiceClient(
  LIVEKIT_HTTP_URL,
  LIVEKIT_API_KEY,
  LIVEKIT_API_SECRET,
);

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// ── Helpers ───────────────────────────────────────────────────────────────────

function roomNameFor(eventId: string) {
  return `nile-event-${eventId}`;
}

/** Mint a LiveKit access token. v2 toJwt() is async. */
function buildToken(opts: {
  identity: string;
  name: string;
  roomName: string;
  canPublish: boolean;
  canSubscribe: boolean;
  metadata: string;
}): Promise<string> {
  const at = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
    identity: opts.identity,
    name: opts.name,
    metadata: opts.metadata,
  });
  at.addGrant({
    roomJoin: true,
    room: opts.roomName,
    canPublish: opts.canPublish,
    canSubscribe: opts.canSubscribe,
    canPublishData: opts.canPublish, // data channel for publishers
  });
  return at.toJwt();
}

function parseMeta(raw: string | undefined): Record<string, unknown> {
  try {
    return JSON.parse(raw || "{}");
  } catch {
    return {};
  }
}

// ── Handler ───────────────────────────────────────────────────────────────────

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    // Identity from the verified JWT — the gateway already enforced verify-jwt,
    // but we re-derive the user so we never trust an id from the body (3.3).
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Missing Authorization header" }, 401);

    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) return json({ error: "Unauthorized" }, 401);

    // Service-role client for server-side checks that bypass RLS.
    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const body = await req.json().catch(() => ({}));
    const action = body.action as string | undefined;
    if (!action) return json({ error: "Missing action" }, 400);

    switch (action) {
      case "create-room":
        return await createRoom(body, user.id, admin);
      case "camera-token":
        return await cameraToken(body, user.id, admin);
      case "audio-token":
        return await audioToken(body, user.id, admin);
      case "list-cameras":
        return await listCameras(body, user.id, admin);
      case "set-master-audio":
        return await setMasterAudio(body, user.id, admin);
      case "start-show":
        return await startShow(body, user.id, admin);
      case "viewer-token":
        return await viewerToken(body, user.id, admin);
      default:
        return json({ error: `Unknown action: ${action}` }, 400);
    }
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});

// ── Host authorization ────────────────────────────────────────────────────────

/**
 * Confirm the caller may operate this event (publish cameras/audio, manage the
 * room). Returns the event row, or a Response error.
 *
 * Operator seam: today only the host is authorized. The roadmap is for the host
 * to invite camera-operator devices on other accounts — when that ships, widen
 * `isAuthorizedOperator` below (e.g. check an event_operators allowlist table).
 * This is the ONE place to change; every operator action routes through here.
 */
async function requireOperator(
  eventId: string,
  userId: string,
  admin: ReturnType<typeof createClient>,
): Promise<{ event: { id: string; host_id: string; livekit_room: string | null } } | Response> {
  // `eventId` here is the client-side LiveKit slug (events.livekit_room), NOT
  // the events PK (a uuid). Every live-time screen carries the slug, so resolve
  // the row by livekit_room.
  const { data: event, error } = await admin
    .from("events")
    .select("id, host_id, livekit_room")
    .eq("livekit_room", eventId)
    .maybeSingle();

  if (error || !event) return json({ error: "Event not found" }, 404);
  if (!(await isAuthorizedOperator(event, userId, admin))) {
    return json({ error: "Forbidden — not authorized to operate this event" }, 403);
  }
  return { event };
}

/** True if `userId` may operate the event: the host, or an assigned operator. */
async function isAuthorizedOperator(
  event: { id: string; host_id: string },
  userId: string,
  admin: ReturnType<typeof createClient>,
): Promise<boolean> {
  if (event.host_id === userId) return true;
  // Assigned camera operators (event_operators row) may publish too.
  const { data } = await admin
    .from("event_operators")
    .select("id")
    .eq("event_id", event.id)
    .eq("operator_id", userId)
    .maybeSingle();
  return !!data;
}

// ── Actions ───────────────────────────────────────────────────────────────────

// create-room (was POST /api/create-event)
//
// NOTE: no requireOperator() here — the app creates the LiveKit room BEFORE it
// writes the events row, so there is nothing to authorize against yet. The host
// binding is established when the row is inserted (host_id = the caller). The
// gateway's verify-jwt already guarantees the caller is an authenticated user,
// which is the right bar for "may create a room for an event I'm about to own".
// eventId is a client-generated slug; a stray room with no backing event simply
// auto-closes after emptyTimeout.
async function createRoom(body: any, _userId: string, _admin: any): Promise<Response> {
  const { eventId, eventName } = body;
  if (!eventId || !eventName) {
    return json({ error: "eventId and eventName are required" }, 400);
  }

  const roomName = roomNameFor(eventId);
  await roomService.createRoom({
    name: roomName,
    emptyTimeout: 1800, // close after 30 min idle
    maxParticipants: 1050,
    metadata: JSON.stringify({ eventName, eventId }),
  });

  return json({ roomName, eventName });
}

// camera-token (was POST /api/camera-token)
async function cameraToken(body: any, userId: string, admin: any): Promise<Response> {
  const { eventId, cameraId, cameraName } = body;
  if (!eventId || !cameraId || !cameraName) {
    return json({ error: "eventId, cameraId, and cameraName are required" }, 400);
  }

  const gate = await requireOperator(eventId, userId, admin);
  if (gate instanceof Response) return gate;

  const roomName = roomNameFor(eventId);

  // First camera to join becomes master audio by default.
  let isMasterAudio = false;
  try {
    const participants = await roomService.listParticipants(roomName);
    const cameras = participants.filter((p) => parseMeta(p.metadata).role === "camera");
    isMasterAudio = cameras.length === 0;
  } catch {
    // Room may not exist yet — treat as first camera.
    isMasterAudio = true;
  }

  const token = await buildToken({
    identity: `camera-${cameraId}`,
    name: cameraName,
    roomName,
    canPublish: true,
    canSubscribe: false,
    // joinedAt is server-stamped (no device clock skew) so the viewer can align
    // this camera against the master-audio timeline. A fresh token on rejoin =
    // a fresh joinedAt automatically.
    metadata: JSON.stringify({ role: "camera", cameraId, cameraName, isMasterAudio, joinedAt: Date.now() }),
  });

  return json({ token, wsUrl: LIVEKIT_URL, isMasterAudio });
}

// audio-token (was POST /api/audio-token) — audio-only master publisher
async function audioToken(body: any, userId: string, admin: any): Promise<Response> {
  const { eventId } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  const gate = await requireOperator(eventId, userId, admin);
  if (gate instanceof Response) return gate;

  const roomName = roomNameFor(eventId);
  const token = await buildToken({
    identity: `master-audio-${eventId}`,
    name: "Master Audio",
    roomName,
    canPublish: true,
    canSubscribe: false,
    // joinedAt is the zero reference for camera-sync offsets (see viewer side).
    metadata: JSON.stringify({ role: "master-audio", joinedAt: Date.now() }),
  });

  return json({ token, wsUrl: LIVEKIT_URL });
}

// list-cameras (was GET /api/event/:id/cameras) — feeds the viewer angle picker
async function listCameras(body: any, userId: string, admin: any): Promise<Response> {
  const { eventId } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  const gate = await requireOperator(eventId, userId, admin);
  if (gate instanceof Response) return gate;

  const roomName = roomNameFor(eventId);
  let cameras: unknown[] = [];
  try {
    const participants = await roomService.listParticipants(roomName);
    cameras = participants
      .filter((p) => parseMeta(p.metadata).role === "camera")
      .map((p) => {
        const meta = parseMeta(p.metadata);
        return {
          identity: p.identity,
          name: p.name,
          cameraName: meta.cameraName,
          cameraId: meta.cameraId,
        };
      });
  } catch {
    cameras = []; // room not up yet → no cameras
  }

  return json({ cameras });
}

// set-master-audio (was POST /api/set-master-audio) — re-assign master flag
async function setMasterAudio(body: any, userId: string, admin: any): Promise<Response> {
  const { eventId, cameraIdentity } = body;
  if (!eventId || !cameraIdentity) {
    return json({ error: "eventId and cameraIdentity are required" }, 400);
  }

  const gate = await requireOperator(eventId, userId, admin);
  if (gate instanceof Response) return gate;

  const roomName = roomNameFor(eventId);
  const participants = await roomService.listParticipants(roomName);

  await Promise.all(
    participants.map(async (p) => {
      const meta = parseMeta(p.metadata);
      if (meta.role !== "camera") return;
      const updated = { ...meta, isMasterAudio: p.identity === cameraIdentity };
      await roomService.updateParticipant(roomName, p.identity, {
        metadata: JSON.stringify(updated),
      });
    }),
  );

  return json({ success: true });
}

// start-show — stamp a single, stable wall-clock anchor for the whole show.
//
// When the host presses Start Show, write showStartedAt into the LiveKit room
// metadata. The viewer reads this anchor plus each publisher's joinedAt to
// align switchable camera angles against the master-audio timeline. Existing
// room metadata (eventName, eventId) is preserved.
async function startShow(body: any, userId: string, admin: any): Promise<Response> {
  const { eventId } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  const gate = await requireOperator(eventId, userId, admin);
  if (gate instanceof Response) return gate;

  const roomName = roomNameFor(eventId);
  let meta: Record<string, unknown> = {};
  try {
    const rooms = await roomService.listRooms([roomName]);
    if (rooms[0]) meta = parseMeta(rooms[0].metadata);
  } catch {
    // Room metadata unreadable — fall back to a bare anchor.
  }

  await roomService.updateRoomMetadata(
    roomName,
    JSON.stringify({ ...meta, showStartedAt: Date.now() }),
  );

  return json({ success: true });
}

// viewer-token (was POST /api/viewer-token) — JWT-derived identity + mode seam
async function viewerToken(body: any, userId: string, admin: any): Promise<Response> {
  const { eventId } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  // userId comes from the verified JWT, NOT the body — closes the old spoofing
  // hole (3.3). `eventId` is the LiveKit slug (events.livekit_room), not the PK.
  const { data: event, error } = await admin
    .from("events")
    .select("id, host_id, status, livekit_room, price")
    .eq("livekit_room", eventId)
    .maybeSingle();

  if (error || !event) return json({ error: "Event not found" }, 404);
  // Viewers may connect once the show is live OR while the host is in Sound Check
  // (they wait in the Lobby until status flips to 'live'). 'scheduled'/'ended'
  // still reject. The same paid-ticket gate below applies in both phases.
  if (event.status !== "live" && event.status !== "soundcheck") {
    return json({ error: "Event is not currently live" }, 403);
  }

  // Paid events require a paid ticket — unless the viewer is the host or an
  // assigned camera operator, who both get free access. Look the ticket up
  // separately so a missing ticket never nulls out the event row (an embedded
  // left-join filter on tickets.user_id did exactly that for free events).
  if (event.price && event.price > 0) {
    const isCrew = await isAuthorizedOperator(
      { id: event.id, host_id: event.host_id },
      userId,
      admin,
    );
    if (!isCrew) {
      const { data: ticket } = await admin
        .from("tickets")
        .select("status")
        .eq("event_id", event.id)
        .eq("buyer_id", userId)
        .maybeSingle();
      if (!ticket || ticket.status !== "paid") {
        return json({ error: "A valid ticket is required to join this event" }, 403);
      }
    }
  }

  // Must match how cameras/audio join: roomNameFor(slug) = `nile-event-<slug>`.
  // events.livekit_room stores the bare slug, so using it here put viewers in a
  // DIFFERENT room than the publishers (viewer saw 0 participants).
  const roomName = roomNameFor(eventId);
  const token = await buildToken({
    identity: `viewer-${userId}`,
    name: `Viewer ${userId}`,
    roomName,
    canPublish: false,
    canSubscribe: true,
    metadata: JSON.stringify({ role: "viewer", userId }),
  });

  // Typed connection descriptor (3.2). Always "webrtc" today; the same shape
  // can return { mode: "hls", manifestUrl } at much higher scale with no app
  // re-architecture.
  return json({ mode: "webrtc", token, wsUrl: LIVEKIT_URL });
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
