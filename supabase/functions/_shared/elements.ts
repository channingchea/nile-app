// Studio live elements (docs/plans/studio-live-elements-foundation.md) — the
// pure rules behind the `set-element`, `list-elements` and `set-layout`
// actions. Mirrors lib/services/live_elements.dart and overlay_layout.dart.
//
// An element is one customizable on-screen asset (a scoreboard, a poll, …).
// Each push from the Studio carries the whole element plus the next version
// number; its state is stored in live_element_state and the on-air ones are
// mirrored into room metadata under `elements` for viewers to draw.

import { type BrandStyle, cleanBrand } from "./graphics.ts";

/** Room metadata is broadcast to every viewer; keep the elements part small. */
export const MAX_ELEMENTS_JSON = 16000;
/** Elements one event can hold state for (on air or not). */
export const MAX_LIVE_ELEMENTS = 30;
/** The layout part of room metadata. */
export const MAX_LAYOUT_JSON = 8000;

const ID = /^[A-Za-z0-9:_-]{1,80}$/;
const KIND = /^[a-z][a-z_]{0,29}$/;
const DAY_MS = 86_400_000;

const isObj = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);
const str = (v: unknown, max: number) => (typeof v === "string" && v.length <= max ? v : undefined);
const isInt = (v: unknown, min: number, max: number): v is number =>
  typeof v === "number" && Number.isInteger(v) && v >= min && v <= max;

// ── Clocks ───────────────────────────────────────────────────────────────────
// Server ms throughout. Each phone shows elapsedMs + (serverNow − runningSince)
// against its own estimate of the server clock (the `clock` action).

export interface Clock {
  elapsedMs: number;
  runningSince?: number;
  pausedAt?: number;
}
export type ClockOp = { op: "start" | "pause" | "reset" | "set"; ms?: number };

export const clockValue = (c: Clock, now: number) =>
  c.elapsedMs + (typeof c.runningSince === "number" ? Math.max(0, now - c.runningSince) : 0);

/** Apply one Studio command to a clock, stamped with the server's own time. */
export function applyClockOp(prev: Clock | undefined, op: ClockOp, now: number): Clock {
  const c = prev ?? { elapsedMs: 0 };
  const running = typeof c.runningSince === "number";
  switch (op.op) {
    case "start":
      return running ? c : { elapsedMs: c.elapsedMs, runningSince: now };
    case "pause":
      return running ? { elapsedMs: clockValue(c, now), pausedAt: now } : c;
    case "reset":
      return { elapsedMs: 0 };
    case "set": {
      const ms = Math.min(Math.max(Math.round(op.ms ?? 0), 0), DAY_MS);
      return running ? { elapsedMs: ms, runningSince: now } : { elapsedMs: ms, ...(c.pausedAt ? { pausedAt: c.pausedAt } : {}) };
    }
  }
}

function cleanClock(raw: unknown): Clock | null {
  if (!isObj(raw) || !isInt(raw.elapsedMs, 0, DAY_MS)) return null;
  const c: Clock = { elapsedMs: raw.elapsedMs };
  if (typeof raw.runningSince === "number" && Number.isFinite(raw.runningSince)) c.runningSince = Math.round(raw.runningSince);
  else if (typeof raw.pausedAt === "number" && Number.isFinite(raw.pausedAt)) c.pausedAt = Math.round(raw.pausedAt);
  return c;
}

function cleanClockOp(raw: unknown): ClockOp | null {
  if (!isObj(raw) || !["start", "pause", "reset", "set"].includes(raw.op as string)) return null;
  const op: ClockOp = { op: raw.op as ClockOp["op"] };
  if (op.op === "set") {
    if (!isInt(raw.ms, 0, DAY_MS)) return null;
    op.ms = raw.ms;
  }
  return op;
}

// ── Kinds ────────────────────────────────────────────────────────────────────
// Each kind cleans its own config and state and names the clocks it runs.
// Adding a kind = one entry here + its Flutter side (ElementKinds + the UI
// registry in lib/widgets/elements/element_kinds.dart).

interface KindRule {
  config(raw: Record<string, unknown>): Record<string, unknown> | null;
  state(raw: Record<string, unknown>): Record<string, unknown>;
  clocks: string[];
}

