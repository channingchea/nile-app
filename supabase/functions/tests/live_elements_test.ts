// Studio live elements (foundation plan, phases 1-3): the pure rules behind
// set-element, list-elements and set-layout.
//
//   deno test --allow-env supabase/functions/tests/

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  applyClockOp,
  buildRow,
  cleanTargets,
  clockValue,
  contentAt,
  type ElementRow,
  liveSnapshot,
  rowToLive,
  validateElementPush,
  validateLayout,
} from "../_shared/elements.ts";

const slotIds = new Set(["s1", "s2"]);
const opts = { slotIds, sponsorCampaignId: "c-1" };
const base = {
  id: "el-1",
  kind: "counter",
  name: "Score",
  config: { label: "Goals", step: 1 },
  state: { value: 3 },
  targets: { all: true },
  version: 1,
};

const push = (over: Record<string, unknown> = {}) => {
  const r = validateElementPush({ ...base, ...over }, opts);
  if ("error" in r) throw new Error(r.error);
  return r.push;
};

Deno.test("clock: start, pause, resume and reset, all in server time", () => {
  let c = applyClockOp(undefined, { op: "start" }, 1000);
  assertEquals(c, { elapsedMs: 0, runningSince: 1000 });
  assertEquals(clockValue(c, 4000), 3000);
  // Starting a running clock changes nothing.
  assertEquals(applyClockOp(c, { op: "start" }, 2000), c);
  c = applyClockOp(c, { op: "pause" }, 5000);
  assertEquals(c, { elapsedMs: 4000, pausedAt: 5000 });
  assertEquals(clockValue(c, 99_000), 4000);
  c = applyClockOp(c, { op: "start" }, 10_000);
  assertEquals(clockValue(c, 11_000), 5000);
  assertEquals(applyClockOp(c, { op: "set", ms: 60_000 }, 12_000), { elapsedMs: 60_000, runningSince: 12_000 });
  assertEquals(applyClockOp(c, { op: "reset" }, 12_000), { elapsedMs: 0 });
});

Deno.test("push: a counter is cleaned; junk is refused", () => {
  const p = push();
  assertEquals(p.spec, { name: "Score", config: { label: "Goals", step: 1 }, targets: { all: true } });
  assertEquals(p.state, { value: 3 });
  assert("error" in validateElementPush({ ...base, kind: "rocket" }, opts));
  assert("error" in validateElementPush({ ...base, id: "has spaces" }, opts));
  assert("error" in validateElementPush({ ...base, version: 0 }, opts));
  assert("error" in validateElementPush({ ...base, name: " " }, opts));
  assert("error" in validateElementPush({ ...base, config: { step: 500 } }, opts));
  // Out-of-range state falls back to the kind's default.
  assertEquals(push({ state: { value: 1e9 } }).state, { value: 0 });
});

Deno.test("push: only real slots are targeted; off air is an empty list", () => {
  assertEquals(cleanTargets({ all: true, except: ["s2", "nope"] }, slotIds), { all: true, except: ["s2"] });
  assertEquals(cleanTargets({ slots: ["s1", "zz", "s1"] }, slotIds), { slots: ["s1"] });
  assertEquals(push({ targets: undefined }).spec.targets, { slots: [] });
  assertEquals(cleanTargets("all", slotIds), null);
});

Deno.test("push: brand style, nile style and the sponsor hook", () => {
  const p = push({ style: { accent: "#ff0000", panel: "#000000", text: "#ffffff" }, nileStyle: true });
  assertEquals(p.spec.style?.accent, "#FF0000");
  assertEquals(p.spec.nileStyle, true);
  assertEquals(push({ presentedBy: "c-1" }).spec.presentedBy, "c-1");
  assert("error" in validateElementPush({ ...base, presentedBy: "someone-else" }, opts));
  assert("error" in validateElementPush({ ...base, presentedBy: "c-1" }, { slotIds, sponsorCampaignId: null }));
});

Deno.test("push: clock commands must name a clock the kind runs", () => {
  assertEquals(push({ clockOps: { main: { op: "start" } } }).clockOps, { main: { op: "start" } });
  assert("error" in validateElementPush({ ...base, clockOps: { shot: { op: "start" } } }, opts));
  assert("error" in validateElementPush({ ...base, clockOps: { main: { op: "explode" } } }, opts));
  assert("error" in validateElementPush({ ...base, clockOps: { main: { op: "set" } } }, opts));
});

Deno.test("row: clocks carry over and the Studio can't write their timestamps", () => {
  const first = buildRow("ev", push({ clockOps: { main: { op: "start" } } }), undefined, 1000);
  assertEquals(first.state, { value: 3, clocks: { main: { elapsedMs: 0, runningSince: 1000 } } });
  // A later push without a command keeps the clock; one smuggling its own clocks is ignored.
  const second = buildRow(
    "ev",
    push({ version: 2, state: { value: 4, clocks: { main: { elapsedMs: 999_999, runningSince: 1 } } } }),
    first,
    3000,
  );
  assertEquals(second.state, { value: 4, clocks: { main: { elapsedMs: 0, runningSince: 1000 } } });
  const paused = buildRow("ev", push({ version: 3, clockOps: { main: { op: "pause" } } }), second, 6000);
  assertEquals(paused.state.clocks, { main: { elapsedMs: 5000, pausedAt: 6000 } });
});

Deno.test("row: content time subtracts the Studio's picture age, capped", () => {
  assertEquals(contentAt(10_000, 400), 9_600);
  assertEquals(contentAt(10_000, 99_999), 10_000);
  assertEquals(buildRow("ev", push({ srcAgeMs: 250 }), undefined, 5000).content_at, 4750);
});

Deno.test("snapshot: only on-air elements reach viewers", () => {
  const on = buildRow("ev", push(), undefined, 100);
  const off = buildRow("ev", push({ id: "el-2", targets: { slots: [] } }), undefined, 200);
  const snap = liveSnapshot([off, on] as ElementRow[]);
  assertEquals(snap.items.map((e) => e.id), ["el-1"]);
  assertEquals(snap.at, 100);
  assertEquals(rowToLive(on), {
    id: "el-1",
    kind: "counter",
    name: "Score",
    config: { label: "Goals", step: 1 },
    targets: { all: true },
    state: { value: 3 },
    version: 1,
    at: 100,
  });
});

Deno.test("layout: spots, hidden, real slots and de-duplicated ids", () => {
  const r = validateLayout({
    all: [{ id: "a", spot: "tl" }, { id: "a", spot: "br" }, { id: "b", spot: "nowhere", hidden: true }],
    bySlot: { s1: [{ id: "c", spot: "full" }], ghost: [{ id: "d" }], s2: [] },
  }, slotIds);
  assert("layout" in r);
  assertEquals(r.layout, {
    all: [{ id: "a", spot: "tl" }, { id: "b", hidden: true }],
    bySlot: { s1: [{ id: "c", spot: "full" }] },
  });
  assert("error" in validateLayout("x", slotIds));
});
