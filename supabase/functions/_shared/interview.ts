// Interview mode (docs/plans/studio-modes.md, phases 2-5) — the rules behind
// the livekit guest and stage actions. Pure, so it can be unit tested. Mirrors
// lib/services/interview.dart.
//
// Room metadata key written by move-guest / set-stage / set-mode:
//   stage  { ids: [{ id, at }], layout, focus, content }
//     ids      who is on stage, in layout order; `at` is the server time (ms)
//              they appear — move-guest sets it a countdown ahead
//     layout   "solo" | "side" | "grid" | "spotlight"
//     focus    identity the solo/spotlight layouts feature, or null
//     content  the optional extra viewer angle: a screen share
//              ("<identity>#share") or an element angle ("el:<id>"), or null
//
// Identities:
//   guest-<userId>       a remote guest (role "guest")
//   backstage-<eventId>  the Studio's private talkback line (role "backstage")

export const STAGE_MAX = 6;
export const STAGE_LAYOUTS = ["solo", "side", "grid", "spotlight"] as const;
export type StageLayout = typeof STAGE_LAYOUTS[number];
export const GUEST_STATUSES = ["invited", "green_room", "on_stage", "removed"] as const;
export type GuestStatus = typeof GUEST_STATUSES[number];
export type Move = "on_stage" | "green_room" | "removed";

export type StageEntry = { id: string; at: number };
export type Stage = { ids: StageEntry[]; layout: StageLayout; focus: string | null; content: string | null };

export const guestIdentity = (userId: string) => `guest-${userId}`;
export const backstageIdentity = (eventId: string) => `backstage-${eventId}`;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const guestUserIdOf = (identity: string): string | null => {
  const m = /^guest-(.+)$/.exec(identity);
  return m && UUID.test(m[1]) ? m[1] : null;
};

export const emptyStage = (ids: StageEntry[] = []): Stage => ({ ids, layout: "grid", focus: null, content: null });

/** The stage as stored in room metadata, normalised. */
export function stageOf(meta: Record<string, unknown>): Stage {
  const raw = meta.stage as Record<string, unknown> | undefined;
  if (!raw || typeof raw !== "object") return emptyStage();
  const ids: StageEntry[] = [];
  if (Array.isArray(raw.ids)) {
    for (const e of raw.ids) {
      const id = (e as StageEntry)?.id, at = (e as StageEntry)?.at;
      if (typeof id === "string" && typeof at === "number" && !ids.some((x) => x.id === id)) ids.push({ id, at });
    }
  }
  const layout = STAGE_LAYOUTS.includes(raw.layout as StageLayout) ? raw.layout as StageLayout : "grid";
  const focus = typeof raw.focus === "string" && ids.some((e) => e.id === raw.focus) ? raw.focus : null;
  const content = typeof raw.content === "string" ? raw.content : null;
  return { ids: ids.slice(0, STAGE_MAX), layout, focus, content };
}

/**
 * Move someone on or off the stage. [countdownMs] is how far ahead they
 * appear (the guest's "you're on in 5"). Someone already on stage keeps
 * their place and time.
 */
export function planMove(
  stage: Stage,
  identity: string,
  to: Move,
  now: number,
  countdownMs: number,
): { stage: Stage } | { error: string; status: number } {
  const on = stage.ids.some((e) => e.id === identity);
  if (to === "on_stage") {
    if (on) return { stage };
    if (stage.ids.length >= STAGE_MAX) return { error: "stage_full", status: 409 };
    const at = now + Math.max(0, Math.min(10_000, Math.round(countdownMs)));
    return { stage: { ...stage, ids: [...stage.ids, { id: identity, at }] } };
  }
  if (!on) return { stage };
  return {
    stage: {
      ...stage,
      ids: stage.ids.filter((e) => e.id !== identity),
      focus: stage.focus === identity ? null : stage.focus,
    },
  };
}

/** Validate a set-stage body. [contentIds] are the angles that may be the content angle. */
export function cleanStagePatch(
  body: Record<string, unknown>,
  stage: Stage,
  contentIds: Set<string>,
): { stage: Stage } | { error: string } {
  const next = { ...stage };
  let changed = false;
  if (body.layout !== undefined) {
    if (!STAGE_LAYOUTS.includes(body.layout as StageLayout)) return { error: "Unknown stage layout" };
    next.layout = body.layout as StageLayout;
    changed = true;
  }
  if (body.focus !== undefined) {
    if (body.focus !== null && !stage.ids.some((e) => e.id === body.focus)) return { error: "They aren't on stage" };
    next.focus = body.focus as string | null;
    changed = true;
  }
  if (body.content !== undefined) {
    if (body.content !== null && !(typeof body.content === "string" && contentIds.has(body.content))) {
      return { error: "That angle isn't available" };
    }
    next.content = body.content as string | null;
    changed = true;
  }
  if (body.order !== undefined) {
    const order = body.order;
    if (!Array.isArray(order) || order.length !== stage.ids.length || new Set(order).size !== order.length) {
      return { error: "order must name everyone on stage once" };
    }
    const byId = new Map(stage.ids.map((e) => [e.id, e]));
    if (!order.every((id) => typeof id === "string" && byId.has(id))) return { error: "order must name everyone on stage once" };
    next.ids = order.map((id) => byId.get(id as string)!);
    changed = true;
  }
  return changed ? { stage: next } : { error: "Nothing to change" };
}

/** Guest titles ("Director", "Author of …"): trimmed, at most 60 characters, empty → null. */
export function cleanTitle(raw: unknown): string | null | undefined {
  if (raw === undefined) return undefined;
  if (raw === null) return null;
  if (typeof raw !== "string") return undefined;
  const t = raw.trim().replace(/\s+/g, " ");
  if (!t) return null;
  return t.length <= 60 ? t : undefined;
}

/** A share-link code: 10 characters from an unambiguous alphabet. */
export function newInviteCode(random: (n: number) => Uint8Array = (n) => crypto.getRandomValues(new Uint8Array(n))): string {
  const alphabet = "abcdefghjkmnpqrstuvwxyz23456789";
  return Array.from(random(10), (b) => alphabet[b % alphabet.length]).join("");
}
export const isInviteCode = (c: unknown): c is string => typeof c === "string" && /^[a-z2-9]{10}$/.test(c);

/** Seconds on stage to add when someone leaves it. */
export function stageSecondsSince(since: string | null, now: number): number {
  if (!since) return 0;
  const t = Date.parse(since);
  return Number.isNaN(t) ? 0 : Math.max(0, Math.round((now - t) / 1000));
}
