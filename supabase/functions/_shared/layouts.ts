// Studio Layouts (docs/plans/studio-layouts.md, phase 3): the pure rules
// behind the livekit `apply-layout` action. The Studio resolves a saved layout
// against the show (lib/services/studio_layouts.dart → resolveLayout) and
// sends the result here in one request; it is validated with the same rules as
// set-graphics / set-layout / set-show / set-element and written as ONE room
// metadata update, so viewers never see half a layout.

import {
  angleIdOf,
  buildRow,
  type ElementPush,
  type ElementRow,
  liveSnapshot,
  type LayoutState,
  MAX_ELEMENTS_JSON,
  MAX_LIVE_ELEMENTS,
  rowToLive,
  validateElementPush,
  validateLayout,
} from "./elements.ts";
import { type GraphicOpts, type GraphicsState, validateGraphics } from "./graphics.ts";

/** Which saved layout is on air, and the version of it that was applied. */
export interface AppliedRef {
  id: string;
  updatedAt: string;
}

export interface ApplyPlan {
  graphics: GraphicsState;
  layout: LayoutState;
  elements: ElementPush[];
  applied: AppliedRef;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const isObj = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);

/** Validate everything in an apply-layout body except show control (which needs the resulting element angles). */
export function validateApply(
  body: Record<string, unknown>,
  opts: GraphicOpts & { slotIds: Set<string>; sponsorCampaignId?: string | null },
): { plan: ApplyPlan } | { error: string } {
  const a = body.applied;
  if (!isObj(a) || typeof a.id !== "string" || !UUID.test(a.id)) return { error: "Which layout is this?" };
  const updatedAt = typeof a.updatedAt === "string" && a.updatedAt.length <= 40 ? a.updatedAt : "";

  const g = validateGraphics(body.graphics, opts);
  if ("error" in g) return g;
  const l = validateLayout(body.layout, opts.slotIds);
  if ("error" in l) return l;

  const raw = body.elements ?? [];
  if (!Array.isArray(raw) || raw.length > MAX_LIVE_ELEMENTS) return { error: "elements must be a list" };
  const elements: ElementPush[] = [];
  const seen = new Set<string>();
  for (const e of raw) {
    const v = validateElementPush(e, { slotIds: opts.slotIds, sponsorCampaignId: opts.sponsorCampaignId });
    if ("error" in v) return v;
    if (seen.has(v.push.id)) return { error: "An element is listed twice" };
    seen.add(v.push.id);
    elements.push(v.push);
  }
  return { plan: { graphics: g.state, layout: l.layout, elements, applied: { id: a.id, updatedAt } } };
}

export type ElementWrite = { row: ElementRow; prev?: ElementRow };

/**
 * The element rows after an Apply. An element already in the show keeps its
 * stored settings and live values (votes, clocks, round) — only where it is on
 * air and whether it is an angle come from the layout. A new one starts from
 * the push (its library item).
 */
export function planElements(
  pushes: ElementPush[],
  rows: ElementRow[],
  eventId: string,
  now: number,
): { next: ElementRow[]; writes: ElementWrite[] } | { error: string; current?: unknown } {
  const byId = new Map(rows.map((r) => [r.element_id, r]));
  const writes: ElementWrite[] = [];
  for (const push of pushes) {
    const prev = byId.get(push.id);
    if (prev && prev.kind !== push.kind) return { error: "An element can't change kind" };
    if (prev && push.version <= prev.version) return { error: "stale", current: rowToLive(prev) };
    let p = push;
    if (prev) {
      const { clocks: _clocks, ...state } = prev.state ?? {};
      const spec = { ...prev.spec, targets: push.spec.targets };
      if (push.spec.angle) spec.angle = true;
      else delete spec.angle;
      p = { ...push, spec, state, clockOps: {}, ops: {} };
    }
    const row = buildRow(eventId, p, prev, now);
    writes.push({ row, prev });
    byId.set(row.element_id, row);
  }
  const next = [...byId.values()];
  if (next.length > MAX_LIVE_ELEMENTS) return { error: `A show can run ${MAX_LIVE_ELEMENTS} elements at most` };
  if (JSON.stringify(liveSnapshot(next)).length > MAX_ELEMENTS_JSON) {
    return { error: "Too many elements on screen at once" };
  }
  return { next, writes };
}

/** Element angle ids (`el:<id>`) among [rows]. */
export const angleIdsOf = (rows: ElementRow[]) =>
  new Set(rows.filter((r) => r.spec?.angle === true).map((r) => angleIdOf(r.element_id)));

export interface AppliedShow {
  offAir: string[];
  defaultSlot: string | null;
  slotOrder: string[];
}

/**
 * Show control from a layout: off-air angles, the default angle and camera
 * order. Ids that aren't cameras or element angles of this show (a camera
 * removed meanwhile) are dropped rather than failing the whole Apply.
 * `sendAll` is never set here — a layout doesn't move viewers.
 */
export function cleanAppliedShow(raw: unknown, ids: Set<string>): AppliedShow {
  const r = isObj(raw) ? raw : {};
  const list = (v: unknown) =>
    Array.isArray(v) ? [...new Set(v.filter((s): s is string => typeof s === "string" && ids.has(s)))] : [];
  return {
    offAir: list(r.offAir).sort(),
    defaultSlot: typeof r.defaultSlot === "string" && ids.has(r.defaultSlot) ? r.defaultSlot : null,
    slotOrder: list(r.slotOrder),
  };
}
