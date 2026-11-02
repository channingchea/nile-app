// Interview mode (phases 2-5): stage moves, the 6-person limit, set-stage
// validation, titles, invite codes. The handlers reuse requireHost (non-hosts
// get 403) and the Studio gate.
//
//   deno test --allow-env supabase/functions/tests/

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  cleanStagePatch,
  cleanTitle,
  emptyStage,
  guestIdentity,
  guestUserIdOf,
  isInviteCode,
  newInviteCode,
  planMove,
  STAGE_MAX,
  stageOf,
  stageSecondsSince,
} from "../_shared/interview.ts";

const U = "0b6c1c7e-1111-4222-8333-944455556666";

Deno.test("guest identities round-trip; others aren't guests", () => {
  assertEquals(guestUserIdOf(guestIdentity(U)), U);
  assertEquals(guestUserIdOf("studio-abc"), null);
  assertEquals(guestUserIdOf("guest-not-a-uuid"), null);
});

Deno.test("stageOf normalises bad metadata", () => {
  assertEquals(stageOf({}), emptyStage());
  const s = stageOf({
    stage: { ids: [{ id: "a", at: 1 }, { id: "a", at: 2 }, { id: 3 }, { id: "b", at: 5 }], layout: "nope", focus: "zz" },
  });
  assertEquals(s, { ids: [{ id: "a", at: 1 }, { id: "b", at: 5 }], layout: "grid", focus: null, content: null });
});

Deno.test("on stage: appears a countdown ahead, keeps place if already on", () => {
  const r = planMove(emptyStage(), "g1", "on_stage", 1000, 5000);
  assert("stage" in r);
  assertEquals(r.stage.ids, [{ id: "g1", at: 6000 }]);
  const again = planMove(r.stage, "g1", "on_stage", 9000, 5000);
  assert("stage" in again);
  assertEquals(again.stage.ids, [{ id: "g1", at: 6000 }]);
  // The countdown is clamped to 0-10 s.
  const long = planMove(emptyStage(), "g2", "on_stage", 0, 60_000);
  assert("stage" in long);
  assertEquals(long.stage.ids[0].at, 10_000);
});

Deno.test("stage holds at most 6, host included", () => {
  let stage = emptyStage();
  for (let i = 0; i < STAGE_MAX; i++) {
    const r = planMove(stage, `p${i}`, "on_stage", 0, 0);
    assert("stage" in r);
    stage = r.stage;
  }
  assertEquals(planMove(stage, "p6", "on_stage", 0, 0), { error: "stage_full", status: 409 });
});

Deno.test("sending back clears focus; moving someone not on stage is a no-op", () => {
  const stage = { ...emptyStage([{ id: "a", at: 0 }, { id: "b", at: 0 }]), focus: "a", layout: "spotlight" as const };
  const r = planMove(stage, "a", "green_room", 0, 0);
  assert("stage" in r);
  assertEquals(r.stage.ids, [{ id: "b", at: 0 }]);
  assertEquals(r.stage.focus, null);
  const same = planMove(stage, "zz", "removed", 0, 0);
  assert("stage" in same);
  assertEquals(same.stage, stage);
});

Deno.test("set-stage validates layout, focus, content and order", () => {
  const stage = emptyStage([{ id: "a", at: 0 }, { id: "b", at: 0 }]);
  const ok = cleanStagePatch({ layout: "spotlight", focus: "b", content: "el:x" }, stage, new Set(["el:x"]));
  assert("stage" in ok);
  assertEquals([ok.stage.layout, ok.stage.focus, ok.stage.content], ["spotlight", "b", "el:x"]);
  assertEquals(cleanStagePatch({ layout: "pip" }, stage, new Set()), { error: "Unknown stage layout" });
  assertEquals(cleanStagePatch({ focus: "c" }, stage, new Set()), { error: "They aren't on stage" });
  assertEquals(cleanStagePatch({ content: "el:y" }, stage, new Set(["el:x"])), { error: "That angle isn't available" });
  assertEquals(cleanStagePatch({}, stage, new Set()), { error: "Nothing to change" });
  const order = cleanStagePatch({ order: ["b", "a"] }, stage, new Set());
  assert("stage" in order);
  assertEquals(order.stage.ids.map((e) => e.id), ["b", "a"]);
  assert("error" in cleanStagePatch({ order: ["a"] }, stage, new Set()));
  assert("error" in cleanStagePatch({ order: ["a", "a"] }, stage, new Set()));
});

Deno.test("titles: trimmed, ≤60, blank clears", () => {
  assertEquals(cleanTitle("  Director  "), "Director");
  assertEquals(cleanTitle(""), null);
  assertEquals(cleanTitle(null), null);
  assertEquals(cleanTitle(undefined), undefined);
  assertEquals(cleanTitle("x".repeat(61)), undefined);
  assertEquals(cleanTitle(7), undefined);
});

Deno.test("invite codes are 10 unambiguous characters", () => {
  for (let i = 0; i < 50; i++) assert(isInviteCode(newInviteCode()));
  assert(!isInviteCode("ABCDEFGHJK"));
  assert(!isInviteCode("abc"));
  assert(!isInviteCode("abcdefghi1")); // digits 0 and 1 are never used
});

Deno.test("stage seconds accumulate from stage_since", () => {
  assertEquals(stageSecondsSince(null, 0), 0);
  assertEquals(stageSecondsSince("2026-11-01T20:00:00Z", Date.parse("2026-11-01T20:01:30Z")), 90);
});
