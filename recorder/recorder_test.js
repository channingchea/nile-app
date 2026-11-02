// node recorder/recorder_test.js — the recorder page's layout rules.
const assert = require("assert");
const { pickTiles, layout, stageLayout, stageOf } = require("./recorder.js");

const cam = (key, slot, share = false) => ({ key, slot, share });

// Off-air cameras and element angles drop out; host order wins.
const meta = {
  offAir: ["b", "el:e2"],
  slotOrder: ["el:e1", "c", "a"],
  elements: { items: [{ id: "e1", angle: true }, { id: "e2", angle: true }, { id: "e3" }] },
};
const picked = pickTiles(meta, [cam("1", "a"), cam("2", "b"), cam("3", "c"), cam("4", "a", true), cam("5", null)]);
assert.deepStrictEqual(picked.map((t) => t.key), ["el:e1", "3", "1", "4", "5"]);
assert.deepStrictEqual(picked.map((t) => [t.s, t.el]), [[null, "e1"], ["c", null], ["a", null], [null, null], [null, null]]);
assert.deepStrictEqual(pickTiles({}, [cam("x", "a")]).map((t) => t.key), ["x"]);

// Geometry: one tile fills the frame; two side by side; three = 2×2 with the
// last row centred; every tile is 16:9 inside the frame.
assert.deepStrictEqual(layout(0, 1920, 1080, 0), []);
assert.deepStrictEqual(layout(1, 1920, 1080, 0), [[0, 0, 1, 1]]);
assert.deepStrictEqual(layout(2, 1920, 1080, 0), [[0, 0.25, 0.5, 0.5], [0.5, 0.25, 0.5, 0.5]]);
assert.deepStrictEqual(layout(3, 1920, 1080, 0), [[0, 0, 0.5, 0.5], [0.5, 0, 0.5, 0.5], [0.25, 0.5, 0.5, 0.5]]);
for (let n = 1; n <= 16; n++) {
  for (const [x, y, w, h] of layout(n, 1920, 1080, 12)) {
    assert.ok(x >= 0 && y >= 0 && x + w <= 1.0001 && y + h <= 1.0001, `n=${n} in frame`);
    assert.ok(Math.abs((w * 1920) / (h * 1080) - 16 / 9) < 0.01, `n=${n} is 16:9`);
  }
}
// Interview stage: the same numbers as stageSlots in lib/services/interview.dart
// (test/interview_test.dart asserts the identical values).
assert.deepStrictEqual(stageLayout("grid", 0, 0), []);
assert.deepStrictEqual(stageLayout("grid", 1, 0), [{ index: 0, r: [0, 0, 1, 1] }]);
assert.deepStrictEqual(stageLayout("solo", 3, 2), [{ index: 2, r: [0, 0, 1, 1] }]);
assert.deepStrictEqual(stageLayout("side", 2, 0), [{ index: 0, r: [0, 0, 0.495, 1] }, { index: 1, r: [0.505, 0, 0.495, 1] }]);
assert.deepStrictEqual(stageLayout("grid", 3, 0), [
  { index: 0, r: [0, 0, 0.495, 0.4911] },
  { index: 1, r: [0.505, 0, 0.495, 0.4911] },
  { index: 2, r: [0.2525, 0.5089, 0.495, 0.4911] },
]);
assert.deepStrictEqual(stageLayout("spotlight", 3, 1), [
  { index: 1, r: [0, 0, 0.75, 1] },
  { index: 0, r: [0.76, 0, 0.24, 0.4911] },
  { index: 2, r: [0.76, 0.5089, 0.24, 0.4911] },
]);
for (const lay of ["side", "grid", "spotlight"]) {
  for (let n = 1; n <= 6; n++) {
    for (const { r: [x, y, w, h] } of stageLayout(lay, n, 0)) {
      assert.ok(x >= 0 && y >= 0 && x + w <= 1.0001 && y + h <= 1.0001, `${lay} n=${n} in frame`);
    }
  }
}
// Countdowns: someone appears only once their time has come.
const st = stageOf({ stage: { ids: [{ id: "a", at: 0 }, { id: "b", at: 5000 }], layout: "spotlight", focus: "b" } }, 1000);
assert.deepStrictEqual(st, { ids: ["a"], layout: "spotlight", fi: 0 });
assert.deepStrictEqual(stageOf({}, 0), { ids: [], layout: "grid", fi: 0 });
console.log("recorder layout ok");
