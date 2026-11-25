// Month-end cross-check of Nile's app store tickets against Apple's own sales
// report (docs/plans/apple-iap-tickets.md, Phase 5). Pure helpers — the
// apple-payouts function does the fetching.

import { BUNDLE_ID } from "./apple_iap.ts";

/** UTC instants of the first moment of [month] and of the next month, in
 *  Pacific time — the clock Apple's reports use. month = "2026-11". */
export function pacificMonthRange(month: string): { from: Date; to: Date } {
  const [y, m] = month.split("-").map(Number);
  const midnight = (year: number, mon: number) => {
    for (const h of [8, 7]) { // PST, then PDT
      const d = new Date(Date.UTC(year, mon - 1, 1, h));
      const hour = new Intl.DateTimeFormat("en-US", {
        timeZone: "America/Los_Angeles", hour: "numeric", hourCycle: "h23",
      }).format(d);
      if (Number(hour) === 0) return d;
    }
    throw new Error(`no Pacific midnight for ${year}-${mon}`);
  };
  return { from: midnight(y, m), to: m === 12 ? midnight(y + 1, 1) : midnight(y, m + 1) };
}

/** The month before [now], as "YYYY-MM" (in Pacific time). */
export function previousMonth(now = new Date()): string {
  const [y, m] = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Los_Angeles", year: "numeric", month: "2-digit",
  }).format(now).split("-").map(Number);
  return m === 1 ? `${y - 1}-12` : `${y}-${String(m - 1).padStart(2, "0")}`;
}

/** Net units per show product in Apple's Sales SUMMARY report (TSV). Refunds
 *  appear as negative units. */
export function appleUnitsBySku(tsv: string): Map<string, number> {
  const [head, ...lines] = tsv.trim().split(/\r?\n/);
  const cols = head.split("\t");
  const sku = cols.indexOf("SKU"), units = cols.indexOf("Units");
  if (sku < 0 || units < 0) throw new Error("unexpected sales report columns");
  const out = new Map<string, number>();
  for (const line of lines) {
    const f = line.split("\t");
    const id = f[sku]?.trim();
    if (!id?.startsWith(`${BUNDLE_ID}.ppv.`)) continue;
    out.set(id, (out.get(id) ?? 0) + Number(f[units] ?? 0));
  }
  return out;
}

export interface NileStoreTicket {
  store_price_cents: number;
  paid_at: string | null;
  refunded_at: string | null;
}

/** Nile's net units per product for the month: sales paid in it, minus
 *  refunds that landed in it — the same way Apple counts. */
export function nileUnitsBySku(rows: NileStoreTicket[], from: Date, to: Date): Map<string, number> {
  const inMonth = (s: string | null) => s !== null && new Date(s) >= from && new Date(s) < to;
  const out = new Map<string, number>();
  for (const r of rows) {
    const id = `${BUNDLE_ID}.ppv.${String(r.store_price_cents).padStart(4, "0")}`;
    const n = (inMonth(r.paid_at) ? 1 : 0) - (inMonth(r.refunded_at) ? 1 : 0);
    if (n) out.set(id, (out.get(id) ?? 0) + n);
  }
  return out;
}

export function compareUnits(apple: Map<string, number>, nile: Map<string, number>) {
  const ids = [...new Set([...apple.keys(), ...nile.keys()])].sort();
  const mismatches = ids
    .map((sku) => ({ sku, apple: apple.get(sku) ?? 0, nile: nile.get(sku) ?? 0 }))
    .filter((r) => r.apple !== r.nile);
  const sum = (m: Map<string, number>) => [...m.values()].reduce((a, b) => a + b, 0);
  return { appleUnits: sum(apple), nileUnits: sum(nile), mismatches };
}

/** App Store Connect API token (ES256), from the .p8 key's PEM text. */
export async function ascToken(keyId: string, issuer: string, p8: string): Promise<string> {
  const der = Uint8Array.from(
    atob(p8.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")),
    (c) => c.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey(
    "pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
  );
  const enc = (o: unknown) =>
    btoa(JSON.stringify(o)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const now = Math.floor(Date.now() / 1000);
  const input = `${enc({ alg: "ES256", kid: keyId, typ: "JWT" })}.${
    enc({ iss: issuer, iat: now, exp: now + 600, aud: "appstoreconnect-v1" })
  }`;
  const sig = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input)),
  );
  return `${input}.${btoa(String.fromCharCode(...sig)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")}`;
}
