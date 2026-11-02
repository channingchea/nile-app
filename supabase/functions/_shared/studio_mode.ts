// Studio modes (docs/plans/studio-modes.md, phase 1) — the rules behind the
// livekit `set-mode` action. Pure, so it can be unit tested. Mirrors StudioMode
// in lib/services/studio_mode.dart.
//
// Room metadata key written by set-mode:
//   mode   "multicam" | "interview" | "premiere"

export const STUDIO_MODES = ["multicam", "interview", "premiere"] as const;
export type StudioMode = typeof STUDIO_MODES[number];

/** Validate a set-mode request. The mode is locked once the show is live. */
export function checkModeChange(
  mode: unknown,
  status: string,
  meta: Record<string, unknown>,
): { mode: StudioMode } | { error: string; status: number } {
  if (!STUDIO_MODES.includes(mode as StudioMode)) {
    return { error: "Unknown studio mode", status: 400 };
  }
  // status 'live' covers the normal path; the anchor covers a show whose row
  // hasn't caught up yet.
  if (status === "live" || typeof meta.showStartedAt === "number") {
    return { error: "The mode can't change while you're live", status: 409 };
  }
  if (status === "ended") return { error: "This show has ended", status: 409 };
  return { mode: mode as StudioMode };
}
