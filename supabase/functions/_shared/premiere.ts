// Premiere mode (docs/plans/studio-modes.md, phases 6-8) — the rules behind the
// premiere and premiere-webhook functions. Pure apart from WebCrypto, so it can
// be unit tested. Mirrors lib/services/premiere.dart.
//
// Films and trailers live in Cloudflare Stream with signed URLs required: a
// Stream video id alone plays nothing. Playback tokens are RS256 JWTs signed
// here with the account's Stream signing key (CF_STREAM_SIGNING_KEY_ID +
// CF_STREAM_SIGNING_JWK, the base64 JWK Cloudflare returned).

export const MAX_FILM_SECONDS = 8 * 3600;
export const MAX_TRAILER_SECONDS = 5 * 60;
/** Films are kept at least this long after the show, whatever the replay choice. */
export const MIN_KEEP_MS = 7 * 24 * 3600_000;
export const REMINDER_LEAD_MS = 2 * 24 * 3600_000;
export const MAX_CAPTION_BYTES = 2 * 1024 * 1024;
/** Per host: uploads open at once, and film/trailer time kept in Stream. */
export const MAX_ACTIVE_UPLOADS = 3;
export const MAX_STORED_SECONDS = 24 * 3600;
/** A show that never went live counts as over this long after its start time. */
export const STALE_SHOW_MS = 7 * 24 * 3600_000;

export type MediaKind = "film" | "trailer";
export type MediaStatus = "none" | "uploading" | "processing" | "ready" | "error";
export const RATINGS = ["G", "PG", "PG-13", "R", "NC-17", "NR", "18+"] as const;
export const REPLAY_POLICIES = ["none", "24h", "48h", "7d", "forever"] as const;
export const CHAT_POLICIES = ["open", "reactions", "slow"] as const;
export type ReplayPolicy = typeof REPLAY_POLICIES[number];

export const isKind = (v: unknown): v is MediaKind => v === "film" || v === "trailer";

/** Upload-Metadata for a tus upload: `key base64(value)`, comma separated; bare keys are flags. */
export function tusMetadata(fields: Record<string, string | true>): string {
  return Object.entries(fields)
    .map(([k, v]) => (v === true ? k : `${k} ${btoa(unescape(encodeURIComponent(v)))}`))
    .join(",");
}

/**
 * Seconds of storage Stream reserves while a tus upload is open. The client
 * reports the file's duration when it can read it; otherwise a film reserves
 * 4 hours (an 8-hour reservation would tie up half the starter plan).
 */
export function reserveSeconds(kind: MediaKind, reported: unknown): number {
  const max = kind === "film" ? MAX_FILM_SECONDS : MAX_TRAILER_SECONDS;
  if (typeof reported !== "number" || !isFinite(reported) || reported <= 0) {
    return kind === "film" ? 4 * 3600 : MAX_TRAILER_SECONDS;
  }
  return Math.min(max, Math.max(60, Math.ceil(reported * 1.02) + 60));
}

export type DetailsPatch = {
  rating?: string | null;
  content_warning?: string | null;
  replay_policy?: ReplayPolicy;
  chat_policy?: string;
  poster_url?: string | null;
  rights_confirmed_at?: string | null;
};

/**
 * The filmmaker's choices, validated. Only keys present in [body] change.
 * [posterPrefix] is the only place a poster may live (our public `events`
 * bucket), so a poster can't be a tracking pixel or an unmoderated image.
 */
export function cleanDetails(
  body: Record<string, unknown>,
  now: number,
  posterPrefix: string,
): { patch: DetailsPatch } | { error: string } {
  const patch: DetailsPatch = {};
  if ("rating" in body) {
    if (body.rating !== null && !RATINGS.includes(body.rating as typeof RATINGS[number])) return { error: "Pick a rating from the list" };
    patch.rating = body.rating as string | null;
  }
  if ("contentWarning" in body) {
    const w = body.contentWarning;
    if (w !== null && typeof w !== "string") return { error: "Content warning must be text" };
    const t = typeof w === "string" ? w.trim() : "";
    if (t.length > 200) return { error: "Content warnings are up to 200 characters" };
    patch.content_warning = t.length ? t : null;
  }
  if ("replayPolicy" in body) {
    if (!REPLAY_POLICIES.includes(body.replayPolicy as ReplayPolicy)) return { error: "Pick a replay option" };
    patch.replay_policy = body.replayPolicy as ReplayPolicy;
  }
  if ("chatPolicy" in body) {
    if (!CHAT_POLICIES.includes(body.chatPolicy as typeof CHAT_POLICIES[number])) return { error: "Pick a chat option" };
    patch.chat_policy = body.chatPolicy as string;
  }
  if ("posterUrl" in body) {
    const u = body.posterUrl;
    if (u !== null && (typeof u !== "string" || !u.startsWith(posterPrefix) || /\s|\.\./.test(u) || u.length > 1000)) {
      return { error: "That poster link isn't valid" };
    }
    patch.poster_url = u as string | null;
  }
  if ("rightsConfirmed" in body) {
    if (typeof body.rightsConfirmed !== "boolean") return { error: "rightsConfirmed must be true or false" };
    patch.rights_confirmed_at = body.rightsConfirmed ? new Date(now).toISOString() : null;
  }
  if (Object.keys(patch).length === 0) return { error: "Nothing to change" };
  return { patch };
}

