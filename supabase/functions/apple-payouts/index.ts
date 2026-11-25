// Supabase Edge Function: apple-payouts (docs/plans/apple-iap-tickets.md, Phase 5)
//
// Runs on the 28th (cron below). Two jobs, in order:
//   1. Cross-check last month: Apple's Sales report vs Nile's app store
//      tickets, per product. The result (and any mismatches) is written to
//      apple_reconciliations for the admin portal. Never blocks payouts.
//   2. Pay hosts: one Stripe transfer per host with the host's share of app
//      store tickets for shows that took place, minus app store refunds after
//      an earlier payout. The transfer lands in the host's Stripe balance and
//      goes to their bank with the regular month-end payout (anchor 31).
//      Nothing is sent when the net is ≤ 0 or the host can't be paid — it rolls
//      to next month.
//
// Needs (supabase secrets set …): STRIPE_SECRET_KEY, CRON_SHARED_SECRET, and
// for the cross-check ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY (.p8 text),
// ASC_VENDOR_NUMBER (App Store Connect → Payments and Financial Reports).
// Transfers draw on Nile's Stripe balance, so it must hold enough USD.
//
// Deploy: npx -y supabase@latest functions deploy apple-payouts --no-verify-jwt --project-ref jelmkkvyrliywcdkzhuu
// Request: POST, header x-cron-secret; body { "dry_run": true } reports
// without sending anything.
//
// CRON (28th, 16:10 UTC):
//   select cron.schedule('apple-payouts', '10 16 28 * *', $$
//     select net.http_post(
//       url     := 'https://jelmkkvyrliywcdkzhuu.functions.supabase.co/apple-payouts',
//       headers := jsonb_build_object('Content-Type', 'application/json',
//         'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets
//                           where name = 'cron_shared_secret')));
//   $$);

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14?target=deno";
import { CURRENCY } from "../_shared/money.ts";
import {
  appleUnitsBySku, ascToken, compareUnits, nileUnitsBySku, type NileStoreTicket,
  pacificMonthRange, previousMonth,
} from "../_shared/apple_payouts.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
  httpClient: Stripe.createFetchHttpClient(),
});
const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);
const log = (note: string, extra: Record<string, unknown> = {}) =>
  console.log(JSON.stringify({ fn: "apple-payouts", note, ...extra }));

async function appleReport(month: string): Promise<string> {
  const env = (k: string) => Deno.env.get(k) ?? "";
  if (!env("ASC_KEY_ID") || !env("ASC_PRIVATE_KEY") || !env("ASC_VENDOR_NUMBER")) {
    throw new Error("not configured: set ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY, ASC_VENDOR_NUMBER");
  }
  const q = new URLSearchParams({
    "filter[frequency]": "MONTHLY",
    "filter[reportType]": "SALES",
    "filter[reportSubType]": "SUMMARY",
    "filter[vendorNumber]": env("ASC_VENDOR_NUMBER"),
    "filter[reportDate]": month,
    "filter[version]": "1_1",
  });
  const res = await fetch(`https://api.appstoreconnect.apple.com/v1/salesReports?${q}`, {
    headers: {
      Authorization: `Bearer ${await ascToken(env("ASC_KEY_ID"), env("ASC_ISSUER_ID"), env("ASC_PRIVATE_KEY"))}`,
      Accept: "application/a-gzip",
    },
  });
  // 404 = "There were no sales for the date specified."
  if (res.status === 404) return "SKU\tUnits\n";
  if (!res.ok) throw new Error(`salesReports ${res.status}: ${(await res.text()).slice(0, 300)}`);
  return await new Response(res.body!.pipeThrough(new DecompressionStream("gzip"))).text();
}

