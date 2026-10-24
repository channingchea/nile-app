// Supabase Edge Function: livekit
//
// Consolidates the former Express backend (nile-backend) into one action-routed
// Edge Function. Handles LiveKit room creation and access-token minting for the
// multicam streaming experience: switchable, synchronized camera angles with a
// master-audio source, plus ticket-gated viewer access.
//
// One function, routed on `action` in the request body (section 3.1):
//   create-room       host    → { roomName, eventName }
//   camera-token      host    → { token, wsUrl, isMasterAudio, slotId, cameraName }
//   audio-token       host    → { token, wsUrl }
//   studio-token      host    → { token, wsUrl, isMasterAudio }   ← desktop Studio joins as control room
//   studio-camera     host    → { success, slotId, cameraName }  ← Studio turns its own webcam on/off
//   list-slots        crew    → { slots: [...], streamAudioTaken } ← "Which camera is this?"
//   rename-camera     host    → { success: true }   ← renames a slot + its live feed
//   list-cameras      host    → { cameras: [{ identity, name, cameraName, cameraId }] }
//   set-master-audio  host    → { success: true }   ← any publisher; exactly one holds the flag
//   set-graphics      host    → { success: true }   ← Studio pushes on-screen graphics (room metadata)
//   set-element       host    → { success, element } ← Studio pushes one live element (state + metadata)
//   list-elements     host    → { elements, serverNow } ← Studio reloads every element's live state
//   set-layout        host    → { success: true }   ← per-camera spots + layer order (room metadata)
//   respond           viewer  → { success, mine }   ← a viewer taps a live element (vote; changeable until close)
//   my-responses      viewer  → { mine }            ← the caller's own taps this show (rejoin)
//   resync            host    → { success, resyncAt } ← every viewer re-aligns cameras + audio
//   clock             any     → { receivedAt, sentAt } ← RealSync clock ping (server ms)
//   report-clock      crew    → { success: true }   ← publisher's clock offset into its metadata
//   remove-participant host   → { success: true }   ← ejects one participant
//   set-ready         crew    → { success: true }   ← flags caller's feed ready
//   start-show        host    → { success: true }   ← stamps showStartedAt anchor + starts replay egress
//   stop-egress       host    → { success: true }   ← stops replay egress on show end
//   replay-exists     viewer  → { available: bool } ← is a ready replay viewable by caller? (drives the CTA)
//   replay-url        viewer  → { url, durationMs }  ← signed playback URL (ticket-gated)
//   replay-grid       viewer  → { url, durationMs, marks } ← grid replay + overlay timeline (same gate)
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
import { corsHeaders as corsHeadersFor } from "../_shared/cors.ts";
import { failure } from "../_shared/errors.ts";
import {
  cleanCameraName,
  flagsToClear,
  isPublisher,
  joinTakesMasterAudio,
  liveCameraCount,
  type Peer,
  resolveSlot,
  type Slot,
  slotHolders,
  studioConnected,
  studioIdentity,
} from "../_shared/studio.ts";
import { mergeRoomMeta, resyncWait, type SponsorInfo, validateGraphics } from "../_shared/graphics.ts";
import {
  buildRow,
  contentAt,
  elementAngleIds,
  type ElementRow,
  openChoices,
  shapeTally,
  validateResponse,
  ELEMENT_KINDS,
  liveSnapshot,
  MAX_ELEMENTS_JSON,
  MAX_LIVE_ELEMENTS,
  rowToLive,
  validateElementPush,
  validateLayout,
} from "../_shared/elements.ts";
import { cleanShowPatch, planReorder } from "../_shared/show.ts";
import { timelineOf } from "../_shared/replay_marks.ts";

// CORS headers are per-request, so the JSON responder is built per-request too
// and handed to the helpers below (they run outside the handler's scope).
type Json = (body: unknown, status?: number) => Response;
const makeJson = (cors: Record<string, string>): Json =>
  (body, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });
