// Studio modes (phase 1): set-mode accepts the three modes and refuses once
// the show is live or over. The handler itself reuses requireHost (non-hosts
// get 403).
//
//   deno test --allow-env supabase/functions/tests/

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { checkModeChange, STUDIO_MODES } from "../_shared/studio_mode.ts";

Deno.test("set-mode accepts each mode before going live", () => {
  for (const mode of STUDIO_MODES) {
    assertEquals(checkModeChange(mode, "soundcheck", {}), { mode });
    assertEquals(checkModeChange(mode, "scheduled", {}), { mode });
  }
});

Deno.test("set-mode rejects unknown modes", () => {
  for (const mode of ["", "Multicam", "talkshow", null, 3]) {
    assertEquals(checkModeChange(mode, "soundcheck", {}), { error: "Unknown studio mode", status: 400 });
  }
});

Deno.test("set-mode is locked while live", () => {
  const locked = { error: "The mode can't change while you're live", status: 409 };
  assertEquals(checkModeChange("interview", "live", {}), locked);
  // Room already has a show anchor even if the row still says soundcheck.
  assertEquals(checkModeChange("interview", "soundcheck", { showStartedAt: 1 }), locked);
});

Deno.test("set-mode refuses an ended show", () => {
  assertEquals(checkModeChange("premiere", "ended", {}), { error: "This show has ended", status: 409 });
});
