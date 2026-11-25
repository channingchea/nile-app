// Cloudflare Stream API client for the premiere functions. Secrets:
// CF_ACCOUNT_ID, CF_STREAM_API_TOKEN (Stream Edit on this account only).

const ACCOUNT = Deno.env.get("CF_ACCOUNT_ID") ?? "";
const TOKEN = Deno.env.get("CF_STREAM_API_TOKEN") ?? "";
export const STREAM_API = `https://api.cloudflare.com/client/v4/accounts/${ACCOUNT}/stream`;

export function streamFetch(path: string, init: RequestInit = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  headers.set("Authorization", `Bearer ${TOKEN}`);
  return fetch(`${STREAM_API}${path}`, { ...init, headers });
}

/** GET /stream/<uid> → the video object, or null if Stream doesn't have it. */
export async function getVideo(uid: string): Promise<Record<string, unknown> | null> {
  const res = await streamFetch(`/${uid}`);
  if (res.status === 404) return null;
  const body = await res.json().catch(() => ({}));
  if (!res.ok || !body.success) throw new Error(`stream get ${res.status}: ${JSON.stringify(body.errors ?? [])}`);
  return body.result;
}

/** Deletes a video; already gone counts as done. */
export async function deleteVideo(uid: string): Promise<void> {
  const res = await streamFetch(`/${uid}`, { method: "DELETE" });
  if (!res.ok && res.status !== 404) throw new Error(`stream delete ${res.status}: ${await res.text()}`);
}

/** Makes sure a video can only be played with a signed token. */
export async function ensureSigned(v: Record<string, unknown>): Promise<void> {
  if (v.requireSignedURLs === true || typeof v.uid !== "string") return;
  const res = await streamFetch(`/${v.uid}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ uid: v.uid, requireSignedURLs: true }),
  });
  if (!res.ok) throw new Error(`stream lock ${res.status}: ${await res.text()}`);
}

/**
 * Deletes queued videos (stream_deletions, migration 0152) from Stream.
 * Best-effort: a failure stays queued for the next run.
 */
// deno-lint-ignore no-explicit-any
export async function drainDeletions(admin: any, limit = 25): Promise<number> {
  const { data } = await admin.from("stream_deletions").select("uid, attempts").order("queued_at").limit(limit);
  let done = 0;
  for (const r of data ?? []) {
    try {
      await deleteVideo(r.uid);
      await admin.from("stream_deletions").delete().eq("uid", r.uid);
      done++;
    } catch (err) {
      console.log(JSON.stringify({ level: "warn", fn: "stream", action: "drain", uid: r.uid, error: String(err) }));
      await admin.from("stream_deletions").update({ attempts: r.attempts + 1 }).eq("uid", r.uid);
    }
  }
  return done;
}