/** How long after the show the replay stays up; null = until the filmmaker deletes it. */
export function replayWindowMs(policy: ReplayPolicy): number | null {
  switch (policy) {
    case "none": return 0;
    case "24h": return 24 * 3600_000;
    case "48h": return 48 * 3600_000;
    case "7d": return 7 * 24 * 3600_000;
    case "forever": return null;
  }
}

/** When the film is deleted from Stream: the replay window, but never sooner than 7 days. */
export function deleteAfter(endedAt: number, policy: ReplayPolicy): number | null {
  const w = replayWindowMs(policy);
  return w === null ? null : endedAt + Math.max(w, MIN_KEEP_MS);
}

export const reminderDue = (deleteAt: number | null, now: number, sentAt: string | null) =>
  deleteAt !== null && sentAt === null && now >= deleteAt - REMINDER_LEAD_MS && now < deleteAt;

export type WatchCheck = {
  isHost: boolean;
  isCrew: boolean;
  status: string;
  price: number;
  replayPrice: number;
  hasTicket: boolean;
  endedAt: number | null;
  policy: ReplayPolicy;
  now: number;
};

/** May this person get a playback token for the film right now? */
export function canWatchFilm(c: WatchCheck): { ok: true } | { error: string; status: number } {
  if (c.isHost) return { ok: true }; // previewing their own film, any time
  if (c.status === "soundcheck") {
    // Viewers wait in the lobby; the film isn't theirs until the show starts.
    return c.isCrew ? { ok: true } : { error: "The premiere hasn't started", status: 403 };
  }
  if (c.status === "live") {
    if (c.isCrew) return { ok: true };
    return c.price <= 0 || c.hasTicket ? { ok: true } : { error: "You need a ticket to watch", status: 403 };
  }
  if (c.status === "ended" && c.endedAt !== null) {
    const w = replayWindowMs(c.policy);
    const open = w === null || c.now < c.endedAt + w;
    if (w === 0 || !open) return { error: "The replay isn't available", status: 403 };
    // Free only when both the show and its replay are free; a ticket of either
    // kind covers it (live holders always rewatch), as with other replays.
    const paidOk = (c.price <= 0 && c.replayPrice <= 0) || c.hasTicket;
    return paidOk || c.isCrew ? { ok: true } : { error: "You need a ticket to watch", status: 403 };
  }
  return { error: "The premiere hasn't started", status: 403 };
}

/**
 * When a playback token expires (unix seconds). A token is a link anyone can
 * use, so viewers get an hour (the player asks for a fresh one as it goes)
 * and never past the end of the replay window. The host's own preview lasts
 * the film plus slack, 1-12 h.
 */
export function tokenExpiry(o: { isHost: boolean; durationS: number | null; now: number; replayEndsAt: number | null }): number {
  const nowS = Math.floor(o.now / 1000);
  if (o.isHost) {
    const d = o.durationS && o.durationS > 0 ? o.durationS : 3 * 3600;
    return nowS + Math.min(12 * 3600, Math.max(3600, Math.ceil(d) + 2 * 3600));
  }
  const exp = nowS + 3600;
  return o.replayEndsAt === null ? exp : Math.min(exp, Math.floor(o.replayEndsAt / 1000));
}

/**
 * The upload quota for one host: [rows] are their event_films rows. The slot
 * being replaced ([eventId], [kind]) doesn't count against them.
 */
