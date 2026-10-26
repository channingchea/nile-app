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
import {
  cleanPollConfig,
  elementAngleIds,
  openChoices,
  reshapes,
  shapeTally,
  totalsPublic,
  validateResponse,
} from "../_shared/elements.ts";
import { cleanShowPatch, planReorder } from "../_shared/show.ts";

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

// ── Phase 4: element angles ─────────────────────────────────────────────────


Deno.test("angle: an element that is only its own angle still reaches viewers", () => {
  const row = buildRow("ev", push({ id: "el-9", targets: { slots: [] }, angle: true }), undefined, 1);
  assertEquals(row.spec.angle, true);
  const snap = liveSnapshot([row]);
  assertEquals(snap.items.map((e) => e.id), ["el-9"]);
  assertEquals(elementAngleIds({ elements: snap }), new Set(["el:el-9"]));
  assertEquals(elementAngleIds({}), new Set());
});

Deno.test("angle: show control and reorder take element angles", () => {
  const ids = new Set(["s1", "s2", "el:x"]);
  const r = cleanShowPatch({ offAir: ["el:x"], defaultSlot: "el:x" }, ids, {}, 1);
  assert("patch" in r);
  assertEquals(r.patch.offAir, ["el:x"]);
  const slots = [
    { id: "s1", slot_index: 1, label: "Camera 1" },
    { id: "s2", slot_index: 2, label: "Camera 2" },
  ];
  const plan = planReorder(["el:x", "s2", "s1"], slots, new Set(["el:x"]));
  assert("rows" in plan);
  assertEquals(plan.order, ["el:x", "s2", "s1"]);
  // Cameras are numbered among cameras only.
  assertEquals(plan.rows.map((r) => [r.id, r.label]), [["s2", "Camera 1"], ["s1", "Camera 2"]]);
  assert("error" in planReorder(["el:y", "s2", "s1"], slots, new Set(["el:x"])));
  assert("error" in planReorder(["el:x", "s2"], slots, new Set(["el:x"])));
});

// ── Phase 5: viewer taps ────────────────────────────────────────────────────

Deno.test("taps: only an open, live element with taps takes a vote, and only its own choices", () => {
  const open = buildRow("ev", push({ config: { label: "Q", taps: true }, state: { value: 0, open: true } }), undefined, 1);
  assertEquals(openChoices(open), ["up", "down"]);
  assertEquals(validateResponse(open, { choice: "up" }), { picks: ["up"] });
  assertEquals(validateResponse(open, { picks: ["down"] }), { picks: ["down"] });
  assertEquals((validateResponse(open, { choice: "sideways" }) as { status: number }).status, 400);
  assertEquals((validateResponse(open, { picks: ["up", "down"] }) as { status: number }).status, 400);

  const closed = buildRow("ev", push({ config: { label: "Q", taps: true }, state: { value: 0 } }), undefined, 1);
  assertEquals((validateResponse(closed, { choice: "up" }) as { status: number }).status, 409);

  const noTaps = buildRow("ev", push({ state: { value: 0, open: true } }), undefined, 1);
  assertEquals(openChoices(noTaps), []);

  const offAir = buildRow("ev", push({ config: { taps: true }, state: { open: true }, targets: { slots: [] } }), undefined, 1);
  assertEquals(openChoices(offAir), []);
  assertEquals((validateResponse(undefined, { choice: "up" }) as { status: number }).status, 404);
});

Deno.test("taps: totals list every choice, zeros included, junk ignored", () => {
  assertEquals(shapeTally(["up", "down"], { up: 3, other: 9 }), { up: 3, down: 0 });
  assertEquals(shapeTally(["up", "down"], { up: -1, down: "7" }), { up: 0, down: 0 });
});

// ── Polls (docs/plans/studio-poll.md, phase 1) ────────────────────────────

const answers = [
  { id: "a", text: "Red" },
  { id: "b", text: "Blue" },
  { id: "c", text: "Green" },
];
const poll = (config: Record<string, unknown>, state: Record<string, unknown> = {}, over: Record<string, unknown> = {}) =>
  push({ kind: "poll", name: "Poll", config: { question: "Best colour?", ...config }, state, ...over });

Deno.test("poll: settings are cleaned; yes/no and rating fill in their own answers", () => {
  assertEquals(cleanPollConfig({ question: "  Best colour? ", answers }), {
    type: "choice",
    question: "Best colour?",
    results: "live",
    answers,
  });
  assertEquals(cleanPollConfig({ type: "yesno", question: "Q", answers: [{ id: "x", text: "Maybe" }] }), {
    type: "yesno",
    question: "Q",
    results: "live",
  });
  assertEquals(
    (poll({ type: "rating" }).spec.config.type),
    "rating",
  );
  assertEquals(cleanPollConfig({ type: "several", question: "Q", answers, maxPicks: 2, results: "reveal", timerSec: 60 }), {
    type: "several",
    question: "Q",
    results: "reveal",
    timerSec: 60,
    answers,
    maxPicks: 2,
  });
  const bad = [
    { question: "", answers },
    { question: "x".repeat(121), answers },
    { question: "Q", answers: answers.slice(0, 1) },
    { question: "Q", answers: [...answers, ...answers.map((a) => ({ ...a, id: a.id + "2", text: a.text + "2" })), { id: "z", text: "7" }] },
    { question: "Q", answers: [{ id: "a", text: "Red" }, { id: "a", text: "Blue" }] },
    { question: "Q", answers: [{ id: "a", text: "Red" }, { id: "b", text: "red" }] },
    { question: "Q", answers: [{ id: "A!", text: "Red" }, { id: "b", text: "Blue" }] },
    { question: "Q", answers: [{ id: "a", text: "x".repeat(41) }, { id: "b", text: "Blue" }] },
    { type: "several", question: "Q", answers, maxPicks: 4 },
    { question: "Q", answers, results: "never" },
    { question: "Q", answers, timerSec: 5 },
    { type: "quiz", question: "Q", answers },
  ];
  for (const c of bad) assertEquals(cleanPollConfig(c), null, JSON.stringify(c));
});

