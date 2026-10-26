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
  /** What viewers may tap, for this config; empty = nothing to tap. */
  choices?(config: Record<string, unknown>): string[];
  /** How many choices one vote may hold (default 1). */
  maxPicks?(config: Record<string, unknown>): number;
  /** Takes timer/reset ops ([ElementOps]). */
  ops?: true;
  /** State only the server writes, from the previous row and this push. */
  serverState?(prev: Record<string, unknown> | undefined, push: ElementPush, now: number): Record<string, unknown>;
  /** Whether viewers may see the totals right now (default yes). */
  totalsPublic?(config: Record<string, unknown>, state: Record<string, unknown>): boolean;
  /** Whether going from [prev] to [next] changes what votes point at. */
  reshapes?(prev: Record<string, unknown>, next: Record<string, unknown>): boolean;
}

export const ELEMENT_KINDS: Record<string, KindRule> = {
  // Hidden test-only kind: a labelled number with a stopwatch. Exercises the
  // whole path (library → push → state → clock → viewer) before real kinds.
  counter: {
    config: (r) => {
      const label = r.label === undefined ? "Count" : str(r.label, 40);
      if (label === undefined) return null;
      const step = r.step === undefined ? 1 : r.step;
      if (!isInt(step, 1, 100)) return null;
      return r.taps === true ? { label, step, taps: true } : { label, step };
    },
    state: (r) => ({
      value: isInt(r.value, -99999, 99999) ? r.value : 0,
      ...(r.open === true ? { open: true } : {}),
    }),
    clocks: ["main"],
    // With taps on, viewers vote up or down (the test stand-in for a poll).
    choices: (c) => (c.taps === true ? ["up", "down"] : []),
  },
  // docs/plans/studio-poll.md.
  poll: {
    config: cleanPollConfig,
    state: (r) => ({
      ...(r.open === true ? { open: true } : {}),
      ...(r.revealed === true ? { revealed: true } : {}),
    }),
    clocks: [],
    choices: (c) => pollAnswers(c).map((a) => a.id),
    maxPicks: (c) => (c.type === "several" ? (c.maxPicks as number | undefined) ?? pollAnswers(c).length : 1),
    ops: true,
    serverState: pollServerState,
    totalsPublic: (c, s) => c.results !== "reveal" || s.revealed === true,
    reshapes: (a, b) =>
      a.type !== b.type || JSON.stringify(pollAnswers(a).map((x) => x.id)) !== JSON.stringify(pollAnswers(b).map((x) => x.id)),
  },
};

// ── Poll ─────────────────────────────────────────────────────────────────────

export const POLL_TYPES = ["choice", "yesno", "rating", "several"] as const;
export const POLL_RESULTS = ["live", "voted", "reveal"] as const;
const ANSWER_ID = /^[a-z0-9]{1,12}$/;
const FIXED_ANSWERS: Record<string, { id: string; text: string }[]> = {
  yesno: [{ id: "yes", text: "Yes" }, { id: "no", text: "No" }],
  rating: ["1", "2", "3", "4", "5"].map((n) => ({ id: n, text: n })),
};

export type PollAnswer = { id: string; text: string };
export const pollAnswers = (c: Record<string, unknown>): PollAnswer[] =>
  FIXED_ANSWERS[c.type as string] ?? (Array.isArray(c.answers) ? c.answers as PollAnswer[] : []);