import {
  AccessToken,
  EgressClient,
  EncodedFileOutput,
  EncodedFileType,
  EncodingOptionsPreset,
  RoomServiceClient,
  S3Upload,
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
const egressClient = new EgressClient(LIVEKIT_HTTP_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET);

// Replay egress → Supabase Storage 'replays' bucket via its S3-compatible
// endpoint. These secrets are set alongside the LiveKit ones (see header §3.4):
//   REPLAYS_S3_ENDPOINT   = https://<project-ref>.storage.supabase.co/storage/v1/s3
//   REPLAYS_S3_REGION     = e.g. us-east-1 (Supabase storage region)
//   REPLAYS_S3_ACCESS_KEY / REPLAYS_S3_SECRET_KEY  (Supabase storage S3 access keys)
const REPLAYS_S3_ENDPOINT = Deno.env.get("REPLAYS_S3_ENDPOINT") ?? "";
const REPLAYS_S3_REGION = Deno.env.get("REPLAYS_S3_REGION") ?? "us-east-1";
const REPLAYS_S3_ACCESS_KEY = Deno.env.get("REPLAYS_S3_ACCESS_KEY") ?? "";
const REPLAYS_S3_SECRET_KEY = Deno.env.get("REPLAYS_S3_SECRET_KEY") ?? "";
const REPLAYS_BUCKET = "replays";
// Nile's recorder page (recorder/index.html, hosted on R2). Unset = no grid
// replay; the combined recording alone still runs.
const REPLAY_RECORDER_URL = Deno.env.get("REPLAY_RECORDER_URL") ?? "";

// Signed replay URLs are valid for the recording's own length plus slack, held
// between a floor and the old flat ceiling. See replayUrl() for the reasoning.
const REPLAY_URL_SLACK_SECONDS = 10 * 60;
const REPLAY_URL_MIN_TTL_SECONDS = 10 * 60;
const REPLAY_URL_MAX_TTL_SECONDS = 4 * 60 * 60;

// ── Helpers ───────────────────────────────────────────────────────────────────

function roomNameFor(eventId: string) {
  return `nile-event-${eventId}`;
}

// What a room actually holds, and how much of that is not for sale. The host,
// every camera operator, a Stream Audio operator and the egress recorder all
// occupy participant slots, so the number of tickets we can honour is strictly
// less than the room ceiling. MAX_VIEWERS is the number the DB CHECK on
// events.ticket_limit and the create-event form both enforce (migration 0105).
const ROOM_CAPACITY = 1050;
const CREW_HEADROOM = 50;
const MAX_VIEWERS = ROOM_CAPACITY - CREW_HEADROOM;

/**
 * Make sure the room exists before a publisher joins, sized to what this event
 * actually sold.
 *
 * The room used to be created exactly once, from the create-event flow — often
 * days before the show — and `emptyTimeout` then tore it down long before
 * anyone arrived. Shows still worked, because LiveKit auto-creates a room when
 * the first valid token joins, but it comes up with LiveKit's defaults: the
 * maxParticipants ceiling set at creation was, in practice, almost never the
 * one in force. Calling this on every publisher mint is what makes the cap real.
 *
 * Safe to call repeatedly, including mid-show: LiveKit's CreateRoom returns an
 * existing room untouched rather than reconfiguring it, so this cannot clobber
 * the `showStartedAt` anchor that start-show writes into the same metadata.
 */
async function ensureRoom(slug: string, admin: any): Promise<void> {
  try {
    const { data: ev } = await admin
      .from("events")
      .select("title, ticket_limit")
      .eq("livekit_room", slug)
      .maybeSingle();
    const limit = (ev?.ticket_limit as number | null) ?? null;
    await roomService.createRoom({
      name: roomNameFor(slug),
      emptyTimeout: 1800, // close after 30 min idle
      // A capped event gets its seats plus crew headroom; an uncapped one gets
      // the whole room. Either way LiveKit enforces the ceiling, not just our
      // own seat counting.
      maxParticipants: limit != null
        ? Math.min(ROOM_CAPACITY, limit + CREW_HEADROOM)
        : ROOM_CAPACITY,
      metadata: JSON.stringify({ eventName: ev?.title ?? "", eventId: slug }),
    });
  } catch (err) {
    // Never block a publisher over this. Without it LiveKit auto-creates the
    // room on join, which is exactly the behaviour that shipped before.
    log("warn", { action: "ensure-room", slug, error: String(err) });
  }
}

// How long a freshly minted token may be used to JOIN, in seconds. The SDK
// default is six hours, which is roughly "the whole show" — a token lifted out
// of a network log or a jailbroken client stayed good until the event was over.
// Nothing here needs a long life: every join and rejoin path in the app mints a
// fresh token immediately before connecting, so the token is used seconds after
// it is issued.
//
// This bounds how long a leaked token lets someone IN. It does NOT disconnect a
// session already in progress — LiveKit checks the TTL at join and never again.
// Cutting off someone already connected is what remove-participant is for.
const TOKEN_TTL_SECONDS = 15 * 60;

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
    ttl: TOKEN_TTL_SECONDS,
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

/** Everyone in the room with their parsed metadata. Empty if the room is not up. */
async function peersOf(roomName: string): Promise<Peer[]> {
  try {
    const ps = await roomService.listParticipants(roomName);
    return ps.map((p) => ({ identity: p.identity, meta: parseMeta(p.metadata) }));
  } catch {
    return [];
  }
}

async function roomMetaOf(roomName: string): Promise<Record<string, unknown>> {
  try {
    const rooms = await roomService.listRooms([roomName]);
    return rooms[0] ? parseMeta(rooms[0].metadata) : {};
  } catch {
    return {};
  }
}

/** Merge [patch] into a participant's metadata (and optionally rename it). */
async function patchPeer(roomName: string, peer: Peer, patch: Record<string, unknown>, name?: string) {
  const metadata = JSON.stringify({ ...peer.meta, ...patch });
  peer.meta = { ...peer.meta, ...patch };
  await roomService.updateParticipant(roomName, peer.identity, name ? { metadata, name } : { metadata });
}

/** Exactly one publisher carries isMasterAudio — drop it from everyone but [keep]. */
async function clearMasterFlags(roomName: string, peers: Peer[], keep: string) {
  await Promise.all(
    flagsToClear(peers, keep).map((p) =>
      patchPeer(roomName, p, { isMasterAudio: false }).catch((err) =>
        log("warn", { action: "clear-master", identity: p.identity, error: String(err) })
      )
    ),
  );
}

/** Decide the master-audio flag for a publisher about to join, clearing others if it takes it. */
async function masterFlagOnJoin(
  roomName: string,
  identity: string,
  role: "camera" | "master-audio" | "studio",
  peers: Peer[],
): Promise<boolean> {
  const chosen = (await roomMetaOf(roomName)).masterAudio;
  const take = joinTakesMasterAudio({ identity, role, peers, chosen });
  if (take) await clearMasterFlags(roomName, peers, identity);
  return take;
}

async function slotsFor(eventPk: string, admin: any): Promise<Slot[]> {
  const { data } = await admin
    .from("event_cameras")
    .select("id, slot_index, label")
    .eq("event_id", eventPk)
    .order("slot_index");
  return (data ?? []) as Slot[];
}

async function usernameOf(userId: string, admin: any): Promise<string | null> {
  const { data } = await admin.from("profiles").select("username").eq("id", userId).maybeSingle();
  return (data?.username as string | undefined) ?? null;
}

/** "iPhone" / "iPad" / "Android" / "Mac" — a label only, so anything short goes. */
const deviceLabel = (raw: unknown) =>
  typeof raw === "string" && raw.length > 0 && raw.length <= 20 ? raw : null;

// ── Structured logging (roadmap #4 observability) ─────────────────────────────
//
// One JSON line per request — searchable in the Supabase logs explorer, e.g.:
//   event_message LIKE '%"level":"error"%'  or  '%"action":"viewer-token"%'
// Fields: level, fn, reqId, action, userId, status, ms (+ error/stack on 500).

interface ReqCtx {
  reqId: string;
  /** Server time the request arrived — the RealSync clock ping's T2. */
  receivedAt: number;
  action?: string;
  userId?: string;
}

function log(level: "info" | "warn" | "error", fields: Record<string, unknown>) {
  console.log(JSON.stringify({ level, fn: "livekit", ...fields }));
}

// ── Handler ───────────────────────────────────────────────────────────────────

serve(async (req) => {
  // Per-request CORS (fix #4): allowlisted origins only — see _shared/cors.ts.
  const corsHeaders = corsHeadersFor(req);
  const json = makeJson(corsHeaders);
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const ctx: ReqCtx = { reqId: crypto.randomUUID().slice(0, 8), receivedAt: Date.now() };
  const t0 = Date.now();
  try {
    const res = await handle(req, ctx, json);
    log(res.status < 400 ? "info" : "warn", {
      reqId: ctx.reqId,
      action: ctx.action,
      userId: ctx.userId,
      status: res.status,
      ms: Date.now() - t0,
    });
    return res;
  } catch (err) {
    log("error", {
      reqId: ctx.reqId,
      action: ctx.action,
      userId: ctx.userId,
      status: 500,
      ms: Date.now() - t0,
      error: String(err),
      stack: err instanceof Error ? err.stack : undefined,
    });
    return json(failure(err, "livekit"), 500);
  }
});

async function handle(req: Request, ctx: ReqCtx, json: Json): Promise<Response> {
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
  ctx.userId = user.id;

  // Service-role client for server-side checks that bypass RLS.
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const body = await req.json().catch(() => ({}));
  const action = body.action as string | undefined;
  if (!action) return json({ error: "Missing action" }, 400);
  ctx.action = action;

  switch (action) {
    case "create-room":
      return await createRoom(body, user.id, admin, json);
    case "camera-token":
      return await cameraToken(body, user.id, admin, json);
    case "audio-token":
      return await audioToken(body, user.id, admin, json);
    case "studio-token":
      return await studioToken(body, user.id, admin, json);
    case "studio-camera":
      return await studioCamera(body, user.id, admin, json);
    case "list-slots":
      return await listSlots(body, user.id, admin, json);
    case "rename-camera":
      return await renameCamera(body, user.id, admin, json);
    case "clock":
      // NTP-style: arrival and reply times bracket the auth work above, so the
      // client can take it out of the round trip.
      return json({ receivedAt: ctx.receivedAt, sentAt: Date.now() });
    case "report-clock":
      return await reportClock(body, user.id, admin, json);
    case "set-graphics":
      return await setGraphics(body, user.id, admin, json);
    case "set-element":
      return await setElement(body, user.id, admin, json);
    case "list-elements":
      return await listElements(body, user.id, admin, json);
    case "set-layout":
      return await setLayout(body, user.id, admin, json);
    case "respond":
      return await respond(body, user.id, admin, json);
    case "my-responses":
      return await myResponses(body, user.id, admin, json);
    case "set-show":
      return await setShow(body, user.id, admin, json);
    case "reorder-cameras":
      return await reorderCameras(body, user.id, admin, json);
    case "resync":
      return await resync(body, user.id, admin, json);
    case "list-cameras":
      return await listCameras(body, user.id, admin, json);
    case "set-master-audio":
      return await setMasterAudio(body, user.id, admin, json);
    case "remove-participant":
      return await removeParticipant(body, user.id, admin, json);
    case "set-ready":
      return await setReady(body, user.id, admin, json);
    case "start-show":
      return await startShow(body, user.id, admin, json);
    case "stop-egress":
      return await stopEgress(body, user.id, admin, json);
    case "replay-exists":
      return await replayExists(body, user.id, admin, json);
    case "replay-url":
      return await replayUrl(body, user.id, admin, json);
    case "replay-grid":
      return await replayGrid(body, user.id, admin, json);
    case "viewer-token":
      return await viewerToken(body, user.id, admin, json);
    case "reconcile-viewers":
      return await reconcileViewers(body, user.id, admin, json);
    default:
      return json({ error: `Unknown action: ${action}` }, 400);
  }
}

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
  json: Json,
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

/**
 * Host-only gate, for the actions that are not merely "operate this event" but
 * "decide the shape of the show" — starting it, and finalizing the recording.
 *
 * requireOperator() authorizes any assigned operator, which is right for
 * publishing a camera and wrong for these two: an operator could stop the egress
 * mid-show and truncate the replay the host later sells.
 */
async function requireHost(
  eventId: string,
  userId: string,
  admin: ReturnType<typeof createClient>,
  json: Json,
): Promise<{ event: { id: string; host_id: string; livekit_room: string | null } } | Response> {
  const gate = await requireOperator(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;
  if (gate.event.host_id !== userId) {
    return json({ error: "Forbidden — only the host can do this" }, 403);
  }
  return gate;
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
async function createRoom(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId, eventName } = body;
  if (!eventId || !eventName) {
    return json({ error: "eventId and eventName are required" }, 400);
  }

  // E21: "any signed-in user" was the whole authorization, with no check that
  // the slug was unclaimed and no rate limit.
  //
  // Claim check: if an event already owns this slug and it isn't the caller's,
  // creating the room would let a stranger set the metadata on — and then join
  // — someone else's show.
  const { data: claimed } = await admin
    .from("events")
    .select("host_id")
    .eq("livekit_room", eventId)
    .maybeSingle();
  if (claimed && claimed.host_id !== userId) {
    return json({ error: "That room id is already taken" }, 409);
  }

  // Rate limit: rooms are created just before the draft row is written, so the
  // caller's recent event count is a good proxy. Generous enough that no real
  // host will meet it, tight enough that a script can't churn rooms.
  const hourAgo = new Date(Date.now() - 3600_000).toISOString();
  const { count: recent } = await admin
    .from("events")
    .select("id", { count: "exact", head: true })
    .eq("host_id", userId)
    .gte("created_at", hourAgo);
  if ((recent ?? 0) > 30) {
    return json({ error: "Too many events created — try again later" }, 429);
  }

  // The events row does not exist yet (see the note above), so there is no
  // ticket_limit to size against — take the whole room for now. ensureRoom()
  // applies the real per-event ceiling when the first publisher joins, which is
  // also the point at which this room has usually expired and been recreated.
  const roomName = roomNameFor(eventId);
  await roomService.createRoom({
    name: roomName,
    emptyTimeout: 1800, // close after 30 min idle
    maxParticipants: ROOM_CAPACITY,
    metadata: JSON.stringify({ eventName, eventId }),
  });

  return json({ roomName, eventName });
}

// camera-token (was POST /api/camera-token)
//
// Body: { eventId, cameraId, cameraName, monitor?, slotId?, device? }
// `slotId` is the event_cameras row the device picked in "Which camera is
// this?". Without it the slot comes from the caller's crew assignment, then a
// label match on cameraName (older builds), then the first open slot — see
// resolveSlot(). A resolved slot's label becomes the camera's name.
async function cameraToken(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId, cameraId, cameraName, monitor, slotId } = body;
  if (!eventId || !cameraId || !cameraName) {
    return json({ error: "eventId, cameraId, and cameraName are required" }, 400);
  }

  const gate = await requireOperator(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;

  // Publishers are the first to arrive, so this is where the room gets built
  // with the right ceiling for this event.
  await ensureRoom(eventId, admin);

  const roomName = roomNameFor(eventId);
  const identity = `camera-${cameraId}`;
  const peers = await peersOf(roomName);
  const isHost = gate.event.host_id === userId;

  // C9: camera_count is what the host is priced on — a "free, single-camera"
  // event could run five publishers because nothing checked at mint time. Count
  // the feeds already in the room (cameras, plus the Studio's own webcam) and
  // refuse the one that would exceed it. A publisher rejoining reuses its own
  // cameraId, so a reconnect never counts twice.
  const { data: cfg } = await admin
    .from("events")
    .select("camera_count")
    .eq("id", gate.event.id)
    .maybeSingle();
  const cameraLimit = Math.max(1, (cfg?.camera_count as number | null) ?? 1);
  const live = liveCameraCount(peers, identity);
  if (live >= cameraLimit) {
    return json(
      {
        error:
          `This event is set up for ${cameraLimit} camera${cameraLimit === 1 ? "" : "s"}, ` +
          `and ${live} ${live === 1 ? "is" : "are"} already connected.`,
      },
      409,
    );
  }

  // Slot. Crew land on the slot the host assigned them; an explicit pick is
  // honoured or refused, never silently moved.
  let assignedSlotId: string | null = null;
  if (!slotId && !isHost) {
    const { data: op } = await admin
      .from("event_operators")
      .select("camera_id")
      .eq("event_id", gate.event.id)
      .eq("operator_id", userId)
      .maybeSingle();
    assignedSlotId = (op?.camera_id as string | null) ?? null;
  }
  const picked = resolveSlot({
    slots: await slotsFor(gate.event.id, admin),
    peers,
    identity,
    slotId,
    assignedSlotId,
    cameraName,
  });
  if ("missing" in picked) return json({ error: "That camera slot no longer exists" }, 404);
  if ("conflict" in picked) {
    return json({ error: `${picked.conflict.label} is already in use on another device.` }, 409);
  }
  const slot = picked.slot;
  const name = slot?.label ?? cameraName;

  // The HOST's camera may also subscribe, and only when it asks to. This feeds
  // the macOS Studio's monitor wall — a host has to see every crew feed to run
  // the show. Operators stay publish-only: they point one camera and have no UI
  // for the others, so subscribe rights would only cost them bandwidth.
  //
  // ⚠️ `monitor` is NOT redundant with the host check, and removing it breaks
  // shipped clients. LiveKit's ConnectOptions default to autoSubscribe: true,
  // so any build that predates the Studio would silently start pulling every
  // crew feed it has no way to render the moment this grant appeared — on a
  // host's phone, mid-show. Clients that manage their own subscriptions
  // (autoSubscribe: false + an explicit subscribe pass) send this flag; older
  // ones never do and keep exactly the behaviour they shipped with.
  const canMonitor = isHost && monitor === true;

  const isMasterAudio = await masterFlagOnJoin(roomName, identity, "camera", peers);

  const token = await buildToken({
    identity,
    name,
    roomName,
    canPublish: true,
    canSubscribe: canMonitor,
    // joinedAt is server-stamped (no device clock skew) so the viewer can align
    // this camera against the master-audio timeline. A fresh token on rejoin =
    // a fresh joinedAt automatically.
    // userId (from the verified JWT) lets the host's crew panel and set-ready
    // match this publisher to the assigned-operator roster. ready starts false
    // on every fresh token, so a reconnect naturally resets readiness.
    // slotId / username / device drive the Studio's slot-ordered source list.
    metadata: JSON.stringify({
      role: "camera",
      cameraId,
      cameraName: name,
      isMasterAudio,
      joinedAt: Date.now(),
      userId,
      ready: false,
      slotId: slot?.id ?? null,
      username: await usernameOf(userId, admin),
      device: deviceLabel(body.device),
    }),
  });

  return json({ token, wsUrl: LIVEKIT_URL, isMasterAudio, slotId: slot?.id ?? null, cameraName: name });
}

// audio-token (was POST /api/audio-token) — audio-only master publisher
async function audioToken(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  const gate = await requireOperator(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;

  // Same reason as camera-token: a Stream Audio operator may be the first
  // publisher in, so the room has to be built correctly here too.
  await ensureRoom(eventId, admin);

  const roomName = roomNameFor(eventId);
  const identity = `master-audio-${eventId}`;
  // Stream Audio carries the show's sound unless the host picked another
  // source that is still in the room (joinTakesMasterAudio).
  const isMasterAudio = await masterFlagOnJoin(roomName, identity, "master-audio", await peersOf(roomName));
  const token = await buildToken({
    identity,
    name: "Stream Audio",
    roomName,
    canPublish: true,
    canSubscribe: false,
    // joinedAt is the zero reference for camera-sync offsets (see viewer side).
    // userId + ready: see camera-token.
    metadata: JSON.stringify({
      role: "master-audio",
      joinedAt: Date.now(),
      userId,
      ready: false,
      isMasterAudio,
      username: await usernameOf(userId, admin),
      device: deviceLabel(body.device),
    }),
  });

  return json({ token, wsUrl: LIVEKIT_URL });
}

// studio-token — the host's desktop Studio joins as the show's control room.
//
// Not a camera: it doesn't count toward camera_count until its own webcam is
// turned on (studio-camera). The identity is fixed per event, so opening the
// Studio on a second Mac evicts the first (LiveKit drops the older session
// with DUPLICATE_IDENTITY) — a show has one control room. While it is in the
// room, the host's phones act as camera operators and start-show / stop-egress
// are refused from anywhere else.
async function studioToken(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  const gate = await requireHost(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;

  await ensureRoom(eventId, admin);

  const roomName = roomNameFor(eventId);
  const identity = studioIdentity(eventId);
  const isMasterAudio = await masterFlagOnJoin(roomName, identity, "studio", await peersOf(roomName));
  const token = await buildToken({
    identity,
    name: "Studio",
    roomName,
    canPublish: true,
    // The Studio's monitor wall. Studio builds connect with autoSubscribe off
    // and subscribe per feed, so the grant never costs an old client anything.
    canSubscribe: true,
    metadata: JSON.stringify({
      role: "studio",
      cameraName: "Studio",
      hasCamera: false,
      isMasterAudio,
      joinedAt: Date.now(),
      userId,
      username: await usernameOf(userId, admin),
      device: deviceLabel(body.device),
    }),
  });

  return json({ token, wsUrl: LIVEKIT_URL, isMasterAudio });
}

// studio-camera — the Studio turns its own webcam on or off.
//
// Body: { eventId, enabled }. Turning it on counts toward camera_count (and is
// refused if the event is full) and takes the first open slot, so the Studio's
// camera shows up — and can be renamed — like any other.
async function studioCamera(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId, enabled } = body;
  if (!eventId || typeof enabled !== "boolean") {
    return json({ error: "eventId and enabled (boolean) are required" }, 400);
  }

  const gate = await requireHost(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;

  const roomName = roomNameFor(eventId);
  const identity = studioIdentity(eventId);
  const peers = await peersOf(roomName);
  const studio = peers.find((p) => p.identity === identity);
  if (!studio) return json({ error: "The Studio isn't connected" }, 409);

  if (!enabled) {
    await patchPeer(roomName, studio, { hasCamera: false, slotId: null, cameraName: "Studio" }, "Studio");
    return json({ success: true, slotId: null, cameraName: "Studio" });
  }

  const { data: cfg } = await admin
    .from("events")
    .select("camera_count")
    .eq("id", gate.event.id)
    .maybeSingle();
  const cameraLimit = Math.max(1, (cfg?.camera_count as number | null) ?? 1);
  const live = liveCameraCount(peers, identity);
  if (live >= cameraLimit) {
    return json(
      {
        error: `All ${cameraLimit} camera${cameraLimit === 1 ? "" : "s"} for this event are in use. ` +
          `Add a camera on the event page to use this one too.`,
      },
      409,
    );
  }

  const picked = resolveSlot({ slots: await slotsFor(gate.event.id, admin), peers, identity });
  const slot = "slot" in picked ? picked.slot : null;
  const name = slot?.label ?? "Studio";
  await patchPeer(roomName, studio, { hasCamera: true, slotId: slot?.id ?? null, cameraName: name }, name);
  return json({ success: true, slotId: slot?.id ?? null, cameraName: name });
}

// list-slots — the event's camera slots and who holds each, for the host
// phone's "Which camera is this?" sheet and the Studio's slot-ordered list.
async function listSlots(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  const gate = await requireOperator(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;

  const peers = await peersOf(roomNameFor(eventId));
  const held = slotHolders(peers);
  const slots = (await slotsFor(gate.event.id, admin)).map((s) => {
    const p = held.get(s.id);
    return {
      id: s.id,
      slotIndex: s.slot_index,
      label: s.label,
      heldBy: p?.identity ?? null,
      heldByUsername: (p?.meta.username as string | undefined) ?? null,
      heldByDevice: (p?.meta.device as string | undefined) ?? null,
    };
  });
  return json({
    slots,
    streamAudioTaken: peers.some((p) => p.meta.role === "master-audio"),
  });
}

// rename-camera — rename a slot (and the feed on it) on the fly.
//
// Body: { eventId, name, slotId? , identity? }. With a slotId the slot's label
// is saved (it is the camera's name for the rest of the event) and whoever is
// on it is renamed live; with only an identity, just that live feed is renamed
// (a feed with no slot). Host only — the Studio is where it is offered.
async function renameCamera(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId, slotId, identity } = body;
  const name = cleanCameraName(body.name);
  if (!eventId || (!slotId && !identity)) {
    return json({ error: "eventId and a slotId or identity are required" }, 400);
  }
  if (!name) return json({ error: "Camera names are 1 to 40 characters" }, 400);

  const gate = await requireHost(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;

  if (slotId) {
    const { data, error } = await admin
      .from("event_cameras")
      .update({ label: name })
      .eq("id", slotId)
      .eq("event_id", gate.event.id)
      .select("id");
    if (error) throw error;
    if (!data?.length) return json({ error: "That camera slot no longer exists" }, 404);
  }

  const roomName = roomNameFor(eventId);
  const targets = (await peersOf(roomName)).filter((p) =>
    isPublisher(p) && ((slotId && p.meta.slotId === slotId) || (!slotId && p.identity === identity))
  );
  await Promise.all(targets.map((p) => patchPeer(roomName, p, { cameraName: name }, name)));
  return json({ success: true });
}

// list-cameras (was GET /api/event/:id/cameras) — feeds the viewer angle picker
async function listCameras(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  const gate = await requireOperator(eventId, userId, admin, json);
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

// set-master-audio — choose which publisher carries the show's sound.
//
// Body: { eventId, identity } (older builds send `cameraIdentity`). Any
// publisher qualifies: a camera, the Studio, or Stream Audio. Exactly one holds
// isMasterAudio afterwards, and the choice is written to room metadata
// (`masterAudio`) so that publisher reclaims audio if it drops and rejoins.
// Viewers route audio from the flag alone.
async function setMasterAudio(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId } = body;
  const target = (body.identity ?? body.cameraIdentity) as string | undefined;
  if (!eventId || !target) {
    return json({ error: "eventId and identity are required" }, 400);
  }

  const gate = await requireOperator(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;

  const roomName = roomNameFor(eventId);
  const peers = await peersOf(roomName);
  const chosen = peers.find((p) => p.identity === target && isPublisher(p));
  if (!chosen) return json({ error: "That source isn't connected" }, 404);

  await roomService.updateRoomMetadata(
    roomName,
    JSON.stringify({ ...(await roomMetaOf(roomName)), masterAudio: target }),
  );
  await clearMasterFlags(roomName, peers, target);
  if (chosen.meta.isMasterAudio !== true) await patchPeer(roomName, chosen, { isMasterAudio: true });

  return json({ success: true });
}

// set-graphics — the Studio puts graphics on (or takes them off) the air.
//
// Body: { eventId, studio: true, graphics: { all: [...], bySlot: { <slotId>: [...] } } }
// The Studio sends the whole on-air state; it is validated (shapes, caps: one
// lower third / logo per corner / banner / slate per target, images only from
// the studio-graphics bucket, real slots only) and written into the room
// metadata next to showStartedAt and the rest. Viewers read it from there —
// late joiners included — and never touch the host's library.
async function setGraphics(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  const gate = await requireHost(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;

  const roomName = roomNameFor(eventId);
  if (body.studio !== true || !studioConnected(await peersOf(roomName))) {
    return json({ error: "Graphics are run from the Studio." }, 409);
  }

  const slots = await slotsFor(gate.event.id, admin);
  const storage = `${Deno.env.get("SUPABASE_URL")}/storage/v1/object/public/`;
  const wantsSponsor = JSON.stringify(body.graphics ?? {}).includes('"sponsor"');
  const result = validateGraphics(body.graphics, {
    imagePrefix: `${storage}studio-graphics/`,
    avatarPrefix: storage,
    slotIds: new Set(slots.map((s) => s.id)),
    sponsor: wantsSponsor ? await sponsorFor(gate.event.id, admin, storage) : null,
  });
  if ("error" in result) return json({ error: result.error }, 400);

  // `at`: the moment the change refers to — viewers whose video runs further
  // behind hold it back so a graphic never lands before the picture does.
  const graphics = { ...result.state, at: contentAt(Date.now(), body.srcAgeMs) };
  const meta = await roomMetaOf(roomName);
  await roomService.updateRoomMetadata(roomName, JSON.stringify(mergeRoomMeta(meta, { graphics })));
  return json({ success: true, graphics });
}

// ── Live elements (studio-live-elements-foundation, phases 1-3) ───────────────

const ELEMENT_COLS = "event_id, element_id, kind, spec, state, version, content_at";

async function elementRows(eventPk: string, admin: any): Promise<ElementRow[]> {
  const { data, error } = await admin.from("live_element_state").select(ELEMENT_COLS).eq("event_id", eventPk);
  if (error) throw error;
  return (data ?? []) as ElementRow[];
}

/** Mirror the on-air elements into room metadata, if they changed. */
async function mirrorElements(roomName: string, rows: ElementRow[]) {
  const snap = liveSnapshot(rows);
  const meta = await roomMetaOf(roomName);
  if (JSON.stringify(meta.elements ?? null) === JSON.stringify(snap)) return;
  await roomService.updateRoomMetadata(roomName, JSON.stringify(mergeRoomMeta(meta, { elements: snap })));
}

// set-element — the Studio changes one live element (or removes it).
//
// Body: { eventId, studio: true, element: { id, kind, name, config, state,
//         style?, nileStyle?, targets, presentedBy?, version, clockOps?, srcAgeMs? } }
//    or { eventId, studio: true, remove: <element id> }.
// The element's live state is stored in live_element_state (the source of
// truth — a Studio that drops reloads from it) and every on-air element is
// mirrored into room metadata `elements`. A push must carry a version newer
// than the stored one; an older one is refused with 409 and the current
// element, so a Studio that fell out of step can catch up. Clocks are stamped
// here with the server's own time.
async function setElement(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  const gate = await requireHost(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;

  const roomName = roomNameFor(eventId);
  if (body.studio !== true || !studioConnected(await peersOf(roomName))) {
    return json({ error: "Elements are run from the Studio." }, 409);
  }

  const table = admin.from("live_element_state");
  let rows = await elementRows(gate.event.id, admin);

  if (typeof body.remove === "string") {
    const { error } = await table.delete().eq("event_id", gate.event.id).eq("element_id", body.remove);
    if (error) throw error;
    // Its votes go with it.
    await admin.from("element_responses").delete().eq("event_id", gate.event.id).eq("element_id", body.remove);
    await admin.from("element_tally_state").delete().eq("event_id", gate.event.id).eq("element_id", body.remove);
    rows = rows.filter((r) => r.element_id !== body.remove);
    await mirrorElements(roomName, rows);
    return json({ success: true });
  }

  const slots = await slotsFor(gate.event.id, admin);
  const wantsSponsor = typeof body.element?.presentedBy === "string";
  const storage = `${Deno.env.get("SUPABASE_URL")}/storage/v1/object/public/`;
  const sponsor = wantsSponsor ? await sponsorFor(gate.event.id, admin, storage) : null;
  const v = validateElementPush(body.element, {
    slotIds: new Set(slots.map((s) => s.id)),
    sponsorCampaignId: sponsor?.campaignId,
  });
  if ("error" in v) return json({ error: v.error }, 400);

  const prev = rows.find((r) => r.element_id === v.push.id);
  if (prev && prev.kind !== v.push.kind) return json({ error: "An element can't change kind" }, 400);
  if (!prev && rows.length >= MAX_LIVE_ELEMENTS) {
    return json({ error: `A show can run ${MAX_LIVE_ELEMENTS} elements at most` }, 400);
  }
  if (prev && v.push.version <= prev.version) {
    return json({ error: "stale", current: rowToLive(prev) }, 409);
  }

  const row = buildRow(gate.event.id, v.push, prev, Date.now());
  const next = [...rows.filter((r) => r.element_id !== row.element_id), row];
  if (JSON.stringify(liveSnapshot(next)).length > MAX_ELEMENTS_JSON) {
    return json({ error: "Too many elements on screen at once" }, 400);
  }

  // Conditional write: only over an older version, so two pushes racing can't
  // leave the older one standing.
  const values = { kind: row.kind, spec: row.spec, state: row.state, version: row.version, content_at: row.content_at, updated_at: new Date().toISOString() };
  if (prev) {
    const { data, error } = await table.update(values)
      .eq("event_id", row.event_id).eq("element_id", row.element_id).lt("version", row.version)
      .select("element_id");
    if (error) throw error;
    if (!data?.length) return json({ error: "stale", current: rowToLive(prev) }, 409);
  } else {
    const { error } = await table.insert({ event_id: row.event_id, element_id: row.element_id, ...values });
    if (error?.code === "23505") return json({ error: "stale" }, 409);
    if (error) throw error;
  }

  await mirrorElements(roomName, next);
  return json({ success: true, element: rowToLive(row) });
}

// list-elements — every element's live state for this event, on air or not:
// the Studio reloads from here when it (re)joins. Also re-mirrors the on-air
// ones into a room that came back up without them.
async function listElements(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  const gate = await requireHost(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;

  const rows = await elementRows(gate.event.id, admin);
  const roomName = roomNameFor(eventId);
  if (rows.length && (await peersOf(roomName)).length) await mirrorElements(roomName, rows);
  // Totals for anything viewers can tap — hosts see totals, never who voted what.
  const tallies: Record<string, Record<string, number>> = {};
  for (const r of rows) {
    const choices = ELEMENT_KINDS[r.kind]?.choices?.(r.spec?.config ?? {}) ?? [];
    if (choices.length) tallies[r.element_id] = await tallyOf(gate.event.id, r.element_id, choices, admin);
  }
  return json({ elements: rows.map(rowToLive), tallies, serverNow: Date.now() });
}

// ── Viewer taps (phase 5) ──────────────────────────────────────────────────────

async function tallyOf(eventPk: string, elementId: string, choices: string[], admin: any) {
  const { data, error } = await admin.rpc("element_tally", { p_event: eventPk, p_element: elementId });
  if (error) throw error;
  return shapeTally(choices, (data ?? {}) as Record<string, unknown>);
}

/** Server-authored message on the read-only system topic (0104: clients may read, never write). */
async function broadcastSystem(slug: string, event: string, payload: Record<string, unknown>) {
  try {
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/realtime/v1/api/broadcast`, {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: key, Authorization: `Bearer ${key}` },
      body: JSON.stringify({ messages: [{ topic: `live_system:${slug}`, event, payload, private: true }] }),
    });
    if (!res.ok) log("warn", { action: "broadcast", status: res.status, body: await res.text() });
  } catch (err) {
    log("warn", { action: "broadcast", error: String(err) });
  }
}

/** Totals into a running grid replay's timeline, so the replay shows them move. */
async function recordTally(eventPk: string, elementId: string, tally: Record<string, number>, admin: any) {
  const { data: grid } = await admin
    .from("replay_grids")
    .select("id")
    .eq("event_id", eventPk)
    .eq("status", "recording")
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (!grid) return;
  const { error } = await admin.from("replay_marks").insert({ grid_id: grid.id, kind: "tally", data: { elementId, tally } });
  if (error) log("warn", { action: "record-tally", error: error.message });
}

/**
 * Send an element's totals to everyone at most once a second. The first vote
 * after a quiet second goes out at once; votes inside the second schedule one
 * trailing send (element_tally_claim decides, atomically, across instances),
 * which recounts when it fires so the last vote is never left out.
 */
async function pushTally(eventPk: string, slug: string, elementId: string, choices: string[], admin: any) {
  const { data: wait, error } = await admin.rpc("element_tally_claim", { p_event: eventPk, p_element: elementId });
  if (error || typeof wait !== "number" || wait < 0) return;
  const send = async () => {
    if (wait > 0) {
      await new Promise((r) => setTimeout(r, wait));
      await admin.rpc("element_tally_sent", { p_event: eventPk, p_element: elementId });
    }
    const tally = await tallyOf(eventPk, elementId, choices, admin);
    await broadcastSystem(slug, "tally", { elementId, tally });
    await recordTally(eventPk, elementId, tally, admin);
  };
  if (wait === 0) return await send();
  // The trailing send outlives this request; keep the worker up for it.
  const later = send().catch((err) => log("warn", { action: "tally", error: String(err) }));
  // deno-lint-ignore no-explicit-any
  (globalThis as any).EdgeRuntime?.waitUntil?.(later);
}

/**
 * The same gate viewer-token applies, read from the database (no LiveKit call
 * per tap): the show is on, the caller isn't removed from it, and a paid show
 * needs a paid ticket. Crew always pass.
 */
async function viewerMayTap(
  eventId: string,
  userId: string,
  admin: any,
  json: Json,
): Promise<{ id: string } | Response> {
  const { data: event } = await admin
    .from("events")
    .select("id, host_id, status, price")
    .eq("livekit_room", eventId)
    .maybeSingle();
  if (!event) return json({ error: "Event not found" }, 404);
  if (event.status !== "live" && event.status !== "soundcheck") {
    return json({ error: "Event is not currently live" }, 403);
  }
  if (await isAuthorizedOperator({ id: event.id, host_id: event.host_id }, userId, admin)) return { id: event.id };
  const { data: ban } = await admin.from("live_chat_bans").select("user_id")
    .eq("event_id", event.id).eq("user_id", userId).maybeSingle();
  if (ban) return json({ error: "You've been removed from this event" }, 403);
  if (event.price && event.price > 0) {
    const { data: ticket } = await admin.from("tickets").select("status")
      .eq("event_id", event.id).eq("buyer_id", userId).maybeSingle();
    if (!ticket || ticket.status !== "paid") {
      return json({ error: "A valid ticket is required to join this event" }, 403);
    }
  }
  return { id: event.id };
}

// respond — a viewer taps an element (a vote). Body: { eventId, elementId, choice }.
// One vote per signed-in account per element, changeable until the element
// closes; at most one change a second. Nobody — host included — can read who
// voted what; totals go out on the system topic.
async function respond(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId, elementId } = body;
  if (!eventId || typeof elementId !== "string") return json({ error: "eventId and elementId are required" }, 400);

  const gate = await viewerMayTap(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;

  const { data: row } = await admin.from("live_element_state").select(ELEMENT_COLS)
    .eq("event_id", gate.id).eq("element_id", elementId).maybeSingle();
  const v = validateResponse(row ?? undefined, body.choice);
  if ("error" in v) return json({ error: v.error }, v.status);

  const { data: status, error } = await admin.rpc("element_respond", {
    p_event: gate.id,
    p_element: elementId,
    p_user: userId,
    p_choice: v.choice,
  });
  if (error) throw error;
  if (status === "slow") return json({ error: "Slow down a moment", retryAfterMs: 1000 }, 429);

  await pushTally(gate.id, eventId, elementId, openChoices(row), admin);
  return json({ success: true, mine: v.choice });
}

// my-responses — the caller's own taps in this show, so a viewer who rejoins
// sees what they picked. Body: { eventId }.
async function myResponses(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);
  const { data: event } = await admin.from("events").select("id").eq("livekit_room", eventId).maybeSingle();
  if (!event) return json({ error: "Event not found" }, 404);
  const { data, error } = await admin.from("element_responses").select("element_id, choice")
    .eq("event_id", event.id).eq("user_id", userId);
  if (error) throw error;
  const mine: Record<string, string> = {};
  for (const r of data ?? []) mine[r.element_id] = r.choice;
  return json({ mine });
}

// set-layout — where graphics and elements sit on each camera.
//
// Body: { eventId, studio: true, layout: { all?: [layer], bySlot: { <slotId>: [layer] } }, srcAgeMs? }
// layer = { id, spot?: tl|tc|tr|ml|mc|mr|bl|bc|br|full, hidden?: true }, top = front.
// The whole layout each time; written into room metadata `layout`.
async function setLayout(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  const gate = await requireHost(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;

  const roomName = roomNameFor(eventId);
  if (body.studio !== true || !studioConnected(await peersOf(roomName))) {
    return json({ error: "Layouts are run from the Studio." }, 409);
  }

  const slots = await slotsFor(gate.event.id, admin);
  const result = validateLayout(body.layout, new Set(slots.map((s) => s.id)));
  if ("error" in result) return json({ error: result.error }, 400);

  const layout = { ...result.layout, at: contentAt(Date.now(), body.srcAgeMs) };
  const meta = await roomMetaOf(roomName);
  await roomService.updateRoomMetadata(roomName, JSON.stringify(mergeRoomMeta(meta, { layout })));
  return json({ success: true, layout });
}

// The event's accepted Pre-Show sponsor — the only sponsor a Studio may put on
// screen, with its logo (ad-creatives bucket) and name looked up here so the
// image can't come from the Studio.
async function sponsorFor(eventId: string, admin: any, storage: string): Promise<SponsorInfo | null> {
  const { data } = await admin
    .from("ad_campaigns")
    .select("id, advertiser_accounts(name), ad_creatives(logo_path)")
    .eq("event_id", eventId)
    .eq("placement", "lobby")
    .in("status", ["active", "completed"])
    .limit(1)
    .maybeSingle();
  if (!data) return null;
  const acct = Array.isArray(data.advertiser_accounts) ? data.advertiser_accounts[0] : data.advertiser_accounts;
  const cr = Array.isArray(data.ad_creatives) ? data.ad_creatives[0] : data.ad_creatives;
  const logo = cr?.logo_path as string | undefined;
  return {
    campaignId: data.id,
    name: (acct?.name as string | undefined) ?? "our sponsor",
    logoUrl: logo ? `${storage}ad-creatives/${logo}` : undefined,
  };
}

// set-show — off-air angles, the default angle, and "Send everyone here".
//
// Body: { eventId, offAir?: [slotId], defaultSlot?: slotId|null, sendAll?: slotId }.
// Partial: only the keys sent change. Written into room metadata, which every
// viewer already follows: an off-air angle leaves their picker (anyone on it
// moves to the default), new viewers start on the default, and a new sendAll
// nonce moves everyone once. Host only — the Studio, or the host's phone.
async function setShow(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  const gate = await requireHost(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;

  const roomName = roomNameFor(eventId);
  const slots = await slotsFor(gate.event.id, admin);
  const meta = await roomMetaOf(roomName);
  // Element angles (`el:<id>`) take show control like cameras do.
  const ids = new Set([...slots.map((s) => s.id), ...elementAngleIds(meta)]);
  const result = cleanShowPatch(body, ids, meta, Date.now());
  if ("error" in result) return json({ error: result.error }, 400);

  await roomService.updateRoomMetadata(roomName, JSON.stringify(mergeRoomMeta(meta, result.patch)));
  return json({ success: true, ...result.patch });
}

// reorder-cameras — the host drags the Studio's camera tiles into a new order.
//
// Body: { eventId, order: [slotId] } naming every slot once. Rewrites
// event_cameras.slot_index in two passes (the (event_id, slot_index) unique
// constraint isn't deferrable, so everything moves out of the way first),
// renumbers default "Camera N" names, renames the feeds live, and writes
// `slotOrder` into room metadata so viewer pickers follow without a refetch.
async function reorderCameras(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  const gate = await requireHost(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;

  const slots = await slotsFor(gate.event.id, admin);
  const roomName = roomNameFor(eventId);
  const plan = planReorder(body.order, slots, elementAngleIds(await roomMetaOf(roomName)));
  if ("error" in plan) return json({ error: plan.error }, 400);

  // Pass 1: park every slot on a negative index. Pass 2: the real order.
  for (const [i, row] of plan.rows.entries()) {
    const { error } = await admin.from("event_cameras").update({ slot_index: -(i + 1) })
      .eq("id", row.id).eq("event_id", gate.event.id);
    if (error) throw error;
  }
  for (const row of plan.rows) {
    const { error } = await admin.from("event_cameras")
      .update({ slot_index: row.slot_index, label: row.label })
      .eq("id", row.id).eq("event_id", gate.event.id);
    if (error) throw error;
  }

  const before = new Map(slots.map((s) => [s.id, s.label]));
  const renamed = new Map(plan.rows.filter((r) => before.get(r.id) !== r.label).map((r) => [r.id, r.label]));
  const peers = await peersOf(roomName);
  await Promise.all(
    peers
      .filter((p) => isPublisher(p) && typeof p.meta.slotId === "string" && renamed.has(p.meta.slotId))
      .map((p) => {
        const name = renamed.get(p.meta.slotId as string)!;
        return patchPeer(roomName, p, { cameraName: name }, name);
      }),
  );
  const meta = await roomMetaOf(roomName);
  await roomService.updateRoomMetadata(
    roomName,
    JSON.stringify(mergeRoomMeta(meta, { slotOrder: plan.order })),
  );
  return json({ success: true, slots: plan.rows });
}

// report-clock — a publisher records its clock offset (device − server, ms) in
// its own metadata, for RealSync. Body: { eventId, identity, offsetMs, rttMs }.
// The identity must be one of the CALLER's publishers (userId in its token
// metadata) — nobody writes someone else's offset.
async function reportClock(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId, identity, offsetMs, rttMs } = body;
  if (!eventId || !identity || typeof offsetMs !== "number" || !Number.isFinite(offsetMs)) {
    return json({ error: "eventId, identity and offsetMs are required" }, 400);
  }
  if (Math.abs(offsetMs) > 24 * 3600_000) return json({ error: "offsetMs out of range" }, 400);

  const gate = await requireOperator(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;

  const roomName = roomNameFor(eventId);
  const peer = (await peersOf(roomName)).find((p) => p.identity === identity);
  if (!peer || !isPublisher(peer) || peer.meta.userId !== userId) {
    return json({ error: "Not your feed" }, 403);
  }
  await patchPeer(roomName, peer, {
    clockOffsetMs: Math.round(offsetMs),
    clockRttMs: typeof rttMs === "number" && Number.isFinite(rttMs) ? Math.round(rttMs) : null,
  });
  return json({ success: true });
}

// resync — every viewer drops and re-picks up the camera they're watching
// together with the show audio, re-measuring the offset between them.
//
// The Studio's call while it is in the room; the host's phone when it isn't.
// Stamps `resyncAt` (server time) into room metadata; viewers act on a stamp
// newer than their own join and ignore it otherwise, so old builds and late
// joiners are unaffected. Once per 10 s, because each one is a visible pause.
async function resync(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  const gate = await requireHost(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;

  const roomName = roomNameFor(eventId);
  if (body.studio !== true && studioConnected(await peersOf(roomName))) {
    return json({ error: "Your Studio is running this show — resync from the Studio." }, 409);
  }

  const meta = await roomMetaOf(roomName);
  const now = Date.now();
  const wait = resyncWait(meta.resyncAt, now);
  if (wait > 0) {
    return json({ error: `Just resynced — try again in ${Math.ceil(wait / 1000)} s.` }, 429);
  }
  await roomService.updateRoomMetadata(roomName, JSON.stringify(mergeRoomMeta(meta, { resyncAt: now })));
  return json({ success: true, resyncAt: now });
}

// remove-participant — eject one participant from the live room.
//
// Host-only. Until this existed the only moderation lever was ending the whole
// show: the ticket gate runs once, at mint, so a refunded ticket holder kept
// watching; a camera operator taken off the crew kept publishing; an abusive
// viewer could not be kicked. LiveKit closes their connection immediately.
//
// Whether they can come straight back is decided by the gate they next fail (or
// pass) in viewer-token / camera-token — a refunded ticket and a de-assigned
// operator are both refused there, so for those two this is final. A viewer
// kicked from a FREE event used to rejoin immediately; the `ban` action in the
// `live-chat` function is the one that makes it stick, and viewer-token now
// refuses anyone carrying a live_chat_bans row (#16 phase 1).
async function removeParticipant(
  body: any,
  userId: string,
  admin: any,
  json: Json,
): Promise<Response> {
  const { eventId, identity } = body;
  if (!eventId || !identity) {
    return json({ error: "eventId and identity are required" }, 400);
  }

  const gate = await requireHost(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;

  try {
    await roomService.removeParticipant(roomNameFor(eventId), identity);
  } catch (err) {
    // Already gone — they left, or a duplicate identity evicted them. The
    // caller wanted them out; they are out. Not an error worth failing on.
    log("warn", { action: "remove-participant", identity, error: String(err) });
  }

  return json({ success: true });
}

// set-ready — a crew member flags their own feed as ready (or not) during
// Sound Check. Self-targeted: we find the caller's publisher(s) by the userId
// stamped into their token metadata, never by an identity from the body.
async function setReady(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId, ready } = body;
  if (!eventId || typeof ready !== "boolean") {
    return json({ error: "eventId and ready (boolean) are required" }, 400);
  }

  const gate = await requireOperator(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;

  const roomName = roomNameFor(eventId);
  const participants = await roomService.listParticipants(roomName);

  await Promise.all(
    participants.map(async (p) => {
      const meta = parseMeta(p.metadata);
      if (meta.userId !== userId) return;
      await roomService.updateParticipant(roomName, p.identity, {
        metadata: JSON.stringify({ ...meta, ready }),
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
async function startShow(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  // Host-only (review C11): starting the show is the host's call, not an
  // operator's.
  const gate = await requireHost(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;
  // While the Studio is in the room it runs the show: a host phone (or an
  // older build that knows nothing about the Studio) can't start or finalize
  // it from the side. The Studio identifies itself with `studio: true`.
  if (body.studio !== true && studioConnected(await peersOf(roomNameFor(eventId)))) {
    return json({ error: "Your Studio is running this show — use the Studio's controls." }, 409);
  }

  const roomName = roomNameFor(eventId);
  let meta: Record<string, unknown> = {};
  try {
    const rooms = await roomService.listRooms([roomName]);
    if (rooms[0]) meta = parseMeta(rooms[0].metadata);
  } catch {
    // Room metadata unreadable — fall back to a bare anchor.
  }

  // Idempotent: if the show already has an anchor (host rejoining after a drop,
  // or a duplicate call), keep the original showStartedAt so the camera-sync
  // timeline never shifts for viewers, and skip a second egress.
  const existingAnchor = typeof meta.showStartedAt === "number"
    ? (meta.showStartedAt as number)
    : null;
  if (existingAnchor !== null) {
    // Report the real recording state even on the no-op path, so a host who
    // rejoined after a drop still sees the "not recording" warning if the
    // egress never came up on the first call.
    const { data: recording } = await admin
      .from("replays")
      .select("id")
      .eq("event_id", gate.event.id)
      .eq("status", "recording")
      .maybeSingle();
    log("info", { action: "start-show", note: "already started; no-op", eventId });
    return json({ success: true, alreadyStarted: true, egressStarted: !!recording });
  }

  const startedAt = Date.now();
  await roomService.updateRoomMetadata(
    roomName,
    JSON.stringify({ ...meta, showStartedAt: startedAt }),
  );

  // Kick off the composited replay recording. Still non-fatal — a failed egress
  // must never block the live show — but no longer silent. This used to swallow
  // both the "storage isn't configured" case and any start error, then return
  // {success: true} regardless, so a host learned there was no recording after
  // the show, with nothing to sell. `egressStarted` is what the Studio's
  // "not recording" warning is driven from.
  const { data: existingReplay } = await admin
    .from("replays")
    .select("id")
    .eq("event_id", gate.event.id)
    .eq("status", "recording")
    .maybeSingle();

  let egressStarted = true;
  if (!existingReplay) {
    egressStarted = await startReplayEgress(gate.event.id, roomName, startedAt, admin)
      .catch((err) => {
        log("error", { reqId: "-", action: "start-egress", error: String(err) });
        return false;
      });
  }

  return json({ success: true, egressStarted });
}

// Start Room Composite Egress → an MP4 in the 'replays' bucket, and record the
// pending replay row. One composited file (default layout = active-speaker mix).
async function startReplayEgress(
  eventPk: string,
  roomName: string,
  startedAt: number,
  admin: any,
): Promise<boolean> {
  if (!REPLAYS_S3_ENDPOINT || !REPLAYS_S3_ACCESS_KEY) {
    log("warn", { action: "start-egress", note: "replay storage not configured; skipping" });
    return false;
  }

  // Object path inside the bucket: <eventPk>/<startedAt>.mp4
  const filepath = `${eventPk}/${startedAt}.mp4`;
  const output = replayFile(filepath);

  // opts.layout = "speaker" → active-speaker composite. RoomCompositeOptions is
  // a plain options object (interface), not a constructed class.
  const info = await egressClient.startRoomCompositeEgress(
    roomName,
    { file: output },
    { layout: "speaker" },
  );

  const { data: replay } = await admin.from("replays").insert({
    event_id: eventPk,
    egress_id: info.egressId,
    status: "recording",
    playback_path: filepath,
    started_at: new Date(startedAt).toISOString(),
  }).select("id").single();

  // The grid replay (phase 6) rides alongside; it never decides egressStarted.
  if (replay?.id && REPLAY_RECORDER_URL) {
    await startGridEgress(eventPk, replay.id, roomName, startedAt, admin).catch((err) =>
      log("error", { reqId: "-", action: "start-grid-egress", error: String(err) })
    );
  }

  return true;
}

function replayFile(filepath: string) {
  return new EncodedFileOutput({
    fileType: EncodedFileType.MP4,
    filepath,
    output: {
      case: "s3",
      value: new S3Upload({
        endpoint: REPLAYS_S3_ENDPOINT,
        region: REPLAYS_S3_REGION,
        bucket: REPLAYS_BUCKET,
        accessKey: REPLAYS_S3_ACCESS_KEY,
        secret: REPLAYS_S3_SECRET_KEY,
        forcePathStyle: true, // Supabase S3 endpoint requires path-style
      }),
    },
  });
}

/**
 * Grid replay (studio live elements, phase 6): LiveKit records Nile's own
 * recorder page — on-air cameras and element angles in the host's order —
 * and the page reports its tiles and every overlay change to replay-recorder,
 * proving itself with the row's recorder_key. The row exists before the
 * egress does, so the page's first report always has somewhere to land.
 */
async function startGridEgress(eventPk: string, replayId: string, roomName: string, startedAt: number, admin: any) {
  const filepath = `${eventPk}/${startedAt}-grid.mp4`;
  const { data: grid, error } = await admin.from("replay_grids").insert({
    replay_id: replayId,
    event_id: eventPk,
    playback_path: filepath,
  }).select("id, recorder_key").single();
  if (error || !grid) throw error ?? new Error("grid row not created");

  const page = new URL(REPLAY_RECORDER_URL);
  page.searchParams.set("k", grid.recorder_key);
  page.searchParams.set("fn", `${Deno.env.get("SUPABASE_URL")}/functions/v1/replay-recorder`);
  try {
    const info = await egressClient.startRoomCompositeEgress(roomName, { file: replayFile(filepath) }, {
      layout: "nile-grid",
      customBaseUrl: page.toString(),
      encodingOptions: EncodingOptionsPreset.H264_1080P_30,
    });
    await admin.from("replay_grids").update({ egress_id: info.egressId }).eq("id", grid.id);
  } catch (err) {
    await admin.from("replay_grids").update({ status: "failed" }).eq("id", grid.id);
    throw err;
  }
}

/** Stop every grid recording still running for an event. Idempotent. */
async function stopGridEgress(eventPk: string, admin: any) {
  const { data: grids } = await admin
    .from("replay_grids")
    .select("egress_id")
    .eq("event_id", eventPk)
    .eq("status", "recording");
  for (const g of grids ?? []) {
    if (!g.egress_id) continue;
    await egressClient.stopEgress(g.egress_id).catch((err) =>
      log("warn", { action: "stop-grid-egress", error: String(err) })
    );
  }
}

// stop-egress — host ends the show; stop the active egress so the file
// finalizes. The egress_ended webhook flips the replay row to ready/failed.
// Called by the host client on End Show; the server-side auto-end cron + the
// hourly fail_stuck_replays sweep cover the cases where the client never fires.
async function stopEgress(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  // Host-only (review C11): an operator finalizing the recording mid-show
  // truncates the replay the host later sells.
  const gate = await requireHost(eventId, userId, admin, json);
  if (gate instanceof Response) return gate;
  // While the Studio is in the room it runs the show: a host phone (or an
  // older build that knows nothing about the Studio) can't start or finalize
  // it from the side. The Studio identifies itself with `studio: true`.
  if (body.studio !== true && studioConnected(await peersOf(roomNameFor(eventId)))) {
    return json({ error: "Your Studio is running this show — use the Studio's controls." }, 409);
  }

  const { data: replay } = await admin
    .from("replays")
    .select("egress_id")
    .eq("event_id", gate.event.id)
    .eq("status", "recording")
    .order("created_at", { ascending: false })
    .maybeSingle();

  if (replay?.egress_id) {
    await egressClient.stopEgress(replay.egress_id).catch((err) =>
      log("warn", { action: "stop-egress", error: String(err) }),
    );
  }
  await stopGridEgress(gate.event.id, admin);

  // C12: nothing used to close the LiveKit room when a show ended — the cron is
  // DB-only, and publishers relied entirely on receiving the realtime 'ended'
  // record. A wedged socket kept a camera publishing into a finished show.
  // deleteRoom disconnects every participant; it also fires room_finished, which
  // the webhook treats as idempotent.
  await roomService.deleteRoom(roomNameFor(eventId)).catch((err) =>
    log("warn", { action: "stop-egress", note: "room delete failed", error: String(err) }),
  );

  return json({ success: true });
}

// reconcile-viewers — write the TRUE live viewer count from LiveKit into
// events.viewer_count, replacing the increment/decrement pair that drifted
// whenever a viewer's app was killed before its decrement fired. Any viewer
// calls this (on join + on a light interval); the value is derived solely from
// the room's actual participants, so it can't be gamed and self-heals. Cameras/
// audio operators (role != 'viewer') are excluded; identity is unique per user
// (`viewer-<userId>`) so multiple tabs count once.
async function reconcileViewers(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId, excludeSelf } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  const { data: event } = await admin
    .from("events")
    .select("id, status")
    .eq("livekit_room", eventId)
    .maybeSingle();
  if (!event) return json({ error: "Event not found" }, 404);

  // E9: this accepted ANY authenticated caller for ANY event — a cheap way to
  // generate service-role writes and realtime churn on someone else's show.
  // Only someone actually in the room has a count to reconcile.
  try {
    const inRoom = await roomService.listParticipants(roomNameFor(eventId));
    const isPresent = inRoom.some(
      (p) => parseMeta(p.metadata).userId === userId,
    );
    // excludeSelf is the leaving case: the caller is on their way out, so they
    // may legitimately no longer be in the participant list.
    if (!isPresent && excludeSelf !== true) {
      return json({ error: "Forbidden — not in this room" }, 403);
    }
  } catch {
    // Room gone: fall through so the count still settles to 0 below.
  }

  // E7: a show that has ended has no viewers, whatever the room says. Nothing
  // used to zero this on end, so the last number just stuck forever.
  // set_viewer_count also keeps events.peak_viewer_count as a running max.
  // viewer_count decays to zero the moment a show ends, so it carries no
  // attendance history — and attendance history is exactly what sponsorship
  // price suggestions are built from. greatest() means writing 0 here clears
  // the live number without touching the peak.
  if (event.status === "ended") {
    await admin.rpc("set_viewer_count", { p_event_id: event.id, p_count: 0 });
    return json({ success: true, viewer_count: 0 });
  }

  // A leaving viewer passes excludeSelf so they aren't counted even if LiveKit
  // hasn't yet processed their disconnect — makes the last-viewer-leaves case
  // settle to the right number instead of sticking at 1.
  //
  // Counting is by the userId in each participant's metadata, NOT by identity:
  // identities carry a per-connection suffix now (E8), so one person on a phone
  // and a laptop is still one viewer.
  let count = 0;
  try {
    const participants = await roomService.listParticipants(roomNameFor(eventId));
    const viewers = new Set<string>();
    for (const p of participants) {
      const meta = parseMeta(p.metadata);
      if (meta.role !== "viewer") continue;
      const who = (meta.userId as string | undefined) ?? p.identity;
      if (excludeSelf === true && who === userId) continue;
      viewers.add(who);
    }
    count = viewers.size;
  } catch (err) {
    // E7: this used to fall through to count = 0 and WRITE it — one transient
    // LiveKit API error zeroed the viewer count mid-show, for everyone. If we
    // can't read the room we don't know the count, so we leave it alone.
    log("warn", { action: "reconcile-viewers", error: String(err) });
    const { data: current } = await admin
      .from("events")
      .select("viewer_count")
      .eq("id", event.id)
      .maybeSingle();
    return json({ success: false, viewer_count: current?.viewer_count ?? 0 });
  }

  await admin.rpc("set_viewer_count", { p_event_id: event.id, p_count: count });
  return json({ success: true, viewer_count: count });
}

// Resolve the event by LiveKit slug and apply the replay access gate (Phase 2
// VOD pricing). Crew (host/operator) always pass — they can preview before
// publish. Everyone else needs the replay PUBLISHED (replay_published_at set),
// and then: free replay (replay_price 0) → open; priced replay → any paid
// ticket row (kind 'live' or 'replay' — live holders always rewatch free).
// Shared by replay-exists and replay-url so both gate identically.
async function gateReplayAccess(
  eventId: string,
  userId: string,
  admin: any,
  json: Json,
): Promise<{ id: string } | Response> {
  if (!eventId) return json({ error: "eventId is required" }, 400);

  const { data: event, error } = await admin
    .from("events")
    .select("id, host_id, replay_price, replay_published_at")
    .eq("livekit_room", eventId)
    .maybeSingle();
  if (error || !event) return json({ error: "Event not found" }, 404);

  const isCrew = await isAuthorizedOperator(
    { id: event.id, host_id: event.host_id },
    userId,
    admin,
  );
  if (isCrew) return { id: event.id };

  if (!event.replay_published_at) {
    return json({ error: "Replay not published yet" }, 403);
  }

  if (event.replay_price && event.replay_price > 0) {
    const { data: ticket } = await admin
      .from("tickets")
      .select("status")
      .eq("event_id", event.id)
      .eq("buyer_id", userId)
      .maybeSingle();
    if (!ticket || ticket.status !== "paid") {
      return json({ error: "Purchase the replay to watch it" }, 403);
    }
  }

  return { id: event.id };
}

// replay-exists — does a ready replay exist that THIS user may watch? Drives the
// event-detail CTA (fix 1): we must NOT key the CTA off replay-url succeeding,
// because that returns null both when no replay exists AND when the user lacks a
// ticket. This returns { available: false } (never an error) for the no-ticket
// case so the client can still surface a "buy a ticket to watch the replay" CTA.
async function replayExists(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  // Does any ready replay exist at all (independent of this user's access)?
  const { data: event } = await admin
    .from("events")
    .select("id, replay_published_at, replay_price")
    .eq("livekit_room", eventId)
    .maybeSingle();
  if (!event) return json({ available: false, authorized: false });

  const { data: replay } = await admin
    .from("replays")
    .select("id")
    .eq("event_id", event.id)
    .eq("status", "ready")
    .limit(1)
    .maybeSingle();
  const hasReplay = !!replay;
  const published = !!event.replay_published_at;

  // Is the caller authorized (crew, or published + free/ticketed)?
  const gate = await gateReplayAccess(eventId, userId, admin, json);
  const authorized = !(gate instanceof Response);

  // available = there's a ready replay AND the caller may watch it now.
  // published + replayPrice drive the client CTA: unpublished → host sees
  // "Set replay price"; published+unauthorized → "Get Replay — $X".
  return json({
    available: hasReplay && authorized,
    authorized,
    hasReplay,
    published,
    replayPrice: event.replay_price ?? null,
  });
}

// replay-url — mint a short-lived signed playback URL for a ready replay, after
// the SAME paid-ticket gate as viewer-token. `eventId` is the LiveKit slug.
async function replayUrl(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId } = body;
  const gate = await gateReplayAccess(eventId, userId, admin, json);
  if (gate instanceof Response) return gate; // 403 (no ticket) or 404 (no event)

  const { data: replay } = await admin
    .from("replays")
    .select("playback_path, duration_ms")
    .eq("event_id", gate.id)
    .eq("status", "ready")
    .order("created_at", { ascending: false })
    .maybeSingle();
  if (!replay?.playback_path) return json({ error: "No replay available" }, 404);

  // A Storage signed URL carries no identity: whoever holds the string can
  // fetch the file. A flat four hours meant every replay — a ten-minute clip
  // included — was a shareable download link for the rest of the afternoon.
  //
  // Size the window to the recording instead. The player streams the file in
  // range requests for as long as someone is watching, so the URL has to
  // outlive the content or playback dies partway through; duration + 10 minutes
  // does that with room for pausing, while a typical 20-minute service now gets
  // a 30-minute window instead of a 4-hour one.
  //
  // ⚠️ This shortens the exposure, it does not remove it. The URL is still a
  // bearer token, so anyone it is forwarded to inside the window can fetch the
  // whole file. Binding playback to a user means proxying it through an
  // authenticated endpoint — a real piece of work, tracked separately.
  const durationMs = (replay.duration_ms as number | null) ?? null;
  const ttl = Math.min(
    REPLAY_URL_MAX_TTL_SECONDS,
    Math.max(
      REPLAY_URL_MIN_TTL_SECONDS,
      Math.ceil((durationMs ?? 0) / 1000) + REPLAY_URL_SLACK_SECONDS,
    ),
  );
  const { data: signed, error: signErr } = await admin.storage
    .from(REPLAYS_BUCKET)
    .createSignedUrl(replay.playback_path, ttl);
  if (signErr || !signed) return json({ error: "Could not sign replay URL" }, 500);

  return json({ url: signed.signedUrl, durationMs, expiresInSeconds: ttl });
}

// replay-grid — the grid replay (phase 6) and its overlay timeline, behind the
// same gate as replay-url. { available: false } when this show has none (older
// shows, or the grid recording failed): the app then plays replay-url.
async function replayGrid(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const gate = await gateReplayAccess(body.eventId, userId, admin, json);
  if (gate instanceof Response) return gate;

  const { data: replay } = await admin
    .from("replays")
    .select("id")
    .eq("event_id", gate.id)
    .eq("status", "ready")
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  const { data: grid } = replay
    ? await admin
      .from("replay_grids")
      .select("id, playback_path, duration_ms, recorder_started_at")
      .eq("replay_id", replay.id)
      .eq("status", "ready")
      .limit(1)
      .maybeSingle()
    : { data: null };
  if (!grid?.playback_path) return json({ available: false });

  const rows: any[] = [];
  for (let from = 0; from < 20000; from += 1000) {
    const { data, error } = await admin
      .from("replay_marks")
      .select("offset_ms, at, kind, data")
      .eq("grid_id", grid.id)
      .order("id")
      .range(from, from + 999);
    if (error) return json({ error: "Could not load the replay" }, 500);
    rows.push(...data);
    if (data.length < 1000) break;
  }

  const durationMs = (grid.duration_ms as number | null) ?? null;
  const ttl = Math.min(
    REPLAY_URL_MAX_TTL_SECONDS,
    Math.max(REPLAY_URL_MIN_TTL_SECONDS, Math.ceil((durationMs ?? 0) / 1000) + REPLAY_URL_SLACK_SECONDS),
  );
  const { data: signed, error: signErr } = await admin.storage
    .from(REPLAYS_BUCKET)
    .createSignedUrl(grid.playback_path, ttl);
  if (signErr || !signed) return json({ error: "Could not sign replay URL" }, 500);

  return json({
    available: true,
    url: signed.signedUrl,
    durationMs,
    expiresInSeconds: ttl,
    marks: timelineOf(rows, grid.recorder_started_at),
  });
}

// viewer-token (was POST /api/viewer-token) — JWT-derived identity + mode seam
async function viewerToken(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const { eventId, lobbySafe } = body;
  if (!eventId) return json({ error: "eventId is required" }, 400);

  // userId comes from the verified JWT, NOT the body — closes the old spoofing
  // hole (3.3). `eventId` is the LiveKit slug (events.livekit_room), not the PK.
  const { data: event, error } = await admin
    .from("events")
    .select("id, host_id, status, livekit_room, price, ticket_limit")
    .eq("livekit_room", eventId)
    .maybeSingle();

  if (error || !event) return json({ error: "Event not found" }, 404);
  // Viewers may connect once the show is live OR while the host is in Sound Check
  // (they wait in the Lobby until status flips to 'live'). 'scheduled'/'ended'
  // still reject. The same paid-ticket gate below applies in both phases.
  if (event.status !== "live" && event.status !== "soundcheck") {
    return json({ error: "Event is not currently live" }, 403);
  }

  // Resolved once and used by all three gates below (ticket check, free-event
  // seat count, and the Sound Check subscribe grant). Crew are the host and any
  // assigned camera operator.
  const isCrew = await isAuthorizedOperator(
    { id: event.id, host_id: event.host_id },
    userId,
    admin,
  );

  // Chat ban (#16 phase 1, migration 0107). remove-participant kicks someone
  // out of the room; on a FREE event nothing then stopped them minting a new
  // token and walking straight back in, because no other gate below applies.
  // This is the piece #11 left open. Crew are exempt — a host cannot ban
  // themselves, and an operator assignment is the stronger signal anyway.
  //
  // Deliberately worded as removal rather than "you are banned": the viewer is
  // out either way, and the host does not need a rejoining argument.
  if (!isCrew) {
    const { data: chatBan } = await admin
      .from("live_chat_bans")
      .select("user_id")
      .eq("event_id", event.id)
      .eq("user_id", userId)
      .maybeSingle();
    if (chatBan) {
      return json({ error: "You've been removed from this event" }, 403);
    }
  }

  // Paid events require a paid ticket — unless the viewer is the host or an
  // assigned camera operator, who both get free access. Look the ticket up
  // separately so a missing ticket never nulls out the event row (an embedded
  // left-join filter on tickets.user_id did exactly that for free events).
  if (event.price && event.price > 0) {
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
  } else if (event.ticket_limit != null) {
    // B9: on a free event, ticket_limit did nothing at all — free events create
    // no ticket rows, so nothing ever read it. A host who set "limit 30" on a
    // free workshop got 400 viewers and no warning. Enforce it here, where the
    // seat is actually taken: count live viewers and turn away the overflow.
    // Crew are never counted or blocked.
    if (!isCrew) {
      try {
        const participants = await roomService.listParticipants(roomNameFor(eventId));
        const viewers = new Set(
          participants
            .filter((p) => parseMeta(p.metadata).role === "viewer")
            .map((p) => (parseMeta(p.metadata).userId as string) ?? p.identity),
        );
        viewers.delete(userId); // rejoining doesn't take a new seat
        if (viewers.size >= event.ticket_limit) {
          return json({ error: "This event is full" }, 409);
        }
      } catch {
        // Room not up yet — nobody is in it, so nothing to be full of.
      }
    }
  }

  // Must match how cameras/audio join: roomNameFor(slug) = `nile-event-<slug>`.
  // events.livekit_room stores the bare slug, so using it here put viewers in a
  // DIFFERENT room than the publishers (viewer saw 0 participants).
  const roomName = roomNameFor(eventId);

  // Sound Check is a private rehearsal, but the cameras and the host's mic are
  // already publishing into the room — and a viewer token that could subscribe
  // meant ticket holders heard the whole thing. The Pre-Show Lobby that is
  // supposed to be covering it is only an overlay in our app; a stock LiveKit
  // client ignores overlays and just pulls the tracks. So withhold the grant
  // until the show is actually live. Crew keep it: the host previewing their
  // own show as a viewer is the point of Sound Check.
  //
  // ⚠️ Gated on `lobbySafe` for the same reason camera-token gates `monitor`:
  // a client that predates this has no re-mint step, so withholding the grant
  // from it would leave it silently unable to watch when the show DID go live —
  // a worse failure than the leak. Builds that re-mint on the status flip send
  // the flag; older ones keep the behaviour they shipped with. Drop the flag
  // and make this unconditional once the force-update floor reaches the build
  // that introduced it.
  const canSubscribe = event.status === "live" || isCrew || lobbySafe !== true;

  // E8: this was a bare `viewer-<userId>`. LiveKit treats an identity as unique
  // per room, so the same person on a phone and a laptop evicted each other
  // forever — both devices reconnecting, neither able to watch. A per-connection
  // suffix makes every session distinct; the count still dedupes on the userId
  // in the metadata (see reconcile-viewers), so one person is still one viewer.
  const token = await buildToken({
    identity: `viewer-${userId}-${crypto.randomUUID().slice(0, 8)}`,
    name: `Viewer ${userId}`,
    roomName,
    canPublish: false,
    canSubscribe,
    metadata: JSON.stringify({ role: "viewer", userId }),
  });

  // Typed connection descriptor (3.2). Always "webrtc" today; the same shape
  // can return { mode: "hls", manifestUrl } at much higher scale with no app
  // re-architecture.
  return json({ mode: "webrtc", token, wsUrl: LIVEKIT_URL });
}

