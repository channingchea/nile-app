// Studio master host (Phases 1-3): who holds a slot, who counts as a camera,
// and who carries the show's audio.
//
//   deno test --allow-env supabase/functions/tests/

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  cleanCameraName,
  flagsToClear,
  joinTakesMasterAudio,
  liveCameraCount,
  type Peer,
  resolveSlot,
  type Slot,
  studioConnected,
} from "../_shared/studio.ts";

const slots: Slot[] = [
  { id: "s1", slot_index: 1, label: "Camera 1" },
  { id: "s2", slot_index: 2, label: "Camera 2" },
  { id: "s3", slot_index: 3, label: "Camera 3" },
];
const cam = (identity: string, meta: Record<string, unknown> = {}): Peer => ({
  identity,
  meta: { role: "camera", ...meta },
});
const studio = (meta: Record<string, unknown> = {}): Peer => ({
  identity: "studio-ev",
  meta: { role: "studio", ...meta },
});
const audio = (meta: Record<string, unknown> = {}): Peer => ({
  identity: "master-audio-ev",
  meta: { role: "master-audio", ...meta },
});

// ── Slots ────────────────────────────────────────────────────────────────────

Deno.test("explicit pick of a free slot is honoured", () => {
  assertEquals(resolveSlot({ slots, peers: [], identity: "camera-a", slotId: "s2" }), { slot: slots[1] });
});

Deno.test("explicit pick of a held slot conflicts", () => {
  const peers = [cam("camera-b", { slotId: "s1" })];
  const r = resolveSlot({ slots, peers, identity: "camera-a", slotId: "s1" });
  assert("conflict" in r);
  assertEquals(r.heldBy.identity, "camera-b");
});

Deno.test("the same device reconnecting keeps its slot", () => {
  const peers = [cam("camera-a", { slotId: "s1" })];
  assertEquals(resolveSlot({ slots, peers, identity: "camera-a", slotId: "s1" }), { slot: slots[0] });
});

Deno.test("a deleted slot is reported missing", () => {
  assertEquals(resolveSlot({ slots, peers: [], identity: "camera-a", slotId: "gone" }), { missing: true });
});

Deno.test("crew land on their assigned slot", () => {
  const r = resolveSlot({ slots, peers: [], identity: "camera-a", assignedSlotId: "s3", cameraName: "Camera 1" });
  assertEquals(r, { slot: slots[2] });
});

Deno.test("an implicit slot that is taken falls through to the first open one", () => {
  const peers = [cam("camera-b", { slotId: "s1" })];
  assertEquals(resolveSlot({ slots, peers, identity: "camera-a", assignedSlotId: "s1" }), { slot: slots[1] });
  assertEquals(resolveSlot({ slots, peers, identity: "camera-a", cameraName: "Camera 1" }), { slot: slots[1] });
});

Deno.test("older builds match a slot by its label", () => {
  assertEquals(resolveSlot({ slots, peers: [], identity: "camera-a", cameraName: "Camera 2" }), { slot: slots[1] });
});

Deno.test("no open slot leaves the feed slotless", () => {
  const peers = slots.map((s, i) => cam(`camera-${i}`, { slotId: s.id }));
  assertEquals(resolveSlot({ slots, peers, identity: "camera-x" }), { slot: null });
});

Deno.test("the Studio's webcam holds a slot like any camera", () => {
  const peers = [studio({ hasCamera: true, slotId: "s1" })];
  const r = resolveSlot({ slots, peers, identity: "camera-a", slotId: "s1" });
  assert("conflict" in r);
});

// ── Camera count ─────────────────────────────────────────────────────────────

Deno.test("the Studio counts as a camera only while its webcam is on", () => {
  assertEquals(liveCameraCount([cam("camera-a"), studio(), audio()]), 1);
  assertEquals(liveCameraCount([cam("camera-a"), studio({ hasCamera: true })]), 2);
  assertEquals(liveCameraCount([cam("camera-a"), cam("camera-b")], "camera-a"), 1);
});

Deno.test("studio presence", () => {
  assert(studioConnected([cam("camera-a"), studio()]));
  assert(!studioConnected([cam("camera-a"), audio()]));
});

// ── Master audio ─────────────────────────────────────────────────────────────

Deno.test("the first camera into an empty room takes master audio", () => {
  assert(joinTakesMasterAudio({ identity: "camera-a", role: "camera", peers: [] }));
  assert(!joinTakesMasterAudio({ identity: "camera-b", role: "camera", peers: [cam("camera-a")] }));
});

Deno.test("a camera joining after the Studio still defaults to master audio", () => {
  assert(joinTakesMasterAudio({ identity: "camera-a", role: "camera", peers: [studio()] }));
});

Deno.test("the Studio never takes master audio by default", () => {
  assert(!joinTakesMasterAudio({ identity: "studio-ev", role: "studio", peers: [] }));
});

Deno.test("Stream Audio takes master audio unless a live choice says otherwise", () => {
  const peers = [cam("camera-a", { isMasterAudio: true })];
  assert(joinTakesMasterAudio({ identity: "master-audio-ev", role: "master-audio", peers }));
  assert(!joinTakesMasterAudio({ identity: "master-audio-ev", role: "master-audio", peers, chosen: "camera-a" }));
});

Deno.test("the chosen source reclaims audio when it rejoins", () => {
  const peers = [audio({ isMasterAudio: true }), cam("camera-b")];
  assert(joinTakesMasterAudio({ identity: "studio-ev", role: "studio", peers, chosen: "studio-ev" }));
  assert(joinTakesMasterAudio({ identity: "camera-a", role: "camera", peers, chosen: "camera-a" }));
});

Deno.test("a choice whose holder left no longer blocks Stream Audio", () => {
  assert(joinTakesMasterAudio({ identity: "master-audio-ev", role: "master-audio", peers: [], chosen: "camera-a" }));
});

Deno.test("taking the flag clears it everywhere else — exactly one holder", () => {
  const peers = [
    cam("camera-a", { isMasterAudio: true }),
    studio({ isMasterAudio: true }),
    cam("camera-b"),
    { identity: "viewer-1", meta: { role: "viewer", isMasterAudio: true } },
  ];
  assertEquals(flagsToClear(peers, "camera-b").map((p) => p.identity), ["camera-a", "studio-ev"]);
});

Deno.test("camera names are trimmed and bounded", () => {
  assertEquals(cleanCameraName("  Stage   Left "), "Stage Left");
  assertEquals(cleanCameraName(""), null);
  assertEquals(cleanCameraName("x".repeat(41)), null);
  assertEquals(cleanCameraName(42), null);
});
