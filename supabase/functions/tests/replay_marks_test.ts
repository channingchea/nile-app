// Grid replays (studio live elements, phase 6): what the recorder page may
// report, and how the replay timeline is put together.
//
//   deno test --allow-env supabase/functions/tests/

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { cleanMark, cleanUpload, timelineOf } from "../_shared/replay_marks.ts";

const KEY = "0b5a2f8e-3c1d-4e6f-9a7b-1c2d3e4f5a6b";

Deno.test("marks: each kind is shaped, bad ones dropped", () => {
  assertEquals(cleanMark({ s: 0, o: 0, k: "start", d: { wall: 1700000000000 } })?.data, { wall: 1700000000000 });
  assertEquals(cleanMark({ s: 1, o: 10, k: "end", d: { junk: 1 } })?.data, {});
  assertEquals(
    cleanMark({ s: 2, o: 20, k: "tiles", d: [{ s: "slot-a", r: [0, 0, 0.5, 0.5] }, { el: "e1", r: [0.5, 0, 0.5, 0.5] }] })?.data,
    [{ s: "slot-a", el: null, r: [0, 0, 0.5, 0.5] }, { s: null, el: "e1", r: [0.5, 0, 0.5, 0.5] }],
  );
  assertEquals(cleanMark({ s: 3, o: 30, k: "meta", d: '{"graphics":{"all":[]}}' })?.data, { graphics: { all: [] } });
  assertEquals(cleanMark({ s: 3, o: 30, k: "meta", d: "" })?.data, {});

  assertEquals(cleanMark({ s: -1, o: 0, k: "end" }), null);
  assertEquals(cleanMark({ s: 1.5, o: 0, k: "end" }), null);
  assertEquals(cleanMark({ s: 1, o: -5, k: "end" }), null);
  assertEquals(cleanMark({ s: 1, o: 0, k: "tally", d: {} }), null, "tallies are server-written only");
  assertEquals(cleanMark({ s: 1, o: 0, k: "start", d: {} }), null);
  assertEquals(cleanMark({ s: 1, o: 0, k: "tiles", d: [{ r: [0, 0, 2, 1] }] }), null);
  assertEquals(cleanMark({ s: 1, o: 0, k: "tiles", d: Array(17).fill({ r: [0, 0, 1, 1] }) }), null);
  assertEquals(cleanMark({ s: 1, o: 0, k: "meta", d: "[1]" }), null);
  assertEquals(cleanMark({ s: 1, o: 0, k: "meta", d: "{nope" }), null);
  assertEquals(cleanMark({ s: 1, o: 0, k: "meta", d: "x".repeat(60001) }), null);
});

Deno.test("upload: key checked, marks filtered, size capped", () => {
  assert("error" in cleanUpload({ key: "nope", marks: [] }));
  assert("error" in cleanUpload({ key: KEY, marks: Array(101).fill({}) }));
  const ok = cleanUpload({ key: KEY, marks: [{ s: 0, o: 0, k: "end" }, { s: 1, o: 0, k: "bogus" }] });
  assert(!("error" in ok));
  assertEquals(ok.marks.length, 1);
});

Deno.test("timeline: tallies placed from wall time, sorted by video time", () => {
  const start = "2026-10-23T20:00:00.000Z";
  const rows = [
    { offset_ms: 5000, at: "2026-10-23T20:00:09Z", kind: "meta", data: { a: 1 } },
    { offset_ms: null, at: "2026-10-23T20:00:03Z", kind: "tally", data: { elementId: "e", tally: { a: 2 } } },
    { offset_ms: null, at: "2026-10-23T19:59:00Z", kind: "tally", data: {} }, // before recording
    { offset_ms: 0, at: "2026-10-23T20:00:00Z", kind: "start", data: { wall: 1 } },
  ];
  assertEquals(timelineOf(rows, start).map((m) => [m.o, m.k]), [[0, "start"], [3000, "tally"], [5000, "meta"]]);
  // No recording start known: tallies can't be placed and are left out.
  assertEquals(timelineOf(rows, null).map((m) => m.k), ["start", "meta"]);
});
