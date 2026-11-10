// Supabase Edge Function: premiere (docs/plans/studio-modes.md, phase 6)
//
// The film side of Premiere mode. Films and trailers are uploaded straight
// from the filmmaker's device to Cloudflare Stream over tus (resumable): this
// function provisions the one-time upload URL, so the Stream API token never
// leaves the server. Every video requires signed URLs; playback-token and
// trailer-token sign short-lived tokens with the account's Stream signing key.
//
// Actions (POST { action, eventId, ... }; eventId = events.id):
//   create-upload   host: { kind: film|trailer, size, durationS?, name? } → { uploadUrl, uid }
//   refresh         host: re-reads processing videos from Stream (webhook fallback)
//   set-details     host: rating, contentWarning, replayPolicy, chatPolicy, posterUrl, rightsConfirmed
//   add-captions    host: { lang, label?, vtt }   remove-captions host: { lang }
//   delete-media    host: { kind }
//   playback-token  ticket holders / host / crew → { url, expiresAt, rating, contentWarning, captions, askRating }
//                   (18+ films need an account shown to be 18 or older)
//   trailer-token   anyone signed in → { url, expiresAt }
//   rate-film       viewer: { stars 1-5 } once the film has started, when the filmmaker asks
//   ratings         host → { count, average }
//   replay-chapters anyone signed in → { span: { start, end } | null, filmReady } (server ms of the film segment)
//
// Secrets: CF_ACCOUNT_ID, CF_STREAM_API_TOKEN, CF_STREAM_SIGNING_KEY_ID,
// CF_STREAM_SIGNING_JWK (set 2026-11-02). Deploy with the default JWT check.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders as corsHeadersFor } from "../_shared/cors.ts";
import { failure } from "../_shared/errors.ts";
import { deleteVideo, drainDeletions, ensureSigned, getVideo, streamFetch, STREAM_API } from "../_shared/cloudflare_stream.ts";
import { filmOf, filmSpan, isAdult } from "../_shared/film.ts";
import {
  canWatchFilm,
  checkQuota,
  checkVtt,
  cleanDetails,
  isCaptionLang,
  isKind,
  manifestUrl,
  type MediaKind,
  type ReplayPolicy,
  replayWindowMs,
  reserveSeconds,
  signPlaybackToken,
  streamStateOf,
  tokenExpiry,
  tusMetadata,
} from "../_shared/premiere.ts";

