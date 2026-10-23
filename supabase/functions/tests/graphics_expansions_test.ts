// Graphics library expansions: brand kit, QR codes and the in-show sponsor
// logo — the pure rules behind set-graphics.
//
//   deno test --allow-env supabase/functions/tests/

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { capKey, cleanBrand, cleanGraphic, validateGraphics } from "../_shared/graphics.ts";

const STORAGE = "https://x.supabase.co/storage/v1/object/public/";
const SPONSOR = {
  campaignId: "c-1",
  name: "Acme Coffee",
  logoUrl: `${STORAGE}ad-creatives/a/logo-1.png`,
};
const opts = {
  imagePrefix: `${STORAGE}studio-graphics/`,
  avatarPrefix: STORAGE,
  slotIds: new Set(["s1", "s2"]),
  sponsor: SPONSOR,
};

Deno.test("brand: hex colours upper-cased, unknown fonts dropped, junk rejected", () => {
  assertEquals(cleanBrand({ accent: "#c8ff00", panel: "#18181b", text: "#ffffff", font: "Oswald" }), {
    accent: "#C8FF00", panel: "#18181B", text: "#FFFFFF", font: "Oswald",
  });
  assertEquals(cleanBrand({ accent: "#C8FF00", panel: "#18181B", text: "#FFFFFF", font: "Comic Sans" })?.font, undefined);
  assertEquals(cleanBrand({ accent: "red", panel: "#18181B", text: "#FFFFFF" }), null);
  assertEquals(cleanBrand({ accent: "#C8FF00", panel: "#18181B" }), null);
});

Deno.test("brand: rides along with the graphics state; a bad kit is just left off", () => {
  const ok = validateGraphics({ all: [], bySlot: {}, brand: { accent: "#112233", panel: "#000000", text: "#FFFFFF" } }, opts);
  assert("state" in ok);
  assertEquals(ok.state.brand?.accent, "#112233");
  const bad = validateGraphics({ all: [], bySlot: {}, brand: { accent: "nope" } }, opts);
  assert("state" in bad);
  assertEquals(bad.state.brand, undefined);
});

Deno.test("nileStyle opt-out survives on any graphic", () => {
  assertEquals(cleanGraphic({ id: "a", kind: "lower_third", title: "A", nileStyle: true }, opts)?.nileStyle, true);
  assertEquals(cleanGraphic({ id: "a", kind: "lower_third", title: "A", nileStyle: "yes" }, opts)?.nileStyle, undefined);
});

Deno.test("qr: https only, needs a corner, caption capped", () => {
  const g = cleanGraphic({ id: "q", kind: "qr", url: "https://joinnile.com/e/1", corner: "br", size: "l", caption: "Scan me" }, opts);
  assertEquals(g, { id: "q", kind: "qr", url: "https://joinnile.com/e/1", corner: "br", size: "l", caption: "Scan me" });
  assertEquals(cleanGraphic({ id: "q", kind: "qr", url: "http://joinnile.com", corner: "br" }, opts), null);
  assertEquals(cleanGraphic({ id: "q", kind: "qr", url: "javascript:alert(1)", corner: "br" }, opts), null);
  assertEquals(cleanGraphic({ id: "q", kind: "qr", url: "https://x.com" }, opts), null);
  assertEquals(cleanGraphic({ id: "q", kind: "qr", url: "https://x.com", corner: "tl", caption: "x".repeat(41) }, opts)?.caption, undefined);
});

Deno.test("qr: its own spot per corner — a logo in the same corner stays up", () => {
  const r = validateGraphics({
    all: [
      { id: "logo", kind: "logo", imageUrl: `${STORAGE}studio-graphics/u/l.png`, corner: "tr" },
      { id: "q", kind: "qr", url: "https://x.com", corner: "tr" },
    ],
    bySlot: {},
  }, opts);
  assert("state" in r);
  assertEquals(r.state.all.map((g) => g.id), ["logo", "q"]);
  assertEquals(capKey(r.state.all[1]), "qr:tr");
});

Deno.test("sponsor: image and name come from the campaign, never the Studio", () => {
  const g = cleanGraphic({
    id: "sponsor:c-1", kind: "sponsor", campaignId: "c-1", corner: "tl", size: "s",
    imageUrl: "https://evil.example/x.png", title: "Not Acme",
  }, opts);
  assertEquals(g, {
    id: "sponsor:c-1", kind: "sponsor", campaignId: "c-1", corner: "tl", size: "s",
    title: "Acme Coffee", imageUrl: SPONSOR.logoUrl,
  });
});

Deno.test("sponsor: another campaign, or no sponsor for the event, is dropped", () => {
  assertEquals(cleanGraphic({ id: "s", kind: "sponsor", campaignId: "c-2", corner: "tl" }, opts), null);
  assertEquals(cleanGraphic({ id: "s", kind: "sponsor", campaignId: "c-1", corner: "tl" }, { ...opts, sponsor: null }), null);
  assertEquals(cleanGraphic({ id: "s", kind: "sponsor", campaignId: "c-1" }, opts), null);
});

Deno.test("sponsor: no logo uploaded → a name-only badge", () => {
  const g = cleanGraphic({ id: "s", kind: "sponsor", campaignId: "c-1", corner: "bl" }, { ...opts, sponsor: { campaignId: "c-1", name: "Acme" } });
  assertEquals(g?.imageUrl, undefined);
  assertEquals(g?.title, "Acme");
});

Deno.test("sponsor: shares the logo spot in its corner", () => {
  const r = validateGraphics({
    all: [
      { id: "logo", kind: "logo", imageUrl: `${STORAGE}studio-graphics/u/l.png`, corner: "tr" },
      { id: "sponsor:c-1", kind: "sponsor", campaignId: "c-1", corner: "tr" },
    ],
    bySlot: {},
  }, opts);
  assert("state" in r);
  assertEquals(r.state.all.map((g) => g.id), ["sponsor:c-1"]);
});
