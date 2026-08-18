// P4 #44. The money module is small, but every constant in it is a promise
// made to a buyer above Stripe's pay button, and the tax switch decides
// whether sales tax gets paid out to hosts as if it were revenue.
//
//   deno test --allow-env supabase/functions/tests/

import {
  assert,
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  AD_REFUND_POLICY,
  CURRENCY,
  priceTaxParams,
  taxParams,
  TICKET_REFUND_POLICY,
  TICKET_REFUND_WINDOW_HOURS,
  TIP_REFUND_POLICY,
} from "../_shared/money.ts";

Deno.test("the stated policy quotes the window the code enforces", () => {
  // refund-ticket refuses a buyer cancellation inside this window. If the
  // sentence and the number ever disagree we are advertising a refund we
  // won't honour.
  assertStringIncludes(
    TICKET_REFUND_POLICY,
    `${TICKET_REFUND_WINDOW_HOURS} hours`,
  );
});

Deno.test("every policy names the currency", () => {
  // The whole reason #37 existed: a buyer in London pays US dollars and their
  // bank adds the FX spread, and nothing said so.
  for (const policy of [TICKET_REFUND_POLICY, TIP_REFUND_POLICY, AD_REFUND_POLICY]) {
    assertStringIncludes(policy, "US dollars");
  }
  assertEquals(CURRENCY, "usd");
});

Deno.test("policies fit inside Stripe's custom_text limit", () => {
  // custom_text.submit.message is capped at 1200 characters; going over
  // doesn't truncate, it rejects the session — i.e. no purchases at all.
  for (const policy of [TICKET_REFUND_POLICY, TIP_REFUND_POLICY, AD_REFUND_POLICY]) {
    assert(policy.length <= 1200, `too long (${policy.length}): ${policy.slice(0, 60)}…`);
  }
});

Deno.test("tip policy does not promise a refund", () => {
  // A tip is a gratuity — there is no delivery to fail. Saying "refund"
  // anywhere in this string would be a promise we don't keep.
  assert(!/refund/i.test(TIP_REFUND_POLICY), TIP_REFUND_POLICY);
  assertStringIncludes(TIP_REFUND_POLICY, "final");
});

Deno.test("tax is off unless STRIPE_TAX_ENABLED is exactly 'true'", () => {
  // These read the env at MODULE LOAD, so this test documents the shipped
  // state rather than re-reading. Enabling tax against the account's current
  // 'pending' status makes every Checkout Session creation throw — which is
  // every ticket, tip and ad purchase on the platform.
  const enabled = Deno.env.get("STRIPE_TAX_ENABLED") === "true";
  assertEquals(Object.keys(taxParams()).length, enabled ? 1 : 0);
  assertEquals(Object.keys(priceTaxParams()).length, enabled ? 1 : 0);
});

Deno.test("when tax IS on, the behaviour is inclusive", () => {
  // Load-bearing. Tickets and sponsorships are destination charges: the host
  // receives (amount - application_fee_amount), and the fee is fixed before
  // Checkout knows the buyer's address. With EXCLUSIVE tax the total grows by
  // the tax and that growth lands in the transfer — Nile would pay sales tax
  // out to creators. Read the source so the assertion holds regardless of the
  // env this test runs under.
  const src = Deno.readTextFileSync(
    new URL("../_shared/money.ts", import.meta.url),
  );
  assertStringIncludes(src, 'const TAX_BEHAVIOR = "inclusive"');
});