async function crossCheck(month: string) {
  const { from, to } = pacificMonthRange(month);
  const row: Record<string, unknown> = { month: `${month}-01`, checked_at: new Date().toISOString() };
  try {
    const { data, error } = await admin
      .from("tickets")
      .select("store_price_cents, paid_at, refunded_at")
      .eq("payment_provider", "apple")
      .eq("apple_environment", "Production")
      .or(`and(paid_at.gte.${from.toISOString()},paid_at.lt.${to.toISOString()}),` +
        `and(refunded_at.gte.${from.toISOString()},refunded_at.lt.${to.toISOString()})`);
    if (error) throw new Error(error.message);
    const result = compareUnits(
      appleUnitsBySku(await appleReport(month)),
      nileUnitsBySku((data ?? []) as NileStoreTicket[], from, to),
    );
    Object.assign(row, {
      apple_units: result.appleUnits, nile_units: result.nileUnits,
      mismatches: result.mismatches, error: null,
    });
  } catch (e) {
    row.error = String((e as Error).message ?? e);
  }
  await admin.from("apple_reconciliations").upsert(row);
  log("cross-check", row);
  return row;
}

async function payHosts(month: string, dryRun: boolean) {
  const { data: batches, error } = await admin.rpc("apple_payout_claim", { p_month: month });
  if (error) throw new Error(`apple_payout_claim: ${error.message}`);
  const results = [];
  for (const b of batches ?? []) {
    const net = Number(b.pay_cents) - Number(b.clawback_cents);
    const base = { host: b.host_id, pay: Number(b.pay_cents), clawback: Number(b.clawback_cents), net };
    if (dryRun || net <= 0 || !b.stripe_account_id) {
      await admin.rpc("apple_payout_release", { p_key: b.key });
      results.push({ ...base, sent: false, reason: dryRun ? "dry_run" : net <= 0 ? "net_not_positive" : "no_account" });
      continue;
    }
    try {
      // A run that stopped after Stripe accepted the transfer but before it was
      // recorded: find that transfer instead of sending a second one
      // (idempotency keys only last 24 hours; the transfer group doesn't expire).
      const prior = (await stripe.transfers.list({ transfer_group: b.key, limit: 1 })).data[0];
      const transfer = prior ?? await stripe.transfers.create(
        {
          amount: net,
          transfer_group: b.key,
          currency: CURRENCY,
          destination: b.stripe_account_id,
          description: `Nile app store ticket sales (${month})`,
          metadata: { type: "apple_iap_payout", key: b.key, host_id: b.host_id, month, pay_cents: String(b.pay_cents), clawback_cents: String(b.clawback_cents) },
        },
        { idempotencyKey: b.key },
      );
      const { error: doneErr } = await admin.rpc("apple_payout_complete", { p_key: b.key, p_transfer_id: transfer.id });
      // Left claimed on failure: the re-run repeats the same transfer request
      // and Stripe's idempotency key returns this transfer, not a second one.
      if (doneErr) throw new Error(`apple_payout_complete: ${doneErr.message}`);
      results.push({ ...base, sent: true, transfer: transfer.id });
    } catch (e) {
      const msg = String((e as Error).message ?? e);
      // Stripe refused (balance short, account restricted): nothing moved, so
      // roll the rows to next month.
      if ((e as { type?: string }).type?.startsWith("Stripe")) {
        await admin.rpc("apple_payout_release", { p_key: b.key });
      }
      results.push({ ...base, sent: false, reason: msg });
    }
  }
  log("payouts", { month, dryRun, results });
  return results;
}

serve(async (req) => {
  const expected = Deno.env.get("CRON_SHARED_SECRET");
  if (!expected || req.headers.get("x-cron-secret") !== expected) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
  }
  try {
    const { dry_run } = await req.json().catch(() => ({}));
    const now = new Date();
    const thisMonth = new Intl.DateTimeFormat("en-CA", {
      timeZone: "America/Los_Angeles", year: "numeric", month: "2-digit",
    }).format(now).slice(0, 7);
    const check = await crossCheck(previousMonth(now));
    const payouts = await payHosts(thisMonth, dry_run === true);
    return new Response(JSON.stringify({ check, payouts }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error(e);
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});