/** A poll's settings, cleaned; null when they can't be saved. Yes/no and rating fill in their own answers. */
export function cleanPollConfig(r: Record<string, unknown>): Record<string, unknown> | null {
  const type = r.type ?? "choice";
  if (!POLL_TYPES.includes(type as typeof POLL_TYPES[number])) return null;
  const question = typeof r.question === "string" ? r.question.trim() : "";
  if (question.length < 1 || question.length > 120) return null;
  const results = r.results ?? "live";
  if (!POLL_RESULTS.includes(results as typeof POLL_RESULTS[number])) return null;
  const out: Record<string, unknown> = { type, question, results };
  if (r.timerSec !== undefined && r.timerSec !== null) {
    if (!isInt(r.timerSec, 10, 1800)) return null;
    out.timerSec = r.timerSec;
  }
  if (type === "choice" || type === "several") {
    if (!Array.isArray(r.answers) || r.answers.length < 2 || r.answers.length > 6) return null;
    const ids = new Set<string>(), texts = new Set<string>();
    const answers: PollAnswer[] = [];
    for (const a of r.answers) {
      if (!isObj(a) || typeof a.id !== "string" || !ANSWER_ID.test(a.id) || typeof a.text !== "string") return null;
      const text = a.text.trim();
      if (text.length < 1 || text.length > 40 || ids.has(a.id) || texts.has(text.toLowerCase())) return null;
      ids.add(a.id);
      texts.add(text.toLowerCase());
      answers.push({ id: a.id, text });
    }
    out.answers = answers;
  }
  if (type === "several" && r.maxPicks !== undefined && r.maxPicks !== null) {
    if (!isInt(r.maxPicks, 1, (out.answers as PollAnswer[]).length)) return null;
    out.maxPicks = r.maxPicks;
  }
  return out;
}

/** Timer and reset, run by the server with its own clock. */
export type ElementOps = { timer?: { op: "start"; sec: number } | { op: "cancel" }; reset?: true };

function cleanOps(raw: unknown, config: Record<string, unknown>): ElementOps | null {
  if (raw === undefined || raw === null) return {};
  if (!isObj(raw)) return null;
  const ops: ElementOps = {};
  if (raw.reset === true) ops.reset = true;
  if (raw.timer !== undefined) {
    const t = raw.timer;
    if (isObj(t) && t.op === "cancel") ops.timer = { op: "cancel" };
    else if (isObj(t) && t.op === "start") {
      const sec = t.sec ?? config.timerSec;
      if (!isInt(sec, 10, 1800)) return null;
      ops.timer = { op: "start", sec };
    } else return null;
  }
  return ops;
}

/**
 * `closesAt` (server ms) and `round` (up one per reset) carry over from the
 * stored row; the Studio can't write either. A reset clears the timer.
 */
