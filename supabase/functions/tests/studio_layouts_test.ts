// Studio Layouts (phase 3): the pure rules behind apply-layout. The handler
// itself reuses requireHost (non-hosts get 403) and writes all of this in one
// room metadata update.
//
//   deno test --allow-env supabase/functions/tests/

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { buildRow, type ElementRow, liveSnapshot, validateElementPush } from "../_shared/elements.ts";
import { angleIdsOf, cleanAppliedShow, planElements, validateApply } from "../_shared/layouts.ts";

const STORAGE = "https://x.supabase.co/storage/v1/object/public/";
const slotIds = new Set(["s1", "s2", "s3"]);
const opts = { imagePrefix: `${STORAGE}studio-graphics/`, avatarPrefix: STORAGE, slotIds };
const LAYOUT_ID = "0b6c1c7e-1111-4222-8333-944455556666";

const counter = (over: Record<string, unknown> = {}) => ({
  id: "ctr",
  kind: "counter",
  name: "Count",
  config: { label: "Goals", step: 1 },
  state: { value: 0 },
  targets: { slots: ["s1"] },
  version: 1,
  ...over,
});

const body = (over: Record<string, unknown> = {}) => ({
  applied: { id: LAYOUT_ID, updatedAt: "2026-11-01T22:00:00Z" },
  graphics: {
    all: [],
    bySlot: { s1: [{ id: "lt", kind: "lower_third", title: "Host" }], ghost: [{ id: "x", kind: "banner", text: "Hi" }] },
  },
  layout: { bySlot: { s1: [{ id: "lt", spot: "tl" }, { id: "ctr" }] } },
  elements: [counter()],
  ...over,
});

const row = (over: Partial<ElementRow> = {}): ElementRow => {
  const v = validateElementPush(counter({ state: { value: 7 }, targets: { all: true }, version: 4 }), { slotIds });
  if ("error" in v) throw new Error(v.error);
  return { ...buildRow("ev", v.push, undefined, 1000), ...over };
};

Deno.test("apply: a resolved layout is cleaned with the usual rules", () => {
  const r = validateApply(body(), opts);
  assert("plan" in r);
  assertEquals(r.plan.applied, { id: LAYOUT_ID, updatedAt: "2026-11-01T22:00:00Z" });
  assertEquals(Object.keys(r.plan.graphics.bySlot), ["s1"]); // unknown camera dropped
  assertEquals(r.plan.layout.bySlot.s1, [{ id: "lt", spot: "tl" }, { id: "ctr" }]);
  assertEquals(r.plan.elements.map((e) => e.id), ["ctr"]);
});

Deno.test("apply: junk is refused", () => {
  assert("error" in validateApply(body({ applied: { id: "nope" } }), opts));
  assert("error" in validateApply(body({ graphics: "x" }), opts));
  assert("error" in validateApply(body({ layout: null }), opts));
  assert("error" in validateApply(body({ elements: [counter(), counter()] }), opts));
  assert("error" in validateApply(body({ elements: [counter({ kind: "rocket" })] }), opts));
  assert("error" in validateApply(body({ elements: "x" }), opts));
});

Deno.test("elements: one already in the show keeps its values; only cameras and angle change", () => {
  const prev = row({ state: { value: 7, clocks: { main: { elapsedMs: 500, runningSince: 900 } } } });
  const v = validateApply(
    body({ elements: [counter({ state: { value: 0 }, config: { label: "Other", step: 5 }, targets: { slots: ["s2"] }, angle: true, version: 5 })] }),
    opts,
  );
  assert("plan" in v);
  const p = planElements(v.plan.elements, [prev], "ev", 2000);
  assert("next" in p);
  const w = p.writes[0].row;
  assertEquals(w.version, 5);
  assertEquals(w.state.value, 7);
  assertEquals(w.state.clocks, { main: { elapsedMs: 500, runningSince: 900 } });
  assertEquals(w.spec.config, { label: "Goals", step: 1 });
  assertEquals(w.spec.targets, { slots: ["s2"] });
  assertEquals(w.spec.angle, true);
  assertEquals([...angleIdsOf(p.next)], ["el:ctr"]);
});

Deno.test("elements: losing its angle drops the flag", () => {
  const prev = row({ spec: { ...row().spec, angle: true } });
  const v = validateApply(body({ elements: [counter({ targets: { slots: [] }, version: 5 })] }), opts);
  assert("plan" in v);
  const p = planElements(v.plan.elements, [prev], "ev", 2000);
  assert("next" in p);
  assertEquals(p.writes[0].row.spec.angle, undefined);
  assertEquals(liveSnapshot(p.next).items, []); // off air everywhere, not an angle
});

Deno.test("elements: a new one starts from its push; untouched ones stay", () => {
  const other = row({ element_id: "other" });
  const v = validateApply(body(), opts);
  assert("plan" in v);
  const p = planElements(v.plan.elements, [other], "ev", 2000);
  assert("next" in p);
  assertEquals(p.writes.length, 1);
  assertEquals(p.writes[0].prev, undefined);
  assertEquals(p.writes[0].row.state, { value: 0 });
  assertEquals(p.next.map((r) => r.element_id).sort(), ["ctr", "other"]);
});

Deno.test("elements: an old version is refused with the current one", () => {
  const v = validateApply(body({ elements: [counter({ version: 4 })] }), opts);
  assert("plan" in v);
  const p = planElements(v.plan.elements, [row()], "ev", 2000);
  assert("error" in p);
  assertEquals(p.error, "stale");
  assertEquals((p.current as { version: number }).version, 4);
});

Deno.test("show: unknown ids are dropped, sendAll is never set", () => {
  const ids = new Set(["s1", "s2", "el:ctr"]);
  assertEquals(
    cleanAppliedShow({ offAir: ["s2", "gone", "s2", 3], defaultSlot: "el:ctr", slotOrder: ["el:ctr", "s2", "gone", "s1"], sendAll: "s1" }, ids),
    { offAir: ["s2"], defaultSlot: "el:ctr", slotOrder: ["el:ctr", "s2", "s1"] },
  );
  assertEquals(cleanAppliedShow({ defaultSlot: "gone" }, ids), { offAir: [], defaultSlot: null, slotOrder: [] });
  assertEquals(cleanAppliedShow(null, ids), { offAir: [], defaultSlot: null, slotOrder: [] });
});
