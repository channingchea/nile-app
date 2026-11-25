// Month-end cross-check helpers (_shared/apple_payouts.ts), Phase 5.
//
//   deno test --allow-env supabase/functions/tests/apple_payouts_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  appleUnitsBySku, compareUnits, nileUnitsBySku, pacificMonthRange, previousMonth,
} from "../_shared/apple_payouts.ts";

const P = "com.nilestreaming.app.ppv.";

Deno.test("Pacific month boundaries, both sides of daylight saving", () => {
  assertEquals(pacificMonthRange("2026-11").from.toISOString(), "2026-11-01T07:00:00.000Z"); // PDT
  assertEquals(pacificMonthRange("2026-11").to.toISOString(), "2026-12-01T08:00:00.000Z"); // PST
  assertEquals(pacificMonthRange("2026-12").to.toISOString(), "2027-01-01T08:00:00.000Z");
});

Deno.test("previous month in Pacific time", () => {
  assertEquals(previousMonth(new Date("2026-11-28T16:10:00Z")), "2026-10");
  assertEquals(previousMonth(new Date("2027-01-28T16:10:00Z")), "2026-12");
  // 1 Dec 05:00 UTC is still 30 Nov in California.
  assertEquals(previousMonth(new Date("2026-12-01T05:00:00Z")), "2026-10");
});

Deno.test("Apple's report: show products only, refunds net off", () => {
  const tsv = [
    "Provider\tSKU\tUnits\tProduct Type Identifier",
    `APPLE\t${P}1499\t3\tIA1`,
    `APPLE\t${P}1499\t-1\tIA1`,
    `APPLE\t${P}0499\t2\tIA1`,
    "APPLE\tcom.nilestreaming.app\t40\t1F", // app downloads
  ].join("\n");
  const m = appleUnitsBySku(tsv);
  assertEquals(m.get(`${P}1499`), 2);
  assertEquals(m.get(`${P}0499`), 2);
  assertEquals(m.size, 2);
});

Deno.test("Nile's side counts sales and refunds by the month they happened", () => {
  const { from, to } = pacificMonthRange("2026-11");
  const rows = [
    { store_price_cents: 1499, paid_at: "2026-11-10T00:00:00Z", refunded_at: null },
    { store_price_cents: 1499, paid_at: "2026-11-11T00:00:00Z", refunded_at: "2026-11-12T00:00:00Z" },
    { store_price_cents: 1499, paid_at: "2026-10-30T00:00:00Z", refunded_at: "2026-11-02T00:00:00Z" },
    { store_price_cents: 499, paid_at: "2026-11-01T06:59:00Z", refunded_at: null }, // still October in PT
  ];
  const m = nileUnitsBySku(rows, from, to);
  assertEquals(m.get(`${P}1499`), 0);
  assertEquals(m.has(`${P}0499`), false);
});

Deno.test("mismatches name the product and both counts", () => {
  const r = compareUnits(new Map([[`${P}1499`, 2], [`${P}0499`, 1]]), new Map([[`${P}1499`, 2]]));
  assertEquals(r, { appleUnits: 3, nileUnits: 2, mismatches: [{ sku: `${P}0499`, apple: 1, nile: 0 }] });
});
