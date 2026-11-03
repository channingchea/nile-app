// Premiere (phase 6): upload reservations, filmmaker details, who may watch,
// deletion timing, playback-token signing and webhook signatures.
//
//   deno test --allow-env supabase/functions/tests/

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  cleanDetails as clean,
  canWatchFilm,
  checkQuota,
  checkVtt,
  deleteAfter,
  isCaptionLang,
  manifestUrl,
  MAX_FILM_SECONDS,
  reminderDue,
  reserveSeconds,
  showIsOver,
  signPlaybackToken,
  streamStateOf,
  tokenExpiry,
  tusMetadata,
  verifyWebhook,
} from "../_shared/premiere.ts";

const H = 3600_000, D = 24 * H;

Deno.test("tus metadata: base64 values, bare flags", () => {
  assertEquals(tusMetadata({ maxdurationseconds: "600", requiresignedurls: true }), "maxdurationseconds NjAw,requiresignedurls");
  assertEquals(tusMetadata({ name: "Café" }), `name ${btoa("CafÃ©")}`);
});

Deno.test("reservations: reported duration plus slack, capped; 4 h when unknown", () => {
  assertEquals(reserveSeconds("film", undefined), 4 * 3600);
  assertEquals(reserveSeconds("film", 5400), Math.ceil(5400 * 1.02) + 60);
  assertEquals(reserveSeconds("film", 99 * 3600), MAX_FILM_SECONDS);
  assertEquals(reserveSeconds("trailer", 90), Math.ceil(90 * 1.02) + 60);
  assertEquals(reserveSeconds("trailer", 3600), 300);
});

const POSTERS = "https://p.supabase.co/storage/v1/object/public/events/";

Deno.test("details: validated, only what's sent changes", () => {
  const now = Date.parse("2026-11-02T00:00:00Z");
  const cleanDetails = (b: Record<string, unknown>, n: number) => clean(b, n, POSTERS);
  assertEquals(cleanDetails({ rating: "PG-13", replayPolicy: "48h" }, now), { patch: { rating: "PG-13", replay_policy: "48h" } });
  assertEquals(cleanDetails({ contentWarning: "  " }, now), { patch: { content_warning: null } });
  assertEquals(cleanDetails({ rightsConfirmed: true }, now), { patch: { rights_confirmed_at: new Date(now).toISOString() } });
  assert("error" in cleanDetails({ rating: "X" }, now));
  assert("error" in cleanDetails({ chatPolicy: "loud" }, now));
  assert("error" in cleanDetails({ posterUrl: "https://tracker.example/p.gif" }, now));
  assert("error" in cleanDetails({ posterUrl: `${POSTERS}../secret` }, now));
  assertEquals(cleanDetails({ posterUrl: `${POSTERS}slug/poster.jpg?t=1` }, now), {
    patch: { poster_url: `${POSTERS}slug/poster.jpg?t=1` },
  });
  assert("error" in cleanDetails({ contentWarning: "x".repeat(201) }, now));
  assert("error" in cleanDetails({}, now));
});

Deno.test("deletion: replay window but at least 7 days; forever never", () => {
  const end = 0;
  assertEquals(deleteAfter(end, "none"), 7 * D);
  assertEquals(deleteAfter(end, "24h"), 7 * D);
  assertEquals(deleteAfter(end, "7d"), 7 * D);
  assertEquals(deleteAfter(end, "forever"), null);
  assert(reminderDue(7 * D, 5 * D, null));
  assert(!reminderDue(7 * D, 5 * D - 1, null));
  assert(!reminderDue(7 * D, 5 * D, "sent"));
  assert(!reminderDue(7 * D, 7 * D, null));
  assert(!reminderDue(null, 5 * D, null));
});

Deno.test("who may watch", () => {
  const base = { isHost: false, isCrew: false, status: "live", price: 1500, replayPrice: 0, hasTicket: false, endedAt: null, policy: "none" as const, now: 10 * H };
  assert("ok" in canWatchFilm({ ...base, isHost: true, status: "scheduled" }));
  assert("error" in canWatchFilm(base));
  assert("ok" in canWatchFilm({ ...base, hasTicket: true }));
  assert("ok" in canWatchFilm({ ...base, price: 0 }));
  assert("ok" in canWatchFilm({ ...base, isCrew: true }));
  assert("error" in canWatchFilm({ ...base, status: "scheduled", hasTicket: true }));
  assert("error" in canWatchFilm({ ...base, status: "soundcheck", hasTicket: true })); // lobby waits
  assert("ok" in canWatchFilm({ ...base, status: "soundcheck", isCrew: true }));
  const ended = { ...base, status: "ended", hasTicket: true, endedAt: 9 * H };
  assert("error" in canWatchFilm(ended)); // no replay
  assert("ok" in canWatchFilm({ ...ended, policy: "24h" }));
  assert("error" in canWatchFilm({ ...ended, policy: "24h", now: 9 * H + 25 * H }));
  assert("ok" in canWatchFilm({ ...ended, policy: "forever", now: 1000 * D }));
  assert("error" in canWatchFilm({ ...ended, policy: "forever", hasTicket: false }));
  const freeShow = { ...ended, price: 0, hasTicket: false, policy: "7d" as const };
  assert("ok" in canWatchFilm(freeShow));
  assert("error" in canWatchFilm({ ...freeShow, replayPrice: 500 })); // priced replay of a free show
});