export function checkQuota(
  rows: Array<Record<string, any>>,
  eventId: string,
  kind: MediaKind,
  reserve: number,
): { error: string; status: number } | null {
  let active = 0, stored = 0;
  for (const r of rows) {
    for (const k of ["film", "trailer"] as MediaKind[]) {
      if (r.event_id === eventId && k === kind) continue;
      const st = r[`${k}_status`];
      if (st === "uploading" || st === "processing") active++;
      if (st !== "none" && st !== "error") stored += Number(r[`${k}_duration_s`]) || (st === "ready" ? 0 : 3600);
    }
  }
  if (active >= MAX_ACTIVE_UPLOADS) return { error: "You have 3 uploads going. Let one finish first.", status: 429 };
  if (stored + reserve > MAX_STORED_SECONDS) {
    return { error: "You've reached 24 hours of films on Nile. Delete one to upload more.", status: 429 };
  }
  return null;
}

/**
 * When the sweep counts a show as over (the anchor for deleting its film):
 * it ended, was cancelled or removed, or never went live a week after its
 * start time. Uses the moment the sweep first sees it, not a host-editable
 * column, so the deletion date can't be pushed back by editing the event.
 */
export function showIsOver(ev: { status: string; removed_at: string | null; scheduled_at: string | null }, now: number): boolean {
  if (ev.status === "ended" || ev.status === "cancelled" || ev.removed_at) return true;
  if (ev.status === "live" || ev.status === "soundcheck") return false;
  const at = ev.scheduled_at ? Date.parse(ev.scheduled_at) : NaN;
  return isFinite(at) && now > at + STALE_SHOW_MS;
}

const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const b64urlJson = (o: unknown) => b64url(new TextEncoder().encode(JSON.stringify(o)));

/** A Stream signed-URL token for [uid], valid until [exp] (unix seconds). */
export async function signPlaybackToken(uid: string, keyId: string, jwkBase64: string, exp: number, nbf?: number): Promise<string> {
  const jwk = JSON.parse(atob(jwkBase64));
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const head = b64urlJson({ alg: "RS256", kid: keyId });
  const body = b64urlJson({ sub: uid, kid: keyId, exp, ...(nbf ? { nbf } : {}) });
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${head}.${body}`));
  return `${head}.${body}.${b64url(new Uint8Array(sig))}`;
}

/** HLS manifest URL for a signed token. */
export const manifestUrl = (host: string | null, token: string) =>
  `https://${host ?? "videodelivery.net"}/${token}/manifest/video.m3u8`;

/** Verifies Cloudflare's `Webhook-Signature: time=…,sig1=…` (HMAC-SHA256 of "time.body"). */
export async function verifyWebhook(header: string | null, body: string, secret: string, nowSec: number, toleranceSec = 600): Promise<boolean> {
  if (!header || !secret) return false;
  const parts = Object.fromEntries(header.split(",").map((p) => {
    const i = p.indexOf("=");
    return [p.slice(0, i).trim(), p.slice(i + 1).trim()];
  }));
  const time = Number(parts.time), sig = parts.sig1;
  if (!isFinite(time) || !sig || Math.abs(nowSec - time) > toleranceSec) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${parts.time}.${body}`)));
  const expected = [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
  if (expected.length !== sig.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ sig.charCodeAt(i);
  return diff === 0;
}

export type StreamVideoState = { uid: string; status: MediaStatus; durationS: number | null; host: string | null; error: string | null };

/** A Stream video object (webhook body or GET /stream/<uid> result) → what we store. */
export function streamStateOf(v: Record<string, any>): StreamVideoState | null {
  if (!v || typeof v.uid !== "string") return null;
  const state = v.status?.state as string | undefined;
  const status: MediaStatus = v.readyToStream === true || state === "ready"
    ? "ready"
    : state === "error"
    ? "error"
    : state === "pendingupload" || state === "downloading"
    ? "uploading"
    : "processing";
  let host: string | null = null;
  try {
    host = v.playback?.hls ? new URL(v.playback.hls).host : null;
  } catch { /* keep null */ }
  const d = typeof v.duration === "number" && v.duration > 0 ? v.duration : null;
  const error = status === "error" ? (v.status?.errorReasonText || v.status?.errorReasonCode || "Processing failed") : null;
  return { uid: v.uid, status, durationS: d, host, error };
}

/** Caption language tag, e.g. en, es, pt-BR. */
export const isCaptionLang = (v: unknown): v is string => typeof v === "string" && /^[a-z]{2,3}(-[A-Z]{2})?$/.test(v);

/** WebVTT text the client sent (it converts .srt itself). */
export function checkVtt(text: unknown): string | null {
  if (typeof text !== "string" || !text.trimStart().startsWith("WEBVTT")) return "Captions must be a WebVTT (.vtt) or SubRip (.srt) file";
  if (new TextEncoder().encode(text).length > MAX_CAPTION_BYTES) return "That caption file is too large (2 MB max)";
  return null;
}
