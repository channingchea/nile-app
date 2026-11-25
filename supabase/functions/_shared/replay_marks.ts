// What Nile's recorder page may report about a grid replay (studio live
// elements, phase 6). Pure, so it can be unit tested. Read back by
// lib/services/replay_timeline.dart.

export type MarkKind = "start" | "tiles" | "meta" | "end";
export type Mark = { seq: number; offset_ms: number; kind: MarkKind; data: unknown };

export const MAX_MARKS_PER_CALL = 100;
export const MAX_SEQ = 20000;
const MAX_OFFSET_MS = 12 * 60 * 60 * 1000;
const MAX_TILES = 16;
const MAX_META_CHARS = 60000;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isRecorderKey = (k: unknown): k is string => typeof k === "string" && UUID.test(k);

const frac = (n: unknown) => typeof n === "number" && Number.isFinite(n) && n >= 0 && n <= 1;
const shortId = (s: unknown) => typeof s === "string" && s.length >= 1 && s.length <= 80;

function cleanTiles(d: unknown): unknown[] | null {
  if (!Array.isArray(d) || d.length > MAX_TILES) return null;
  const out = [];
  for (const t of d) {
    if (!t || typeof t !== "object") return null;
    const { s, el, r } = t as Record<string, unknown>;
    if (!Array.isArray(r) || r.length !== 4 || !r.every(frac)) return null;
    if (s != null && !shortId(s)) return null;
    if (el != null && !shortId(el)) return null;
    out.push({ s: s ?? null, el: el ?? null, r });
  }
  return out;
}

/** One reported mark, or null when it doesn't fit. Room metadata arrives as its JSON string. */
export function cleanMark(m: unknown): Mark | null {
  if (!m || typeof m !== "object") return null;
  const { s, o, k, d } = m as Record<string, unknown>;
  if (!Number.isInteger(s) || (s as number) < 0 || (s as number) > MAX_SEQ) return null;
  if (!Number.isInteger(o) || (o as number) < 0 || (o as number) > MAX_OFFSET_MS) return null;
  const base = { seq: s as number, offset_ms: o as number };
  switch (k) {
    case "start": {
      const wall = (d as Record<string, unknown> | null)?.wall;
      return typeof wall === "number" && wall > 0 ? { ...base, kind: "start", data: { wall } } : null;
    }
    case "end":
      return { ...base, kind: "end", data: {} };
    case "tiles": {
      const tiles = cleanTiles(d);
      return tiles ? { ...base, kind: "tiles", data: tiles } : null;
    }
    case "meta": {
      if (typeof d !== "string" || d.length > MAX_META_CHARS) return null;
      try {
        const parsed = JSON.parse(d || "{}");
        return parsed && typeof parsed === "object" && !Array.isArray(parsed)
          ? { ...base, kind: "meta", data: parsed }
          : null;
      } catch {
        return null;
      }
    }
  }
  return null;
}

/** A recorder upload: the marks that fit (bad ones are dropped, not fatal). */
export function cleanUpload(body: unknown): { key: string; marks: Mark[] } | { error: string } {
  const b = (body ?? {}) as Record<string, unknown>;
  if (!isRecorderKey(b.key)) return { error: "bad key" };
  if (!Array.isArray(b.marks) || b.marks.length > MAX_MARKS_PER_CALL) return { error: "bad marks" };
  return { key: b.key, marks: b.marks.map(cleanMark).filter((m): m is Mark => m !== null) };
}

/**
 * Marks as the replay screen reads them: { o, k, d } sorted by video time.
 * Server-written tallies carry no offset; they are placed from their wall
 * time and the moment the page started recording.
 */
export function timelineOf(
  rows: { offset_ms: number | null; at: string; kind: string; data: unknown }[],
  startedAt: string | null,
): { o: number; k: string; d: unknown }[] {
  const start = startedAt ? Date.parse(startedAt) : NaN;
  const out: { o: number; k: string; d: unknown }[] = [];
  for (const r of rows) {
    const o = r.offset_ms ?? (Number.isNaN(start) ? null : Date.parse(r.at) - start);
    if (o == null || o < 0) continue;
    out.push({ o, k: r.kind, d: r.data });
  }
  return out.sort((a, b) => a.o - b.o);
}