Deno.test("poll: closesAt and round are the server's; ops run on its clock", () => {
  // The Studio can't write closesAt or round.
  const first = buildRow("ev", poll({ answers, timerSec: 30 }, { open: true, closesAt: 5, round: 9 }), undefined, 1000);
  assertEquals(first.state, { open: true, round: 0 });

  const timed = buildRow("ev", poll({ answers, timerSec: 30 }, { open: true }, { version: 2, ops: { timer: { op: "start" } } }), first, 2000);
  assertEquals(timed.state, { open: true, round: 0, closesAt: 32000 });
  const custom = buildRow("ev", poll({ answers }, { open: true }, { version: 2, ops: { timer: { op: "start", sec: 10 } } }), first, 2000);
  assertEquals(custom.state.closesAt, 12000);
  // A later push keeps the timer; cancel clears it.
  assertEquals(buildRow("ev", poll({ answers }, { open: true }, { version: 3 }), timed, 3000).state.closesAt, 32000);
  assertEquals(buildRow("ev", poll({ answers }, {}, { version: 3, ops: { timer: { op: "cancel" } } }), timed, 3000).state, { round: 0 });

  // Reset: a new round, no timer.
  const reset = buildRow("ev", poll({ answers }, {}, { version: 3, ops: { reset: true } }), timed, 3000);
  assertEquals(reset.state, { round: 1 });

  // No timer without a length; ops are for polls only.
  assert("error" in validateElementPush({ ...base, kind: "poll", config: { question: "Q", answers }, ops: { timer: { op: "start" } } }, opts));
  assert("error" in validateElementPush({ ...base, kind: "poll", config: { question: "Q", answers }, ops: { timer: { op: "start", sec: 4000 } } }, opts));
  assert("error" in validateElementPush({ ...base, ops: { reset: true } }, opts));
});

Deno.test("poll: wording edits keep the answers; changing them reshapes", () => {
  const a = cleanPollConfig({ question: "Q", answers })!;
  const reworded = cleanPollConfig({ question: "Q?", answers: answers.map((x) => ({ ...x, text: x.text + "!" })) })!;
  assertEquals(reshapes("poll", a, reworded), false);
  assertEquals(reshapes("poll", a, cleanPollConfig({ question: "Q", answers: [...answers].reverse() })!), true);
  assertEquals(reshapes("poll", a, cleanPollConfig({ question: "Q", answers: answers.slice(0, 2) })!), true);
  assertEquals(reshapes("poll", a, cleanPollConfig({ type: "several", question: "Q", answers })!), true);
  assertEquals(reshapes("counter", { label: "a" }, { label: "b", taps: true }), false);
});

Deno.test("poll: picks — its own answers, once each, within the limit, before close", () => {
  const one = buildRow("ev", poll({ answers }, { open: true }), undefined, 0);
  assertEquals(validateResponse(one, { picks: ["b"] }, 1), { picks: ["b"] });
  assertEquals((validateResponse(one, { picks: ["a", "b"] }, 1) as { status: number }).status, 400);
  assertEquals((validateResponse(one, { picks: [] }, 1) as { status: number }).status, 400);
  assertEquals((validateResponse(one, { picks: ["z"] }, 1) as { status: number }).status, 400);

  const several = buildRow("ev", poll({ type: "several", answers, maxPicks: 2 }, { open: true }), undefined, 0);
  assertEquals(validateResponse(several, { picks: ["a", "c"] }, 1), { picks: ["a", "c"] });
  assertEquals((validateResponse(several, { picks: ["a", "b", "c"] }, 1) as { error: string }).error, "Pick up to 2");
  assertEquals((validateResponse(several, { picks: ["a", "a"] }, 1) as { status: number }).status, 400);
  const any = buildRow("ev", poll({ type: "several", answers }, { open: true }), undefined, 0);
  assertEquals(validateResponse(any, { picks: ["a", "b", "c"] }, 1), { picks: ["a", "b", "c"] });

  const rating = buildRow("ev", poll({ type: "rating" }, { open: true }), undefined, 0);
  assertEquals(openChoices(rating, 1), ["1", "2", "3", "4", "5"]);

  // The timer closes voting by itself, Studio or no Studio.
  const timed = buildRow("ev", poll({ answers }, { open: true }, { ops: { timer: { op: "start", sec: 10 } } }), undefined, 0);
  assertEquals(validateResponse(timed, { picks: ["a"] }, 9999), { picks: ["a"] });
  assertEquals((validateResponse(timed, { picks: ["a"] }, 10000) as { error: string }).error, "Voting has closed");
  assertEquals(openChoices(timed, 10000), []);
});

Deno.test("poll: reveal mode withholds totals from viewers until the reveal", () => {
  assertEquals(totalsPublic(buildRow("ev", poll({ answers, results: "reveal" }, { open: true }), undefined, 0)), false);
  assertEquals(totalsPublic(buildRow("ev", poll({ answers, results: "reveal" }, { revealed: true }), undefined, 0)), true);
  assertEquals(totalsPublic(buildRow("ev", poll({ answers, results: "voted" }, { open: true }), undefined, 0)), true);
  assertEquals(totalsPublic(buildRow("ev", push(), undefined, 0)), true);
});