Deno.test("token lifetime: viewers 1 h (never past the replay), host the whole film", () => {
  const now = 1_000_000_000_000, s = now / 1000;
  assertEquals(tokenExpiry({ isHost: false, durationS: 7200, now, replayEndsAt: null }), s + 3600);
  assertEquals(tokenExpiry({ isHost: false, durationS: 7200, now, replayEndsAt: now + 60_000 }), s + 60);
  assertEquals(tokenExpiry({ isHost: true, durationS: 600, now, replayEndsAt: null }), s + 600 + 7200);
  assertEquals(tokenExpiry({ isHost: true, durationS: null, now, replayEndsAt: null }), s + 5 * 3600);
  assertEquals(tokenExpiry({ isHost: true, durationS: 20 * 3600, now, replayEndsAt: null }), s + 12 * 3600);
  assertEquals(manifestUrl("customer-x.cloudflarestream.com", "t"), "https://customer-x.cloudflarestream.com/t/manifest/video.m3u8");
});

Deno.test("playback tokens: RS256 JWT that verifies with the key's public half", async () => {
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  );
  const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
  const token = await signPlaybackToken("vid123", "kid9", btoa(JSON.stringify(jwk)), 2000000000);
  const [h, b, s] = token.split(".");
  const dec = (x: string) => JSON.parse(atob(x.replace(/-/g, "+").replace(/_/g, "/")));
  assertEquals(dec(h), { alg: "RS256", kid: "kid9" });
  assertEquals(dec(b), { sub: "vid123", kid: "kid9", exp: 2000000000 });
  const sig = Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
  assert(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", pair.publicKey, sig, new TextEncoder().encode(`${h}.${b}`)));
});

Deno.test("webhook signatures: right secret and fresh time only", async () => {
  const body = '{"uid":"a"}', secret = "s3cret", t = 1700000000;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${t}.${body}`)));
  const sig = [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
  assert(await verifyWebhook(`time=${t},sig1=${sig}`, body, secret, t + 5));
  assert(!(await verifyWebhook(`time=${t},sig1=${sig}`, body + " ", secret, t + 5)));
  assert(!(await verifyWebhook(`time=${t},sig1=${sig}`, body, "other", t + 5)));
  assert(!(await verifyWebhook(`time=${t},sig1=${sig}`, body, secret, t + 3600)));
  assert(!(await verifyWebhook(null, body, secret, t)));
});

Deno.test("stream state from a webhook body", () => {
  assertEquals(
    streamStateOf({ uid: "u", readyToStream: true, duration: 61.5, status: { state: "ready" }, playback: { hls: "https://customer-ab.cloudflarestream.com/u/manifest/video.m3u8" } }),
    { uid: "u", status: "ready", durationS: 61.5, host: "customer-ab.cloudflarestream.com", error: null },
  );
  assertEquals(streamStateOf({ uid: "u", status: { state: "error", errorReasonText: "Bad codec" } })?.error, "Bad codec");
  assertEquals(streamStateOf({ uid: "u", status: { state: "inprogress" }, duration: -1 })?.status, "processing");
  assertEquals(streamStateOf({ uid: "u", status: { state: "pendingupload" } })?.status, "uploading");
  assertEquals(streamStateOf({}), null);
});

Deno.test("captions: language tags and WebVTT only", () => {
  assert(isCaptionLang("en") && isCaptionLang("pt-BR") && !isCaptionLang("EN") && !isCaptionLang("english"));
  assertEquals(checkVtt("WEBVTT\n\n00:00.000 --> 00:01.000\nHi"), null);
  assert(checkVtt("1\n00:00:00,000 --> 00:00:01,000\nHi") !== null);
});

Deno.test("quota: 3 uploads at once, 24 h stored; the slot being replaced is free", () => {
  const busy = (id: string) => ({ event_id: id, film_status: "uploading", film_duration_s: null, trailer_status: "none" });
  assertEquals(checkQuota([busy("a"), busy("b")], "c", "film", 3600), null);
  assert(checkQuota([busy("a"), busy("b"), busy("c")], "d", "film", 3600) !== null);
  assertEquals(checkQuota([busy("a"), busy("b"), busy("c")], "c", "film", 3600), null);
  const big = (id: string) => ({ event_id: id, film_status: "ready", film_duration_s: 10 * 3600, trailer_status: "none" });
  assertEquals(checkQuota([big("a")], "b", "film", 4 * 3600), null);
  assert(checkQuota([big("a"), big("b")], "c", "film", 5 * 3600) !== null);
});

Deno.test("a show is over when ended, cancelled, removed or a week stale", () => {
  const now = Date.parse("2026-11-20T00:00:00Z");
  const ev = (status: string, scheduled = "2026-11-19T00:00:00Z", removed: string | null = null) =>
    ({ status, scheduled_at: scheduled, removed_at: removed });
  assert(showIsOver(ev("ended"), now));
  assert(showIsOver(ev("cancelled"), now));
  assert(showIsOver(ev("scheduled", undefined, "2026-11-19T00:00:00Z"), now));
  assert(!showIsOver(ev("scheduled"), now));
  assert(showIsOver(ev("scheduled", "2026-11-10T00:00:00Z"), now));
  assert(!showIsOver(ev("live", "2026-11-01T00:00:00Z"), now));
});
