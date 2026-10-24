// node recorder/recorder_test.js — the recorder page's layout rules.
const assert = require("assert");
const { pickTiles, layout } = require("./recorder.js");

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
console.log("recorder layout ok");
