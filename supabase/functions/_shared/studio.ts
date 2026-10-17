// Studio master host — the decisions the `livekit` function makes about who is
// in the room, kept free of LiveKit/Supabase clients so they can be unit tested.
//
// Roles a publisher can carry in token metadata:
//   camera        a phone/iPad/Mac pointing a lens (identity camera-<installId>)
//   master-audio  the Stream Audio device             (master-audio-<eventId>)
//   studio        the host's desktop control room      (studio-<eventId>)
// A studio is a publisher too: it may share its screen, turn on its own webcam
// (hasCamera) and carry the show's audio.

export const PUBLISHER_ROLES = new Set(["camera", "master-audio", "studio"]);

/** The slice of a LiveKit participant these rules read. */
export interface Peer {
  identity: string;
  meta: Record<string, unknown>;
}

export interface Slot {
  id: string;
  slot_index: number;
  label: string;
}

export const studioIdentity = (eventId: string) => `studio-${eventId}`;

export const isPublisher = (p: Peer) => PUBLISHER_ROLES.has(p.meta.role as string);

/** True if a Studio is in the room — the gate for start-show / stop-egress. */
export const studioConnected = (peers: Peer[]) =>
  peers.some((p) => p.meta.role === "studio");

/**
 * Feeds that count against the event's camera_count: every camera, plus the
 * Studio while its own webcam is on. [except] is the caller reconnecting, so a
 * rejoin never counts twice.
 */
export function liveCameraCount(peers: Peer[], except?: string): number {
  return peers.filter((p) =>
    p.identity !== except &&
    (p.meta.role === "camera" || (p.meta.role === "studio" && p.meta.hasCamera === true))
  ).length;
}

/** slotId → identity currently holding it, ignoring [except]. */
export function slotHolders(peers: Peer[], except?: string): Map<string, Peer> {
  const out = new Map<string, Peer>();
  for (const p of peers) {
    if (p.identity === except) continue;
    const id = p.meta.slotId;
    if (typeof id === "string" && isPublisher(p)) out.set(id, p);
  }
  return out;
}

export type SlotResult =
  | { slot: Slot | null }
  | { conflict: Slot; heldBy: Peer };

/**
 * Which camera slot a device lands on.
 *
 *  - An explicit pick (`slotId`, from "Which camera is this?") is honoured or
 *    refused — two phones must never both be "Camera 1".
 *  - Otherwise the caller's assignment wins (crew Setup), then a slot whose
 *    label matches the name an older build sent, and if that slot is taken or
 *    nothing matched, the first open slot. Only the explicit pick ever
 *    conflicts; the implicit routes fall through so a crew phone is never
 *    locked out because the host grabbed its slot.
 *  - The same device reconnecting is excluded from "taken", so it keeps its
 *    slot.
 */
export function resolveSlot(opts: {
  slots: Slot[];
  peers: Peer[];
  identity: string;
  slotId?: string | null;
  assignedSlotId?: string | null;
  cameraName?: string | null;
}): SlotResult | { missing: true } {
  const { slots, peers, identity } = opts;
  const held = slotHolders(peers, identity);

  if (opts.slotId) {
    const slot = slots.find((s) => s.id === opts.slotId);
    if (!slot) return { missing: true };
    const holder = held.get(slot.id);
    return holder ? { conflict: slot, heldBy: holder } : { slot };
  }

  const open = (s: Slot | undefined) => (s && !held.has(s.id) ? s : undefined);
  const assigned = open(slots.find((s) => s.id === opts.assignedSlotId));
  if (assigned) return { slot: assigned };
  const named = open(slots.find((s) => s.label === opts.cameraName));
  if (named) return { slot: named };
  return { slot: slots.find((s) => !held.has(s.id)) ?? null };
}

/**
 * Whether a publisher joining now should carry the master-audio flag. Exactly
 * one publisher ever carries it; when this returns true the caller must clear
 * the flag on everyone else ([flagsToClear]).
 *
 *  1. The host's explicit choice (room metadata `masterAudio`) always wins for
 *     that identity, so a dropped master reclaims audio when it reconnects.
 *  2. While the chosen publisher is in the room, nobody else takes it.
 *  3. With no live choice: Stream Audio takes it (it always has — a dedicated
 *     audio device beats a camera mic); the first camera into an empty room
 *     takes it; a Studio never takes it by default.
 */
export function joinTakesMasterAudio(opts: {
  identity: string;
  role: "camera" | "master-audio" | "studio";
  peers: Peer[];
  chosen?: unknown;
}): boolean {
  const others = opts.peers.filter((p) => p.identity !== opts.identity && isPublisher(p));
  const chosen = typeof opts.chosen === "string" ? opts.chosen : null;
  if (chosen === opts.identity) return true;
  if (chosen && others.some((p) => p.identity === chosen)) return false;
  switch (opts.role) {
    case "master-audio":
      return true;
    case "camera":
      return !others.some((p) => p.meta.isMasterAudio === true) &&
        !others.some((p) => p.meta.role === "camera");
    default:
      return false;
  }
}

/** Publishers (other than [keep]) whose flag must be cleared. */
export const flagsToClear = (peers: Peer[], keep: string) =>
  peers.filter((p) => p.identity !== keep && isPublisher(p) && p.meta.isMasterAudio === true);

/** Display names: trimmed, 1–40 characters. Null when unusable. */
export function cleanCameraName(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const name = raw.trim().replace(/\s+/g, " ");
  return name.length >= 1 && name.length <= 40 ? name : null;
}