export const ELEMENT_KINDS: Record<string, KindRule> = {
  // Hidden test-only kind: a labelled number with a stopwatch. Exercises the
  // whole path (library → push → state → clock → viewer) before real kinds.
  counter: {
    config: (r) => {
      const label = r.label === undefined ? "Count" : str(r.label, 40);
      if (label === undefined) return null;
      const step = r.step === undefined ? 1 : r.step;
      return isInt(step, 1, 100) ? { label, step } : null;
    },
    state: (r) => ({ value: isInt(r.value, -99999, 99999) ? r.value : 0 }),
    clocks: ["main"],
  },
};

// ── Targets ──────────────────────────────────────────────────────────────────
// Where an element is on air — the same shape graphics use: every camera
// (minus `except`), or just `slots`. `{ slots: [] }` = off air.

export type Targets = { all: true; except?: string[] } | { slots: string[] };

export function cleanTargets(raw: unknown, slotIds: Set<string>): Targets | null {
  if (!isObj(raw)) return null;
  const ids = (v: unknown) =>
    Array.isArray(v) ? [...new Set(v.filter((s): s is string => typeof s === "string" && slotIds.has(s)))].sort() : [];
  if (raw.all === true) {
    const except = ids(raw.except);
    return except.length ? { all: true, except } : { all: true };
  }
  return Array.isArray(raw.slots) ? { slots: ids(raw.slots) } : null;
}

export const onAir = (t: Targets) => "all" in t || t.slots.length > 0;

// ── A push ───────────────────────────────────────────────────────────────────

export interface ElementSpec {
  name: string;
  config: Record<string, unknown>;
  style?: BrandStyle;
  nileStyle?: true;
  targets: Targets;
  /** Sponsor hook ("presented by"): this event's accepted campaign only. No UI yet. */
  presentedBy?: string;
}

export interface ElementPush {
  id: string;
  kind: string;
  spec: ElementSpec;
  state: Record<string, unknown>;
  version: number;
  clockOps: Record<string, ClockOp>;
  srcAgeMs: number;
}

/**
 * Validate one element from the Studio. [sponsorCampaignId] is the event's
 * accepted sponsor; a `presentedBy` naming anything else is refused.
 */
export function validateElementPush(
  raw: unknown,
  opts: { slotIds: Set<string>; sponsorCampaignId?: string | null },
): { push: ElementPush } | { error: string } {
  if (!isObj(raw)) return { error: "element must be an object" };
  const id = typeof raw.id === "string" && ID.test(raw.id) ? raw.id : undefined;
  if (!id) return { error: "element id is missing or malformed" };
  const kind = typeof raw.kind === "string" && KIND.test(raw.kind) ? raw.kind : undefined;
  const rule = kind ? ELEMENT_KINDS[kind] : undefined;
  if (!kind || !rule) return { error: "Unknown element kind" };
  const name = typeof raw.name === "string" ? raw.name.trim() : "";
  if (name.length < 1 || name.length > 60) return { error: "Name is 1–60 characters" };
  if (!isInt(raw.version, 1, 2_000_000_000)) return { error: "version must be a positive whole number" };
  const config = rule.config(isObj(raw.config) ? raw.config : {});
  if (!config) return { error: "That element's settings aren't valid" };
  const targets = cleanTargets(raw.targets ?? { slots: [] }, opts.slotIds);
  if (!targets) return { error: "targets are malformed" };

  const spec: ElementSpec = { name, config, targets };
  const style = cleanBrand(raw.style);
  if (style) spec.style = style;
  if (raw.nileStyle === true) spec.nileStyle = true;
  if (raw.presentedBy !== undefined && raw.presentedBy !== null) {
    if (typeof raw.presentedBy !== "string" || raw.presentedBy !== opts.sponsorCampaignId) {
      return { error: "Only this show's sponsor can present an element" };
    }
    spec.presentedBy = raw.presentedBy;
  }

  const clockOps: Record<string, ClockOp> = {};
  if (isObj(raw.clockOps)) {
    for (const [name, op] of Object.entries(raw.clockOps)) {
      const clean = cleanClockOp(op);
      if (!rule.clocks.includes(name) || !clean) return { error: `Bad clock command for ${name}` };
      clockOps[name] = clean;
    }
  }
  const srcAgeMs = isInt(raw.srcAgeMs, 0, 5000) ? raw.srcAgeMs : 0;
  const { clocks: _ignored, ...rest } = isObj(raw.state) ? raw.state : {};
  return { push: { id, kind, spec, state: rule.state(rest), version: raw.version, clockOps, srcAgeMs } };
}