type Json = (body: unknown, status?: number) => Response;
const makeJson = (cors: Record<string, string>): Json => (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const KEY_ID = Deno.env.get("CF_STREAM_SIGNING_KEY_ID") ?? "";
const JWK = Deno.env.get("CF_STREAM_SIGNING_JWK") ?? "";
const MAX_UPLOAD_BYTES = 30 * 1024 ** 3; // Stream's tus limit
const MAX_TRAILER_BYTES = 4 * 1024 ** 3;
const UPLOAD_WINDOW_MS = 6 * 3600_000; // how long a provisioned upload URL accepts bytes
const POSTER_PREFIX = `${Deno.env.get("SUPABASE_URL")}/storage/v1/object/public/events/`;
const ON_AIR = ["live", "soundcheck"];
const CAPTIONS_BUCKET = "film-captions";
const captionPath = (eventId: string, lang: string) => `${eventId}/${lang}.vtt`;

function log(level: "info" | "warn" | "error", fields: Record<string, unknown>) {
  console.log(JSON.stringify({ level, fn: "premiere", ...fields }));
}

type EventRow = {
  id: string;
  host_id: string;
  status: string;
  price: number;
  replay_price: number | null;
  ended_at: string | null;
  studio_mode: string;
  removed_at: string | null;
};
type FilmRow = Record<string, any> & { event_id: string };

async function eventOf(eventId: unknown, admin: any): Promise<EventRow | null> {
  if (typeof eventId !== "string" || !/^[0-9a-f-]{36}$/i.test(eventId)) return null;
  const { data } = await admin
    .from("events")
    .select("id, host_id, status, price, replay_price, ended_at, studio_mode, removed_at")
    .eq("id", eventId)
    .maybeSingle();
  return data as EventRow | null;
}

async function filmOf_(eventId: string, admin: any): Promise<FilmRow | null> {
  const { data } = await admin.from("event_films").select("*").eq("event_id", eventId).maybeSingle();
  return data as FilmRow | null;
}

async function saveFilm(ev: EventRow, patch: Record<string, unknown>, admin: any): Promise<FilmRow> {
  const { data, error } = await admin
    .from("event_films")
    .upsert({ event_id: ev.id, host_id: ev.host_id, ...patch }, { onConflict: "event_id" })
    .select("*")
    .single();
  if (error) throw error;
  return data as FilmRow;
}

const hostGate = (ev: EventRow | null, userId: string, json: Json): Response | null => {
  if (!ev || ev.removed_at) return json({ error: "Event not found" }, 404);
  if (ev.host_id !== userId) return json({ error: "Only the host can do this" }, 403);
  return null;
};

// create-upload — a one-time tus URL the device uploads to directly.
async function createUpload(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const ev = await eventOf(body.eventId, admin);
  const refused = hostGate(ev, userId, json);
  if (refused) return refused;
  if (ev!.studio_mode !== "premiere") return json({ error: "Switch this event to Premiere mode first" }, 409);
  if (ev!.status === "ended" || ev!.status === "cancelled") return json({ error: "This show is over" }, 409);
  const kind = body.kind;
  if (!isKind(kind)) return json({ error: "kind must be film or trailer" }, 400);
  if (kind === "film" && ON_AIR.includes(ev!.status)) {
    return json({ error: "You can't change the film once the show has started" }, 409);
  }
  const size = body.size;
  const cap = kind === "film" ? MAX_UPLOAD_BYTES : MAX_TRAILER_BYTES;
  if (typeof size !== "number" || !Number.isInteger(size) || size <= 0) return json({ error: "size is required" }, 400);
  if (size > cap) return json({ error: kind === "film" ? "Films can be up to 30 GB" : "Trailers can be up to 4 GB" }, 413);

  const { data: mine, error: mineErr } = await admin
    .from("event_films")
    .select("event_id, film_uid, film_status, film_duration_s, trailer_uid, trailer_status, trailer_duration_s")
    .eq("host_id", userId);
  if (mineErr) throw mineErr;
  const existing = (mine ?? []).find((r: any) => r.event_id === ev!.id) ?? null;
  if (kind === "film" && existing && ["uploading", "processing"].includes(existing.film_status) && body.replace !== true) {
    return json({ error: "A film is already uploading for this show", uploading: true }, 409);
  }
  const reserve = reserveSeconds(kind, body.durationS);
  const over = checkQuota(mine ?? [], ev!.id, kind, reserve);
  if (over) return json({ error: over.error }, over.status);

  const name = typeof body.name === "string" && body.name.trim() ? body.name.trim().slice(0, 200) : `${kind}.mp4`;
  const res = await streamFetch("?direct_user=true", {
    method: "POST",
    headers: {
      "Tus-Resumable": "1.0.0",
      "Upload-Length": String(size),
      "Upload-Creator": userId,
      "Upload-Metadata": tusMetadata({
        name: `${kind} ${ev!.id} ${name}`.slice(0, 250),
        requiresignedurls: true,
        maxdurationseconds: String(reserve),
        expiry: new Date(Date.now() + UPLOAD_WINDOW_MS).toISOString(),
      }),
    },
  });
  const uploadUrl = res.headers.get("Location");
  const uid = res.headers.get("stream-media-id");
  if (res.status !== 201 || !uploadUrl || !uid) {
    log("warn", { action: "create-upload", status: res.status, body: (await res.text()).slice(0, 500) });
    return json({ error: "Couldn't start the upload. Try again." }, 502);
  }

  // Save only over the uid we read, so two uploads started at once can't
  // both win. The loser's video is deleted. A replaced uid is queued for
  // deletion by trigger (0152).
  const patch = kind === "film"
    ? { film_uid: uid, film_status: "uploading", film_error: null, film_name: name, film_bytes: size, film_duration_s: null, captions: [] }
    : { trailer_uid: uid, trailer_status: "uploading", trailer_error: null, trailer_duration_s: null };
  const prev = existing?.[`${kind}_uid`] ?? null;
  let saved: FilmRow | null = null;
  if (existing) {
    let q = admin.from("event_films").update(patch).eq("event_id", ev!.id);
    q = prev === null ? q.is(`${kind}_uid`, null) : q.eq(`${kind}_uid`, prev);
    const { data, error } = await q.select("*");
    if (error) throw error;
    saved = (data as FilmRow[])?.[0] ?? null;
  } else {
    const { data, error } = await admin.from("event_films")
      .insert({ event_id: ev!.id, host_id: ev!.host_id, ...patch }).select("*").maybeSingle();
    if (error && error.code !== "23505") throw error;
    saved = data as FilmRow | null;
  }
  if (!saved) {
    await deleteVideo(uid).catch(() => {});
    return json({ error: "Another upload started at the same time. Try again." }, 409);
  }
  await drainDeletions(admin, 5).catch(() => 0);
  return json({ uploadUrl, uid, film: saved });
}

// refresh — webhook fallback: re-read anything not settled.
async function refresh(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const ev = await eventOf(body.eventId, admin);
  const refused = hostGate(ev, userId, json);
  if (refused) return refused;
  const film = await filmOf_(ev!.id, admin);
  if (!film) return json({ film: null });
  const patch: Record<string, unknown> = {};
  for (const kind of ["film", "trailer"] as MediaKind[]) {
    const uid = film[`${kind}_uid`];
    if (!uid || !["uploading", "processing"].includes(film[`${kind}_status`])) continue;
    const v = await getVideo(uid);
    if (!v) {
      patch[`${kind}_status`] = "error";
      patch[`${kind}_error`] = "The upload didn't finish. Start it again.";
      continue;
    }
    const s = streamStateOf(v);
    if (!s) continue;
    if (s.status === "ready") await ensureSigned(v);
    // Stream reports pendingupload until bytes arrive; keep "uploading" then.
    patch[`${kind}_status`] = s.status;
    patch[`${kind}_error`] = s.error;
    patch[`${kind}_duration_s`] = s.durationS;
    if (s.host) patch.playback_host = s.host;
  }
  if (Object.keys(patch).length === 0) return json({ film });
  return json({ film: await saveFilm(ev!, patch, admin) });
}

async function setDetails(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const ev = await eventOf(body.eventId, admin);
  const refused = hostGate(ev, userId, json);
  if (refused) return refused;
  const r = cleanDetails(body, Date.now(), POSTER_PREFIX);
  if ("error" in r) return json({ error: r.error }, 400);
  return json({ film: await saveFilm(ev!, r.patch, admin) });
}

async function addCaptions(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const ev = await eventOf(body.eventId, admin);
  const refused = hostGate(ev, userId, json);
  if (refused) return refused;
  if (!isCaptionLang(body.lang)) return json({ error: "Pick a caption language" }, 400);
  const bad = checkVtt(body.vtt);
  if (bad) return json({ error: bad }, 400);
  const film = await filmOf_(ev!.id, admin);
  if (!film?.film_uid || film.film_status !== "ready") return json({ error: "Add captions once the film has finished processing" }, 409);
  const form = new FormData();
  form.append("file", new Blob([body.vtt], { type: "text/vtt" }), `${body.lang}.vtt`);
  const res = await streamFetch(`/${film.film_uid}/captions/${body.lang}`, { method: "PUT", body: form });
  if (!res.ok) {
    log("warn", { action: "add-captions", status: res.status, body: (await res.text()).slice(0, 500) });
    return json({ error: "Stream didn't accept that caption file" }, 502);
  }
  // Our own copy too: the app's player shows WebVTT it fetched itself.
  const { error: upErr } = await admin.storage.from(CAPTIONS_BUCKET)
    .upload(captionPath(ev!.id, body.lang), new Blob([body.vtt], { type: "text/vtt" }), { upsert: true, contentType: "text/vtt" });
  if (upErr) throw upErr;
  const label = typeof body.label === "string" && body.label.trim() ? body.label.trim().slice(0, 40) : body.lang;
  const captions = [...(film.captions ?? []).filter((c: any) => c.lang !== body.lang), { lang: body.lang, label }];
  return json({ film: await saveFilm(ev!, { captions }, admin) });
}

async function removeCaptions(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const ev = await eventOf(body.eventId, admin);
  const refused = hostGate(ev, userId, json);
  if (refused) return refused;
  if (!isCaptionLang(body.lang)) return json({ error: "Pick a caption language" }, 400);
  const film = await filmOf_(ev!.id, admin);
  if (!film?.film_uid) return json({ error: "There's no film" }, 404);
  const res = await streamFetch(`/${film.film_uid}/captions/${body.lang}`, { method: "DELETE" });
  if (!res.ok && res.status !== 404) return json({ error: "Couldn't remove those captions" }, 502);
  await admin.storage.from(CAPTIONS_BUCKET).remove([captionPath(ev!.id, body.lang)]).catch(() => {});
  const captions = (film.captions ?? []).filter((c: any) => c.lang !== body.lang);
  return json({ film: await saveFilm(ev!, { captions }, admin) });
}

async function deleteMedia(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const ev = await eventOf(body.eventId, admin);
  const refused = hostGate(ev, userId, json);
  if (refused) return refused;
  if (!isKind(body.kind)) return json({ error: "kind must be film or trailer" }, 400);
  if (body.kind === "film" && ON_AIR.includes(ev!.status)) {
    return json({ error: "You can't delete the film once the show has started" }, 409);
  }
  const patch = body.kind === "film"
    ? { film_uid: null, film_status: "none", film_error: null, film_name: null, film_bytes: null, film_duration_s: null, captions: [] }
    : { trailer_uid: null, trailer_status: "none", trailer_error: null, trailer_duration_s: null };
  if (body.kind === "film") {
    const old = await filmOf_(ev!.id, admin);
    const paths = (old?.captions ?? []).map((c: any) => captionPath(ev!.id, c.lang));
    if (paths.length) await admin.storage.from(CAPTIONS_BUCKET).remove(paths).catch(() => {});
  }
  const film = await saveFilm(ev!, patch, admin); // the trigger queues the old video
  await drainDeletions(admin, 5).catch(() => 0);
  return json({ film });
}

async function playbackToken(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const ev = await eventOf(body.eventId, admin);
  if (!ev || ev.removed_at) return json({ error: "Event not found" }, 404);
  const film = await filmOf_(ev.id, admin);
  if (!film?.film_uid || film.film_status !== "ready") return json({ error: "The film isn't ready" }, 409);
  const isHost = ev.host_id === userId;
  const [{ data: op }, { data: ticket }, { data: ban }] = await Promise.all([
    admin.from("event_operators").select("id").eq("event_id", ev.id).eq("operator_id", userId).maybeSingle(),
    admin.from("tickets").select("id").eq("event_id", ev.id).eq("buyer_id", userId).eq("status", "paid").limit(1).maybeSingle(),
    admin.from("live_chat_bans").select("user_id").eq("event_id", ev.id).eq("user_id", userId).maybeSingle(),
  ]);
  if (ban && !isHost && !op) return json({ error: "You've been removed from this event" }, 403);
  const now = Date.now();
  const policy = (film.replay_policy ?? "none") as ReplayPolicy;
  // The sweep's over_at anchor once it exists; ended_at is host-editable.
  const endedAt = film.over_at ? Date.parse(film.over_at) : ev.ended_at ? Date.parse(ev.ended_at) : null;
  const ok = canWatchFilm({
    isHost,
    isCrew: !!op,
    status: ev.status,
    price: ev.price ?? 0,
    replayPrice: ev.replay_price ?? 0,
    hasTicket: !!ticket,
    endedAt: endedAt,
    policy,
    now,
  });
  if ("error" in ok) return json({ error: ok.error }, ok.status);
  const info = {
    rating: film.rating ?? null,
    contentWarning: film.content_warning ?? null,
    askRating: film.ask_rating === true,
    chatPolicy: film.chat_policy ?? "open",
  };
  // 18+: the account has to show the viewer is an adult (a store-held age
  // band or the birthday they gave). The host previews their own film.
  if (film.rating === "18+" && !isHost) {
    const { data: age } = await admin.from("user_age_verification")
      .select("birthdate, age_lower_bound").eq("user_id", userId).maybeSingle();
    if (!isAdult(age, now)) {
      return json({ error: "This film is for adults. Your account doesn't show you're 18 or older.", code: "age", ...info }, 403);
    }
  }
  const w = replayWindowMs(policy);
  const exp = tokenExpiry({
    isHost,
    durationS: Number(film.film_duration_s) || null,
    now,
    replayEndsAt: ev.status === "ended" && endedAt !== null && w !== null ? endedAt + w : null,
  });
  const token = await signPlaybackToken(film.film_uid, KEY_ID, JWK, exp);
  const captions = [];
  for (const c of film.captions ?? []) {
    const { data } = await admin.storage.from(CAPTIONS_BUCKET).createSignedUrl(captionPath(ev.id, c.lang), 3600);
    if (data?.signedUrl) captions.push({ lang: c.lang, label: c.label ?? c.lang, url: data.signedUrl });
  }
  return json({
    url: manifestUrl(film.playback_host, token),
    expiresAt: exp * 1000,
    durationS: film.film_duration_s,
    captions,
    ...info,
  });
}

// rate-film — { eventId, stars }. Someone who could watch, once the film has
// started, when the filmmaker asked for ratings. One rating each; a second
// replaces the first.
async function rateFilm(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const ev = await eventOf(body.eventId, admin);
  if (!ev || ev.removed_at) return json({ error: "Event not found" }, 404);
  const stars = body.stars;
  if (typeof stars !== "number" || !Number.isInteger(stars) || stars < 1 || stars > 5) {
    return json({ error: "Pick 1 to 5 stars" }, 400);
  }
  const film = await filmOf_(ev.id, admin);
  if (!film?.ask_rating) return json({ error: "This film isn't taking ratings" }, 409);
  if (filmOf(film.film_state)?.startedAt === undefined) return json({ error: "The film hasn't started" }, 409);
  if (ev.host_id === userId) return json({ error: "You can't rate your own film" }, 403);
  const { data: ban } = await admin.from("live_chat_bans").select("user_id")
    .eq("event_id", ev.id).eq("user_id", userId).maybeSingle();
  if (ban) return json({ error: "You've been removed from this event" }, 403);
  if ((ev.price ?? 0) > 0) {
    const { data: ticket } = await admin.from("tickets").select("id")
      .eq("event_id", ev.id).eq("buyer_id", userId).eq("status", "paid").limit(1).maybeSingle();
    if (!ticket) return json({ error: "You need a ticket to rate this film" }, 403);
  }
  const { error } = await admin.from("film_ratings")
    .upsert({ event_id: ev.id, user_id: userId, stars }, { onConflict: "event_id,user_id" });
  if (error) throw error;
  return json({ success: true });
}

// replay-chapters — where the film sat in the show, so the replay can offer
// Intro (recording) · Film (Stream) · Q&A (recording). Times aren't secret;
// whether the film itself may play is still playback-token's call.
async function replayChapters(body: any, _userId: string, admin: any, json: Json): Promise<Response> {
  const ev = await eventOf(body.eventId, admin);
  if (!ev || ev.removed_at || ev.studio_mode !== "premiere") return json({ span: null, filmReady: false });
  const film = await filmOf_(ev.id, admin);
  return json({ span: filmSpan(filmOf(film?.film_state)), filmReady: film?.film_status === "ready" });
}

async function ratings(body: any, userId: string, admin: any, json: Json): Promise<Response> {
  const ev = await eventOf(body.eventId, admin);
  const refused = hostGate(ev, userId, json);
  if (refused) return refused;
  const { data, error } = await admin.from("film_ratings").select("stars").eq("event_id", ev!.id);
  if (error) throw error;
  const n = (data ?? []).length;
  const avg = n ? (data as { stars: number }[]).reduce((a, r) => a + r.stars, 0) / n : null;
  return json({ count: n, average: avg });
}

async function trailerToken(body: any, _userId: string, admin: any, json: Json): Promise<Response> {
  const ev = await eventOf(body.eventId, admin);
  if (!ev || ev.removed_at || ev.studio_mode !== "premiere") return json({ error: "Event not found" }, 404);
  const film = await filmOf_(ev.id, admin);
  if (!film?.trailer_uid || film.trailer_status !== "ready") return json({ url: null, posterUrl: film?.poster_url ?? null });
  const exp = Math.floor(Date.now() / 1000) + 2 * 3600;
  const token = await signPlaybackToken(film.trailer_uid, KEY_ID, JWK, exp);
  return json({ url: manifestUrl(film.playback_host, token), expiresAt: exp * 1000, posterUrl: film.poster_url ?? null });
}

async function handle(req: Request, json: Json, ctx: Record<string, unknown>): Promise<Response> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "Missing Authorization header" }, 401);
  const userClient = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error } = await userClient.auth.getUser();
  if (error || !user) return json({ error: "Unauthorized" }, 401);
  ctx.userId = user.id;
  if (!KEY_ID || !JWK || !STREAM_API.includes("/accounts/") || STREAM_API.includes("/accounts//")) {
    return json({ error: "Premiere isn't configured yet" }, 503);
  }
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const body = await req.json().catch(() => ({}));
  ctx.action = body.action;
  switch (body.action) {
    case "create-upload": return await createUpload(body, user.id, admin, json);
    case "refresh": return await refresh(body, user.id, admin, json);
    case "set-details": return await setDetails(body, user.id, admin, json);
    case "add-captions": return await addCaptions(body, user.id, admin, json);
    case "remove-captions": return await removeCaptions(body, user.id, admin, json);
    case "delete-media": return await deleteMedia(body, user.id, admin, json);
    case "playback-token": return await playbackToken(body, user.id, admin, json);
    case "trailer-token": return await trailerToken(body, user.id, admin, json);
    case "rate-film": return await rateFilm(body, user.id, admin, json);
    case "ratings": return await ratings(body, user.id, admin, json);
    case "replay-chapters": return await replayChapters(body, user.id, admin, json);
    default: return json({ error: "Unknown action" }, 400);
  }
}

serve(async (req) => {
  const cors = corsHeadersFor(req);
  const json = makeJson(cors);
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const ctx: Record<string, unknown> = { reqId: crypto.randomUUID().slice(0, 8) };
  const t0 = Date.now();
  try {
    const res = await handle(req, json, ctx);
    log(res.status < 400 ? "info" : "warn", { ...ctx, status: res.status, ms: Date.now() - t0 });
    return res;
  } catch (err) {
    log("error", { ...ctx, status: 500, error: String(err), stack: err instanceof Error ? err.stack : undefined });
    return json(failure(err, "premiere"), 500);
  }
});
