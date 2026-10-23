// Studio edits (graphics targeting/auto-hide, chat on screen, show control):
// the pure rules behind set-graphics, set-show and reorder-cameras.
//
//   deno test --allow-env supabase/functions/tests/

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { cleanGraphic, validateGraphics } from "../_shared/graphics.ts";
import { cleanShowPatch, planReorder } from "../_shared/show.ts";
import type { Slot } from "../_shared/studio.ts";

const STORAGE = "https://x.supabase.co/storage/v1/object/public/";
const opts = {
  imagePrefix: `${STORAGE}studio-graphics/`,
  avatarPrefix: STORAGE,
  slotIds: new Set(["s1", "s2", "s3"]),
};

Deno.test("graphics: except is kept for real slots only, deduped and sorted", () => {
  const r = validateGraphics({
    all: [{ id: "lt", kind: "lower_third", title: "Jane", except: ["s2", "ghost", "s1", "s2", 7] }],
    bySlot: { s3: [{ id: "x", kind: "banner", text: "Hi", except: ["s1"] }] },
  }, opts);
  assert("state" in r);
  assertEquals(r.state.all[0].except, ["s1", "s2"]);
  // except means nothing on a per-camera graphic.
  assertEquals(r.state.bySlot.s3[0].except, undefined);
});

Deno.test("graphics: hideAt survives, rounded; junk dropped", () => {
  assertEquals(cleanGraphic({ id: "a", kind: "lower_third", title: "A", hideAt: 1234.6 }, opts)?.hideAt, 1235);
  assertEquals(cleanGraphic({ id: "a", kind: "lower_third", title: "A", hideAt: "soon" }, opts)?.hideAt, undefined);
});

Deno.test("graphics: chat cards — need a name and a message; avatars only from our storage", () => {
  const ok = cleanGraphic(
    { id: "chat:1", kind: "chat", title: "maya", text: "Hello!", avatarUrl: `${STORAGE}avatars/m.png` },
    opts,
  );
  assertEquals(ok?.avatarUrl, `${STORAGE}avatars/m.png`);
  const elsewhere = cleanGraphic(
    { id: "chat:2", kind: "chat", title: "maya", text: "Hi", avatarUrl: "https://lh3.googleusercontent.com/x" },
    opts,
  );
  assert(elsewhere);
  assertEquals(elsewhere.avatarUrl, undefined);
  assertEquals(cleanGraphic({ id: "chat:3", kind: "chat", title: "maya" }, opts), null);
  // Chat messages may be longer than a banner (200), not longer.
  assertEquals(cleanGraphic({ id: "c", kind: "chat", title: "m", text: "x".repeat(200) }, opts)?.text?.length, 200);
  assertEquals(cleanGraphic({ id: "c", kind: "chat", title: "m", text: "x".repeat(201) }, opts), null);
  assertEquals(cleanGraphic({ id: "b", kind: "banner", text: "x".repeat(141), scrolling: false }, opts), null);
});

Deno.test("graphics: countdown slates keep showsClock only with an end time", () => {
  assertEquals(cleanGraphic({ id: "s", kind: "slate", title: "In", endsAt: 5, showsClock: true }, opts)?.showsClock, true);
  assertEquals(cleanGraphic({ id: "s", kind: "slate", title: "In", showsClock: true }, opts)?.showsClock, undefined);
});

Deno.test("graphics: the old string-prefix form still works", () => {
  assert(cleanGraphic({ id: "l", kind: "logo", corner: "tl", imageUrl: `${STORAGE}studio-graphics/a.png` }, `${STORAGE}studio-graphics/`));
});

const ids = new Set(["s1", "s2", "s3"]);

Deno.test("set-show: partial patches, real slots only", () => {
  const r = cleanShowPatch({ offAir: ["s2", "s2"] }, ids, {}, 1000);
  assert("patch" in r);
  assertEquals(r.patch, { offAir: ["s2"] });
  assert("error" in cleanShowPatch({ offAir: ["nope"] }, ids, {}, 1000));
  assert("error" in cleanShowPatch({ offAir: "s1" }, ids, {}, 1000));
  assert("error" in cleanShowPatch({}, ids, {}, 1000));
});

Deno.test("set-show: default angle can be set or cleared", () => {
  const set = cleanShowPatch({ defaultSlot: "s3" }, ids, {}, 1);
  assert("patch" in set);
  assertEquals(set.patch.defaultSlot, "s3");
  const clear = cleanShowPatch({ defaultSlot: null }, ids, {}, 1);
  assert("patch" in clear);
  assertEquals(clear.patch.defaultSlot, null);
  assert("error" in cleanShowPatch({ defaultSlot: "ghost" }, ids, {}, 1));
});

Deno.test("set-show: send everyone gets a fresh nonce, never to an off-air camera", () => {
  const r = cleanShowPatch({ sendAll: "s1" }, ids, {}, 4242);
  assert("patch" in r);
  assertEquals(r.patch.sendAll, { slot: "s1", nonce: 4242 });
  assert("error" in cleanShowPatch({ sendAll: "s1" }, ids, { offAir: ["s1"] }, 1));
  // Taking it off air in the same request counts too.
  assert("error" in cleanShowPatch({ sendAll: "s1", offAir: ["s1"] }, ids, {}, 1));
  // …and putting it back on air in the same request allows it.
  assert("patch" in cleanShowPatch({ sendAll: "s1", offAir: [] }, ids, { offAir: ["s1"] }, 1));
});

const slots: Slot[] = [
  { id: "s1", slot_index: 1, label: "Camera 1" },
  { id: "s2", slot_index: 2, label: "Drums" },
  { id: "s3", slot_index: 3, label: "Camera 3" },
];

Deno.test("reorder: every slot exactly once", () => {
  assert("error" in planReorder(["s1", "s2"], slots));
  assert("error" in planReorder(["s1", "s1", "s2"], slots));
  assert("error" in planReorder(["s1", "s2", "ghost"], slots));
  assert("error" in planReorder("s1,s2,s3", slots));
});

Deno.test("reorder: default names follow position, chosen names stay", () => {
  const r = planReorder(["s3", "s2", "s1"], slots);
  assert("rows" in r);
  assertEquals(r.rows, [
    { id: "s3", slot_index: 1, label: "Camera 1" },
    { id: "s2", slot_index: 2, label: "Drums" },
    { id: "s1", slot_index: 3, label: "Camera 3" },
  ]);
});
