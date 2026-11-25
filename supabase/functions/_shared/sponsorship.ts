// Shared sponsorship-offer logic (host-approved offers, migrations 0095–0097).
//
// The accept path lives here because it has exactly two callers with identical
// money semantics: a host tapping Accept (respond-sponsorship-offer) and the
// auto-accept that fires the instant Nile clears an offer on an opted-in event
// (review-ad-campaign). Two copies of an off-session destination charge would
// be two places to get the split, the idempotency key and the decline
// classification subtly different — and only one of them would get fixed.

import Stripe from "https://esm.sh/stripe@14?target=deno";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
  httpClient: Stripe.createFetchHttpClient(),
});

// Advertiser-facing dashboard; also the recovery destination for a card that
// needs a second authentication attempt.
export function portalUrl() {
  const base = (Deno.env.get("AD_PORTAL_URL") ?? "https://ads.joinnile.com").replace(/\/$/, "");
  return `${base}/advertise/portal`;
}

export const PLATFORM_MIN_OFFER_CENTS = 2500;

// Every sponsorship email is a Django template in Klaviyo, and Django's filters
// are a bad place to turn 4500 into "$45" or an ISO timestamp into a date a
// person can read. Money and deadlines are formatted HERE, once, so a template
// author can only ever print the right thing. Raw values ride along under
// explicitly raw names (amount_cents, offer_expires_at_iso) for anything that
// needs to compute rather than display.

// Whole dollars read as whole dollars; cents only when there are cents.
export function dollars(cents: number): string {
  const d = Number(cents ?? 0) / 100;
  return Number.isInteger(d) ? `$${d.toFixed(0)}` : `$${d.toFixed(2)}`;
}

// "Aug 17, 2026, 4:00 AM UTC". UTC because these go to advertisers and hosts in
// unknown timezones, and a wrong local time is worse than an explicit one.
export function formatWhen(iso: string | null | undefined): string | null {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  return `${
    new Intl.DateTimeFormat("en-US", {
      timeZone: "UTC",
      month: "short",
      day: "numeric",
      year: "numeric",
      hour: "numeric",
      minute: "2-digit",
      hour12: true,
    }).format(d)
  } UTC`;
}

