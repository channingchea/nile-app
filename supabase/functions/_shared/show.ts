// Show control (studio-edits plan, phase 5) — what `set-show` and
// `reorder-cameras` accept. Pure, so it can be unit tested. Mirrors ShowControl
// in lib/services/show_control.dart.
//
// Room metadata keys written here:
//   offAir       [slotId]          viewers don't see these angles
//   defaultSlot  slotId | null     where new viewers start
//   sendAll      { slot, nonce }   "Send everyone here" — each nonce acted on once
//   slotOrder    [slotId]          camera order, everywhere

import type { Slot } from "./studio.ts";

export type ShowPatch = {
  offAir?: string[];
  defaultSlot?: string | null;
  sendAll?: { slot: string; nonce: number };
};

/** Validate a set-show body against the event's slots. Partial: absent keys are left alone. */
export function cleanShowPatch(
  body: Record<string, unknown>,
  slotIds: Set<string>,
  current: Record<string, unknown>,
  now: number,
): { patch: ShowPatch } | { error: string } {
  const patch: ShowPatch = {};
  if (body.offAir !== undefined) {
    if (!Array.isArray(body.offAir)) return { error: "offAir must be a list of camera slots" };
    const ids = body.offAir.filter((s): s is string => typeof s === "string");
    if (ids.some((s) => !slotIds.has(s))) return { error: "That camera slot doesn't exist" };
    patch.offAir = [...new Set(ids)].sort();
  }
  if (body.defaultSlot !== undefined) {
    if (body.defaultSlot !== null && !(typeof body.defaultSlot === "string" && slotIds.has(body.defaultSlot))) {
      return { error: "That camera slot doesn't exist" };
    }
    patch.defaultSlot = body.defaultSlot as string | null;
  }
  if (body.sendAll !== undefined) {
    const slot = body.sendAll;
    if (typeof slot !== "string" || !slotIds.has(slot)) return { error: "That camera slot doesn't exist" };
    const offAir = patch.offAir ?? (Array.isArray(current.offAir) ? current.offAir : []);
    if (offAir.includes(slot)) return { error: "That camera is off air" };
    patch.sendAll = { slot, nonce: now };
  }
  if (Object.keys(patch).length === 0) return { error: "Nothing to change" };
  return { patch };
}

const DEFAULT_LABEL = /^Camera \d+$/;

/**
 * A new camera order. [order] must name every slot exactly once, and may also
 * place element angles ([virtualIds], `el:<id>`) among them. Returns each real
 * slot's new 1-based index and label — default "Camera N" names follow their
 * position among the cameras; a name the host chose is kept — plus the full
 * order (cameras and element angles) for room metadata.
 */
export function planReorder(
  order: unknown,
  slots: Slot[],
  virtualIds: Set<string> = new Set(),
): { rows: { id: string; slot_index: number; label: string }[]; order: string[] } | { error: string } {
  const bad = { error: "order must list every camera once" };
  if (!Array.isArray(order) || new Set(order).size !== order.length) return bad;
  const byId = new Map(slots.map((s) => [s.id, s]));
  if (order.some((id) => !byId.has(id as string) && !virtualIds.has(id as string))) return bad;
  const real = (order as string[]).filter((id) => byId.has(id));
  if (real.length !== slots.length) return bad;
  return {
    rows: real.map((id, i) => {
      const s = byId.get(id)!;
      return {
        id,
        slot_index: i + 1,
        label: DEFAULT_LABEL.test(s.label) ? `Camera ${i + 1}` : s.label,
      };
    }),
    order: order as string[],
  };
}