function pollServerState(prev: Record<string, unknown> | undefined, push: ElementPush, now: number) {
  const round = (isInt(prev?.round, 0, 1e6) ? prev!.round as number : 0) + (push.ops.reset ? 1 : 0);
  let closesAt = typeof prev?.closesAt === "number" ? prev.closesAt : undefined;
  if (push.ops.reset || push.ops.timer?.op === "cancel") closesAt = undefined;
  if (push.ops.timer?.op === "start") closesAt = now + push.ops.timer.sec * 1000;
  return { round, ...(closesAt !== undefined ? { closesAt } : {}) };
}

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
  /** Also its own angle in every viewer's picker (phase 4). */
  angle?: true;
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
  ops: ElementOps;
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
  if (raw.angle === true) spec.angle = true;
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
  const ops = rule.ops ? cleanOps(raw.ops, config) : raw.ops == null ? {} : null;
  if (!ops) return { error: "Bad timer or reset command" };
  const srcAgeMs = isInt(raw.srcAgeMs, 0, 5000) ? raw.srcAgeMs : 0;
  const { clocks: _ignored, ...rest } = isObj(raw.state) ? raw.state : {};
  return { push: { id, kind, spec, state: rule.state(rest), version: raw.version, clockOps, ops, srcAgeMs } };
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
  const server = rule.serverState?.(prev?.state, push, now) ?? {};
  const state = { ...push.state, ...server };
  return {
    event_id: eventId,
    element_id: push.id,
    kind: push.kind,
    spec: push.spec,
    state: Object.keys(clocks).length ? { ...state, clocks } : state,
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

/** Room metadata `elements`: every element on air somewhere — over a camera or as its own angle. */
export function liveSnapshot(rows: ElementRow[]) {
  const items = rows
    .filter((r) => r.spec?.angle === true || (r.spec?.targets && onAir(r.spec.targets)))
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

// ── Element angles (phase 4) ─────────────────────────────────────────────────
// An element shown as its own angle is a virtual camera with id `el:<id>`.
// Show control (off air, default, send everyone, order) takes these ids next
// to real slot ids.

export const ANGLE_PREFIX = "el:";
export const angleIdOf = (elementId: string) => `${ANGLE_PREFIX}${elementId}`;

/** The element angles in a room's metadata right now. */
export function elementAngleIds(meta: Record<string, unknown>): Set<string> {
  const items = isObj(meta.elements) && Array.isArray(meta.elements.items) ? meta.elements.items : [];
  return new Set(
    items
      .filter((e): e is Record<string, unknown> => isObj(e) && e.angle === true && typeof e.id === "string")
      .map((e) => angleIdOf(e.id as string)),
  );
}

// ── Viewer taps (phase 5) ────────────────────────────────────────────────────

/** Everything a viewer could tap on [row], open or not. */
export const choicesOf = (row: Pick<ElementRow, "kind" | "spec">) =>
  ELEMENT_KINDS[row.kind]?.choices?.(row.spec?.config ?? {}) ?? [];

/** Whether voting has ended on its own: a timer ran out. */
export const timedOut = (state: Record<string, unknown> | undefined, now: number) =>
  typeof state?.closesAt === "number" && now >= state.closesAt;

/** What a viewer may tap on [row] right now: its choices while it is open (and its timer hasn't run out), else none. */
export function openChoices(row: Pick<ElementRow, "kind" | "spec" | "state"> | undefined, now = Date.now()): string[] {
  if (!row || row.state?.open !== true || timedOut(row.state, now)) return [];
  const isLive = row.spec?.angle === true || (row.spec?.targets && onAir(row.spec.targets));
  return isLive ? choicesOf(row) : [];
}

/** Whether viewers may see [row]'s totals now (a reveal-mode poll before its reveal: no). */
export const totalsPublic = (row: Pick<ElementRow, "kind" | "spec" | "state">) =>
  ELEMENT_KINDS[row.kind]?.totalsPublic?.(row.spec?.config ?? {}, row.state ?? {}) ?? true;

/** Whether [prev] → [next] changes what votes point at (refused while open or holding votes). */
export const reshapes = (kind: string, prev: Record<string, unknown>, next: Record<string, unknown>) =>
  ELEMENT_KINDS[kind]?.reshapes?.(prev, next) ?? false;

/**
 * Whether a viewer's tap counts: the element is open and live, and its picks
 * are its own — `picks` (a list) or, from older builds, one `choice`. No
 * duplicates; at most the kind's limit.
 */
export function validateResponse(
  row: Pick<ElementRow, "kind" | "spec" | "state"> | undefined,
  body: { picks?: unknown; choice?: unknown },
  now = Date.now(),
): { picks: string[] } | { error: string; status: number } {
  if (!row) return { error: "That isn't on screen", status: 404 };
  const choices = openChoices(row, now);
  if (!choices.length) return { error: "Voting has closed", status: 409 };
  const picks = Array.isArray(body.picks) ? body.picks : typeof body.choice === "string" ? [body.choice] : null;
  if (!picks || !picks.length || !picks.every((p) => typeof p === "string" && choices.includes(p))) {
    return { error: "Not a choice", status: 400 };
  }
  if (new Set(picks).size !== picks.length) return { error: "Pick each answer once", status: 400 };
  const max = ELEMENT_KINDS[row.kind]?.maxPicks?.(row.spec?.config ?? {}) ?? 1;
  if (picks.length > max) return { error: max === 1 ? "Pick one answer" : `Pick up to ${max}`, status: 400 };
  return { picks: picks as string[] };
}

/** Choice → count, every choice present (zeros included), in the kind's order. */
export function shapeTally(choices: string[], counts: Record<string, unknown>): Record<string, number> {
  const out: Record<string, number> = {};
  for (const c of choices) out[c] = isInt(counts[c], 0, 1e9) ? counts[c] as number : 0;
  return out;
}