// Klaviyo server-side event — the only email channel these functions have.
// Env-gated on KLAVIYO_API_KEY (private pk_ key): no-ops cleanly when unset,
// same posture as the notify helpers in review-ad-campaign. Never throws: an
// email failure must never fail a settled charge.
export async function klaviyoEvent(
  metric: string,
  email: string | null | undefined,
  uniqueId: string,
  properties: Record<string, unknown>,
) {
  const key = Deno.env.get("KLAVIYO_API_KEY");
  if (!key || !email) return;
  try {
    const res = await fetch("https://a.klaviyo.com/api/events/", {
      method: "POST",
      headers: {
        Authorization: `Klaviyo-API-Key ${key}`,
        revision: "2024-10-15",
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify({
        data: {
          type: "event",
          attributes: {
            unique_id: uniqueId,
            properties: { dashboard_url: portalUrl(), ...properties },
            metric: { data: { type: "metric", attributes: { name: metric } } },
            profile: { data: { type: "profile", attributes: { email } } },
          },
        },
      }),
    });
    if (!res.ok) console.error(`klaviyo ${metric} failed:`, res.status, await res.text());
  } catch (err) {
    console.error(`klaviyo ${metric} error:`, err);
  }
}

// In-app + push notification to the host that a screened offer is waiting.
// Fires on CLEARANCE (Nile's policy screen passing), which is the first moment
// the host is allowed to see the creative.
//
// actor_id is NOT NULL and FKs to profiles, and an advertiser account has no
// profile row — so the host stands in as their own actor. Nothing renders the
// actor for this type; the app resolves the brand from entity_id (the campaign).
// Push delivery is free via the AFTER INSERT trigger on notifications.
// deno-lint-ignore no-explicit-any
export async function notifyHostOfferCleared(admin: any, campaignId: string) {
  try {
    const { data: c } = await admin
      .from("ad_campaigns")
      .select("id, events(host_id)")
      .eq("id", campaignId)
      .maybeSingle();
    const hostId = c?.events?.host_id as string | undefined;
    if (!hostId) return;

    const { data: enabled } = await admin.rpc("notif_enabled", {
      p_uid: hostId,
      p_type: "sponsorship_offer",
    });
    if (enabled === false) return; // fail-open: null/undefined still notifies

    const { error } = await admin.from("notifications").insert({
      recipient_id: hostId,
      actor_id: hostId,
      type: "sponsorship_offer",
      entity_id: campaignId,
    });
    if (error) console.error("sponsorship_offer notification failed:", error);
  } catch (err) {
    console.error("sponsorship_offer notification error:", err);
  }
}

// Decline codes worth a second attempt while the offer window is still open.
// insufficient_funds and generic_decline are here because the same card is
// routinely approved hours later; authentication_required means the 3DS we
// forced at setup didn't carry, and the advertiser can finish it themselves.
// Everything else — stolen_card, lost_card, do_not_honor, fraudulent,
// pickup_card — is the issuer saying "not this card, not ever".
const RECOVERABLE_DECLINE_CODES = new Set([
  "try_again_later",
  "processing_error",
  "insufficient_funds",
  "generic_decline",
]);

export type AcceptOutcome =
  | { result: "accepted" }
  | { result: "payment_pending"; decline_code: string }
  | { result: "rejected"; decline_code: string }
  | { result: "error"; error: string; status: number };

// Accept an offer: charge the saved card off-session as a Connect destination
// charge, freeze the split on the row, and decline the losing offers.
//
// Callers must have already authorised the actor. This re-reads the campaign
// itself so both callers get the same guards, and every write is status-guarded
// on 'pending_host' so a double-tap or a racing auto-accept can't charge twice.
// deno-lint-ignore no-explicit-any
export async function acceptSponsorshipOffer(
  admin: any,
  campaignId: string,
  opts: { note?: string | null; auto?: boolean } = {},
): Promise<AcceptOutcome> {
  const { data: c } = await admin
    .from("ad_campaigns")
    .select(
      "id, status, budget_cents, offer_expires_at, event_id, stripe_customer_id, " +
        "stripe_payment_method_id, advertiser_accounts(name, contact_email), " +
        "events(title, host_id)",
    )
    .eq("id", campaignId)
    .maybeSingle();
  if (!c) return { result: "error", error: "Campaign not found", status: 404 };
  if (c.status !== "pending_host") {
    return { result: "error", error: `Offer is ${c.status}, not awaiting a decision`, status: 409 };
  }
  if (c.offer_expires_at && new Date(c.offer_expires_at).getTime() < Date.now()) {
    return { result: "error", error: "This offer has expired", status: 409 };
  }
  if (!c.stripe_customer_id || !c.stripe_payment_method_id) {
    return { result: "error", error: "No saved card on this offer", status: 409 };
  }

  // Host must STILL be payable. charges_enabled can flip false between the
  // offer and the acceptance, and a destination charge into a disabled account
  // fails as an opaque API error rather than a decline we can explain.
  const hostId = c.events?.host_id as string | undefined;
  const { data: hostProfile } = await admin
    .from("profiles").select("stripe_account_id").eq("id", hostId ?? "").maybeSingle();
  const hostAccountId = hostProfile?.stripe_account_id as string | null;
  if (!hostAccountId) return { result: "error", error: "host_not_payable", status: 409 };
  const hostAccount = await stripe.accounts.retrieve(hostAccountId);
  if (!hostAccount.charges_enabled) return { result: "error", error: "host_not_payable", status: 409 };

  // The split is frozen HERE, not at offer time: config can be retuned between
  // an offer and its acceptance, and the number the host agreed to is the one
  // on screen at the moment they tap Accept.
  const { data: cfg } = await admin
    .from("app_config").select("sponsorship_host_share").eq("id", 1).maybeSingle();
  const hostShare = Number(cfg?.sponsorship_host_share ?? 0.70);
  const amount = Number(c.budget_cents);
  const fee = Math.round(amount * (1 - hostShare));
  const eventTitle = (c.events?.title as string | undefined) ?? "your event";
  const nowIso = new Date().toISOString();
  const note = typeof opts.note === "string" ? opts.note.trim().slice(0, 300) : "";

  let pi: Stripe.PaymentIntent;
  try {
    pi = await stripe.paymentIntents.create({
      amount,
      currency: "usd",
      customer: c.stripe_customer_id,
      payment_method: c.stripe_payment_method_id,
      off_session: true,
      confirm: true,
      application_fee_amount: fee,
      transfer_data: { destination: hostAccountId },
      description: `Nile sponsorship: ${eventTitle}`,
      metadata: { type: "sponsorship_accept", campaign_id: campaignId, event_id: c.event_id ?? "" },
    // Keyed on the campaign so a double-tapped Accept, or an auto-accept racing
    // a host tap, can only ever produce one charge. We never retry the charge
    // server-side, so replaying a cached decline inside the 24h key window is
    // the correct outcome rather than a hazard.
    }, { idempotencyKey: campaignId });
  } catch (err) {
    return await onChargeFailed(admin, c, err, {
      note, nowIso, eventTitle, amount, fee, hostAccountId,
    });
  }

  const { data: updated, error: updErr } = await admin
    .from("ad_campaigns")
    .update({
      status: "active",
      stripe_payment_intent_id: pi.id,
      application_fee_cents: fee,
      split_status: "split",
      host_note: note || null,
      host_decided_at: nowIso,
      auto_accepted: opts.auto === true,
      last_decline_code: null,
    })
    .eq("id", campaignId)
    .eq("status", "pending_host")
    .select("id")
    .maybeSingle();

  if (updErr || !updated) {
    // Either a sibling offer won the race — the partial unique index on
    // (event_id) where status in ('active','completed') rejects the second
    // winner with 23505 — or the row moved under us. The card is already
    // charged, so unwind it; an advertiser paying for a lobby they will never
    // appear in is the one outcome with no defence.
    console.error("accept update failed after charge:", campaignId, updErr);
    try {
      await stripe.refunds.create({
        payment_intent: pi.id,
        reverse_transfer: true,
        refund_application_fee: true,
      });
    } catch (refundErr) {
      console.error("REFUND FAILED — manual refund owed:", pi.id, refundErr);
    }
    return { result: "error", error: "This event already has a sponsor", status: 409 };
  }

  await declineSponsorshipSiblings(admin, campaignId, c.event_id, eventTitle, nowIso);
  await notifyHostSponsored(admin, hostId, eventTitle, c.advertiser_accounts?.name ?? "A sponsor", campaignId);
  await klaviyoEvent(
    "Nile Sponsorship Offer Accepted",
    c.advertiser_accounts?.contact_email,
    `${campaignId}:offer_accepted`,
    {
      brand: c.advertiser_accounts?.name ?? "there",
      event_title: eventTitle,
      amount: dollars(amount),
      amount_cents: amount,
      campaign_id: campaignId,
      host_note: note,
    },
  );
  return { result: "accepted" };
}

// Losing offers on the same event, once one of them has been paid for.
//
// payment_pending siblings are included: the unique index would stop such a
// sibling from becoming a second sponsor, but only AFTER its recovery Checkout
// Session took the advertiser's money — so the session is expired here too.
// Belt and braces, because the webhook's status guard is the other half.
// deno-lint-ignore no-explicit-any
export async function declineSponsorshipSiblings(
  admin: any, winnerId: string, eventId: string | null, eventTitle: string, nowIso: string,
) {
  if (!eventId) return;
  const autoNote = "The host chose another sponsor for this event.";
  const { data: losers, error } = await admin
    .from("ad_campaigns")
    .update({
      status: "declined",
      host_note: autoNote,
      host_decided_at: nowIso,
      payment_recovery_url: null,
    })
    .eq("event_id", eventId)
    .eq("placement", "lobby")
    .in("status", ["pending_host", "payment_pending"])
    .neq("id", winnerId)
    .select("id, budget_cents, stripe_payment_intent_id, advertiser_accounts(name, contact_email)");
  if (error) { console.error("sibling decline failed:", error); return; }
  // deno-lint-ignore no-explicit-any
  for (const l of (losers ?? []) as any[]) {
    await expireRecoverySession(l.stripe_payment_intent_id);
    await klaviyoEvent(
      "Nile Sponsorship Offer Declined",
      l.advertiser_accounts?.contact_email,
      `${l.id}:offer_declined`,
      {
        brand: l.advertiser_accounts?.name ?? "there",
        event_title: eventTitle,
        amount: dollars(l.budget_cents),
        amount_cents: l.budget_cents,
        campaign_id: l.id,
        host_note: autoNote,
      },
    );
  }
}

// Kill a payment-recovery Checkout Session so its URL — which is sitting in an
// advertiser's inbox — stops being payable. A payment_pending row stores the
// recovery SESSION id in stripe_payment_intent_id (the same "cs_ until the
// webhook overwrites it with the real pi_" convention create-ad-payment uses
// for the payment-mode paths), so the prefix is what tells them apart.
// Best-effort: Stripe refuses to expire a session that is already complete or
// expired, and that refusal is not an error worth surfacing.
export async function expireRecoverySession(sessionId: string | null | undefined) {
  if (!sessionId?.startsWith("cs_")) return;
  try {
    await stripe.checkout.sessions.expire(sessionId);
  } catch (err) {
    console.error("recovery session expire failed:", sessionId, err);
  }
}

// Off-session charge failed. Split by decline code: a card that might work in
// an hour keeps the offer alive (payment_pending, 6h fuse); a card the issuer
// has condemned lands in 'rejected' — which, deliberately, is the one status
// that does NOT burn one of the advertiser's three offers on this event.
// deno-lint-ignore no-explicit-any
async function onChargeFailed(
  admin: any,
  c: any,
  err: unknown,
  ctx: {
    note: string; nowIso: string; eventTitle: string;
    amount: number; fee: number; hostAccountId: string;
  },
): Promise<AcceptOutcome> {
  const { note, nowIso, eventTitle, amount, fee, hostAccountId } = ctx;
  const e = err as Stripe.errors.StripeError;
  const code = e?.code ?? "";
  const declineCode = e?.decline_code ?? "";
  const key = declineCode || code || "unknown";
  const recoverable = code === "authentication_required" ||
    (code === "card_declined" && RECOVERABLE_DECLINE_CODES.has(declineCode));

  console.error(JSON.stringify({
    level: "error",
    fn: "sponsorship-accept",
    note: "off-session charge failed",
    campaign_id: c.id,
    code,
    decline_code: declineCode,
    recoverable,
    message: e?.message ?? String(err),
  }));

  if (recoverable) {
    // Recovery is a fresh, HOSTED Checkout Session in payment mode. The failed
    // off-session PaymentIntent is abandoned deliberately: finishing it would
    // need Stripe.js and a client-side handleNextAction, and the advertiser
    // portal loads neither. Checkout owns the 3DS challenge, and completion
    // arrives back through the same webhook that handles every other session.
    let recovery: Stripe.Checkout.Session | null = null;
    try {
      recovery = await stripe.checkout.sessions.create({
        mode: "payment",
        customer: c.stripe_customer_id,
        line_items: [{
          price_data: {
            currency: "usd",
            unit_amount: amount,
            product_data: { name: `Sponsor “${eventTitle}”` },
          },
          quantity: 1,
        }],
        // Same destination charge the off-session attempt would have made —
        // the host's split must not change just because the card needed a
        // second try. fee is the one frozen at the host's decision.
        payment_intent_data: {
          application_fee_amount: fee,
          transfer_data: { destination: hostAccountId },
        },
        success_url: `${portalUrl()}?campaign_id=${c.id}&session_id={CHECKOUT_SESSION_ID}`,
        cancel_url: portalUrl(),
        metadata: {
          type: "ad_campaign",
          sponsorship_recovery: "1",
          campaign_id: c.id,
          fee_cents: String(fee),
        },
      });
    } catch (createErr) {
      console.error("recovery session create failed:", c.id, createErr);
    }

    await admin
      .from("ad_campaigns")
      .update({
        status: "payment_pending",
        last_decline_code: key,
        payment_retry_until: new Date(Date.now() + 6 * 3_600_000).toISOString(),
        payment_recovery_url: recovery?.url ?? null,
        // Session id, not a PaymentIntent — the webhook overwrites it with the
        // real pi_ on completion. Every downstream release/refund path guards
        // on the "pi_" prefix, so a cs_ here is inert.
        ...(recovery ? { stripe_payment_intent_id: recovery.id } : {}),
        host_note: note || null,
        host_decided_at: nowIso,
      })
      .eq("id", c.id)
      .eq("status", "pending_host");
    await klaviyoEvent(
      "Nile Sponsorship Payment Action Needed",
      c.advertiser_accounts?.contact_email,
      `${c.id}:payment_action_needed`,
      {
        brand: c.advertiser_accounts?.name ?? "there",
        event_title: eventTitle,
        amount: dollars(amount),
        amount_cents: amount,
        campaign_id: c.id,
        decline_code: key,
        confirm_url: recovery?.url ?? portalUrl(),
      },
    );
    return { result: "payment_pending", decline_code: key };
  }

  const reason = `Your card was declined (${key}) and this sponsorship could not be completed. You were not charged.`;
  await admin
    .from("ad_campaigns")
    .update({
      status: "rejected",
      last_decline_code: key,
      review_note: reason,
      host_decided_at: nowIso,
    })
    .eq("id", c.id)
    .eq("status", "pending_host");
  // Reuses the existing "Nile Ad Rejected" flow — it already carries a reason
  // string, so a hard decline needs no new Klaviyo flow.
  await klaviyoEvent("Nile Ad Rejected", c.advertiser_accounts?.contact_email, `${c.id}:hard_decline`, {
    brand: c.advertiser_accounts?.name ?? "there",
    headline: `Sponsorship: ${eventTitle}`,
    campaign_id: c.id,
    reason,
  });
  return { result: "rejected", decline_code: key };
}

// Host email on ACCEPTANCE (it used to fire on Nile's clearance, which was
// before any money moved and before the host had agreed to anything).
// deno-lint-ignore no-explicit-any
async function notifyHostSponsored(
  admin: any, hostId: string | undefined, eventTitle: string, brand: string, campaignId: string,
) {
  try {
    if (!hostId) return;
    const { data: userData } = await admin.auth.admin.getUserById(hostId);
    await klaviyoEvent(
      "Nile Event Sponsored",
      userData?.user?.email as string | undefined,
      `${campaignId}:host_sponsored`,
      { brand, event_title: eventTitle, campaign_id: campaignId },
    );
  } catch (err) {
    console.error("host sponsored notify error:", err);
  }
}
