// Studio graphics on air (Studio master host, phase 5) — the shape the
// `set-graphics` action accepts and writes into LiveKit room metadata under
// `graphics`. Mirrors GraphicsState / LiveGraphic in
// lib/services/studio_graphics.dart. Pure, so it can be unit tested.

const KINDS = new Set(["lower_third", "logo", "banner", "slate"]);
const CORNERS = new Set(["tl", "tr", "bl", "br"]);
const SIZES = new Set(["s", "m", "l"]);

/** Room metadata is broadcast to every viewer; keep the graphics part small. */
export const MAX_GRAPHICS_JSON = 8000;

export interface LiveGraphic {
  id: string;
  kind: string;
  title?: string;
  subtitle?: string;
  text?: string;
  imageUrl?: string;
  corner?: string;
  size?: string;
  scrolling?: true;
  endsAt?: number;
}

export interface GraphicsState {
  all: LiveGraphic[];
  bySlot: Record<string, LiveGraphic[]>;
}

const str = (v: unknown, max: number) =>
  typeof v === "string" && v.length <= max ? v : undefined;

/** One cap key per target: one lower third, one logo per corner, one banner, one slate. */
export const capKey = (g: LiveGraphic) => (g.kind === "logo" ? `logo:${g.corner}` : g.kind);

/**
 * Normalize one graphic, or null if it can't be drawn. Images must come from
 * the studio-graphics bucket ([imagePrefix]) — room metadata is not a way to
 * make every viewer's app fetch an arbitrary URL.
 */
export function cleanGraphic(raw: unknown, imagePrefix: string): LiveGraphic | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  const id = str(r.id, 80);
  const kind = typeof r.kind === "string" && KINDS.has(r.kind) ? r.kind : undefined;
  if (!id || !kind) return null;

  const g: LiveGraphic = { id, kind };
  const title = str(r.title, 60);
  const subtitle = str(r.subtitle, 120);
  const text = str(r.text, 140);
  const imageUrl = str(r.imageUrl, 500);
  if (title) g.title = title;
  if (subtitle) g.subtitle = subtitle;
  if (text) g.text = text;
  if (imageUrl) {
    if (!imageUrl.startsWith(imagePrefix)) return null;
    g.imageUrl = imageUrl;
  }

  switch (kind) {
    case "lower_third":
      return g.title ? g : null;
    case "logo":
      if (!g.imageUrl || typeof r.corner !== "string" || !CORNERS.has(r.corner)) return null;
      g.corner = r.corner;
      if (typeof r.size === "string" && SIZES.has(r.size)) g.size = r.size;
      return g;
    case "banner":
      if (!g.text) return null;
      if (r.scrolling === true) g.scrolling = true;
      return g;
    case "slate":
      if (!g.title) return null;
      if (typeof r.endsAt === "number" && Number.isFinite(r.endsAt)) g.endsAt = Math.round(r.endsAt);
      return g;
  }
  return null;
}

/** Drop bad entries and enforce the caps — the last graphic of a cap key wins. */
function cleanList(raw: unknown, imagePrefix: string): LiveGraphic[] {
  if (!Array.isArray(raw)) return [];
  const byCap = new Map<string, LiveGraphic>();
  for (const item of raw.slice(0, 20)) {
    const g = cleanGraphic(item, imagePrefix);
    if (g) {
      byCap.delete(capKey(g)); // keep insertion order = latest last
      byCap.set(capKey(g), g);
    }
  }
  return [...byCap.values()];
}

/**
 * Validate a whole graphics state from the Studio. Per-slot lists are kept
 * only for the event's real slots. Returns the normalized state or an error.
 */
export function validateGraphics(
  raw: unknown,
  opts: { imagePrefix: string; slotIds: Set<string> },
): { state: GraphicsState } | { error: string } {
  if (!raw || typeof raw !== "object") return { error: "graphics must be an object" };
  const r = raw as Record<string, unknown>;
  const state: GraphicsState = { all: cleanList(r.all, opts.imagePrefix), bySlot: {} };
  if (r.bySlot && typeof r.bySlot === "object") {
    for (const [slotId, list] of Object.entries(r.bySlot as Record<string, unknown>)) {
      if (!opts.slotIds.has(slotId)) continue;
      const clean = cleanList(list, opts.imagePrefix);
      if (clean.length) state.bySlot[slotId] = clean;
    }
  }
  if (JSON.stringify(state).length > MAX_GRAPHICS_JSON) {
    return { error: "Too many graphics on screen at once" };
  }
  return { state };
}

/** Resync is rate-limited: once per 10 s per room. Returns ms to wait, or 0. */
export function resyncWait(lastResyncAt: unknown, now: number, windowMs = 10_000): number {
  if (typeof lastResyncAt !== "number") return 0;
  const left = lastResyncAt + windowMs - now;
  return left > 0 ? left : 0;
}

/**
 * Room metadata is shared by several writers (start-show's showStartedAt,
 * set-master-audio's masterAudio, graphics, resyncAt). Every write merges.
 */
export const mergeRoomMeta = (meta: Record<string, unknown>, patch: Record<string, unknown>) => ({
  ...meta,
  ...patch,
});