// ── Rows and the room-metadata mirror ────────────────────────────────────────

export interface ElementRow {
  event_id: string;
  element_id: string;
  kind: string;
  spec: ElementSpec;
  state: Record<string, unknown>;
  version: number;
  content_at: number;
}

/** The server ms an update refers to: when it arrived, less how old the Studio's picture was. */
export const contentAt = (now: number, srcAgeMs: unknown) =>
  now - (isInt(srcAgeMs, 0, 5000) ? srcAgeMs : 0);

/**
 * The row a push becomes. Clocks the kind runs carry over from [prev] and the
 * Studio's commands are applied to them with the server's [now]; the Studio
 * never sets a clock's timestamps itself.
 */
export function buildRow(eventId: string, push: ElementPush, prev: ElementRow | undefined, now: number): ElementRow {
  const rule = ELEMENT_KINDS[push.kind];
  const before = isObj(prev?.state?.clocks) ? prev!.state.clocks as Record<string, unknown> : {};
  const clocks: Record<string, Clock> = {};
  for (const name of rule.clocks) {
    const old = cleanClock(before[name]) ?? undefined;
    const op = push.clockOps[name];
    const next = op ? applyClockOp(old, op, now) : old;
    if (next) clocks[name] = next;
  }
  return {
    event_id: eventId,
    element_id: push.id,
    kind: push.kind,
    spec: push.spec,
    state: Object.keys(clocks).length ? { ...push.state, clocks } : push.state,
    version: push.version,
    content_at: contentAt(now, push.srcAgeMs),
  };
}

/** One element as the Studio and viewers read it. */
export const rowToLive = (r: ElementRow) => ({
  id: r.element_id,
  kind: r.kind,
  ...r.spec,
  state: r.state,
  version: r.version,
  at: Number(r.content_at),
});

/** Room metadata `elements`: every element that is on air somewhere. */
export function liveSnapshot(rows: ElementRow[]) {
  const items = rows
    .filter((r) => r.spec?.targets && onAir(r.spec.targets))
    .sort((a, b) => a.element_id.localeCompare(b.element_id))
    .map(rowToLive);
  return { items, at: items.reduce((m, e) => Math.max(m, e.at), 0) };
}

// ── Layout ───────────────────────────────────────────────────────────────────
// Per camera: an ordered layer list (top = front) of graphic/element ids, each
// with a spot on a 3×3 grid (or full screen) and a hidden flag. `all` is the
// layout of every camera without its own.

export const SPOTS = new Set(["tl", "tc", "tr", "ml", "mc", "mr", "bl", "bc", "br", "full"]);

export interface LayerEntry {
  id: string;
  spot?: string;
  hidden?: true;
}

export interface LayoutState {
  all?: LayerEntry[];
  bySlot: Record<string, LayerEntry[]>;
}

function cleanLayers(raw: unknown): LayerEntry[] | null {
  if (!Array.isArray(raw)) return null;
  const seen = new Set<string>();
  const out: LayerEntry[] = [];
  for (const x of raw.slice(0, 40)) {
    if (!isObj(x) || typeof x.id !== "string" || !ID.test(x.id) || seen.has(x.id)) continue;
    seen.add(x.id);
    const e: LayerEntry = { id: x.id };
    if (typeof x.spot === "string" && SPOTS.has(x.spot)) e.spot = x.spot;
    if (x.hidden === true) e.hidden = true;
    out.push(e);
  }
  return out;
}

export function validateLayout(
  raw: unknown,
  slotIds: Set<string>,
): { layout: LayoutState } | { error: string } {
  if (!isObj(raw)) return { error: "layout must be an object" };
  const layout: LayoutState = { bySlot: {} };
  const all = cleanLayers(raw.all);
  if (all && all.length) layout.all = all;
  if (isObj(raw.bySlot)) {
    for (const [slot, list] of Object.entries(raw.bySlot)) {
      if (!slotIds.has(slot)) continue;
      const clean = cleanLayers(list);
      if (clean && clean.length) layout.bySlot[slot] = clean;
    }
  }
  if (JSON.stringify(layout).length > MAX_LAYOUT_JSON) return { error: "That layout is too large" };
  return { layout };
}
