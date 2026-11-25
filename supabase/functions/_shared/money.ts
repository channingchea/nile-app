// Currency, tax and the refund policy we are obliged to state before payment.
// (P4 #37 from the 2026-08-16 platform review.)
//
// One module because the six Stripe call sites each hardcoded "usd" and none
// of them said so to the buyer, and because a refund policy that lives in two
// places drifts into two policies.

// Every amount Nile creates is in this currency. That is a real product
// decision, not an oversight — but it has to be *visible*: a viewer in London
// buying a UK host's stream pays US dollars and their bank adds the FX spread.
// The app and the web both render prices as "$12.00 USD" for this reason.
export const CURRENCY = "usd";

// ── Stripe Tax ──────────────────────────────────────────────────────────────
// OFF until the platform account's tax settings are active. Right now
// tax.settings.status is 'pending' with head_office missing, and enabling
// automatic_tax against a pending account makes every Checkout Session
// creation throw — which is every ticket, tip and ad purchase on the platform.
// Turn on with:  supabase secrets set STRIPE_TAX_ENABLED=true
export const TAX_ENABLED = Deno.env.get("STRIPE_TAX_ENABLED") === "true";

// INCLUSIVE, deliberately, and this one matters.
//
// Tickets and sponsorships are destination charges: the connected account
// receives (amount - application_fee_amount), and application_fee_amount is
// fixed when the session is created — before Checkout has collected the
// buyer's address, therefore before Stripe knows the tax. With EXCLUSIVE tax
// the total grows by the tax and that growth lands in the transfer, so Nile
// would be paying sales tax out to hosts as if it were revenue.
//
// Inclusive tax carves the tax out of the quoted price instead: the buyer pays
// exactly the number they were shown, the host's share is unchanged, and the
// platform commission absorbs the tax. Margin cost, not a correctness cost.
const TAX_BEHAVIOR = "inclusive" as const;

/** Session-level tax switch. Spread into checkout.sessions.create(). */
export const taxParams = () => (TAX_ENABLED ? { automatic_tax: { enabled: true } } : {});

/** Line-item tax behaviour. Spread into price_data. */
export const priceTaxParams = () => (TAX_ENABLED ? { tax_behavior: TAX_BEHAVIOR } : {});

// ── Disclosure ──────────────────────────────────────────────────────────────
// Stripe renders custom_text.submit.message directly above the pay button, so
// this is the last thing a buyer reads before the charge. That is the only
// placement that satisfies "disclosed before payment" no matter which surface
// sent them here — app, web, or a shared link.

/** Hours before an event starts during which a ticket can still be cancelled. */
export const TICKET_REFUND_WINDOW_HOURS = 24;

export const TICKET_REFUND_POLICY =
  `Cancel up to ${TICKET_REFUND_WINDOW_HOURS} hours before the event starts for a full refund. ` +
  "After that all sales are final — except that you're refunded automatically and in full if " +
  "the host cancels, never goes live, or removes the event. " +
  "Charged in US dollars; your bank may add a foreign transaction fee.";

// A tip is a gratuity, not a purchase of anything — there is no delivery to
// fail and nothing to hand back. Saying so plainly beats a silent "final".
export const TIP_REFUND_POLICY =
  "Tips are voluntary and final — they go to the creator, not to Nile. " +
  "Charged in US dollars; your bank may add a foreign transaction fee.";

export const AD_REFUND_POLICY =
  "You can stop a campaign at any time from your portal; undelivered budget is " +
  "refunded automatically. Charged in US dollars.";
