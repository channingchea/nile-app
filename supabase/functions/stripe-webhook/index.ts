// Supabase Edge Function: stripe-webhook
//
// Setup:
//   supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_...
//   supabase secrets set ADMIN_ALERT_EMAIL=you@joinnile.com   (Part 2: review-needed alert; also read by tally-ad-spend)
//   supabase functions deploy stripe-webhook --no-verify-jwt
//
// IMPORTANT: deploy with --no-verify-jwt. Stripe signs with the webhook
// secret, not a Supabase JWT — with JWT verification on, Supabase's gateway
// rejects every delivery with 401 UNAUTHORIZED_NO_AUTH_HEADER before this
// function runs. Auth is still enforced via constructEventAsync (the
// signature check below). This applies ONLY to the webhook; stripe-connect
// and refund-ticket DO need JWT verification (they read the user's session).
//
// In Stripe Dashboard → Webhooks → Add endpoint:
//   URL: https://<project>.supabase.co/functions/v1/stripe-webhook
//   Events: checkout.session.completed, charge.refunded,
//           charge.dispute.created, charge.dispute.closed,
//           checkout.session.expired, checkout.session.async_payment_failed
//
// ── Delivery semantics (review #19) ─────────────────────────────────────────
// Stripe delivers at LEAST once. Every event is claimed against
// stripe_webhook_events (migration 0112) before any work happens and marked
// processed after, so a redelivery of an event we already finished is acked and
// dropped. This is not belt-and-braces on top of the per-handler status guards:
// onSponsorshipPaymentRecovered interprets "my status guard matched nothing" as
// "the lobby slot is gone" and REFUNDS, so on a replay it clawed back a live
// sponsorship and reversed the host's transfer. The dedupe plus the re-read in
// that function are the two halves of that fix.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14?target=deno";
import {
  declineSponsorshipSiblings,
  notifyHostOfferCleared,
} from "../_shared/sponsorship.ts";
import { ejectFromLiveRoom } from "../_shared/livekit_eject.ts";
import { failure } from "../_shared/errors.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
  httpClient: Stripe.createFetchHttpClient(),
});

const adminClient = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

const ok = (extra: Record<string, unknown> = {}) =>
  new Response(JSON.stringify({ received: true, ...extra }), {
    headers: { "Content-Type": "application/json" },
  });

serve(async (req) => {
  const body = await req.text();
  const sig = req.headers.get("stripe-signature");
  const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, sig!, webhookSecret);
  } catch (err) {
    return new Response(`Webhook error: ${err}`, { status: 400 });
  }

  // ── dedupe gate (0112) ─────────────────────────────────────────────────────
  // Claim before any work. A claim that is already finished is a replay: ack it
  // and stop. A claim held by a delivery still in flight gets a 5xx so Stripe
  // redelivers rather than considering the event handled by a request that may
  // yet fail. A claim RPC that errors is also a 5xx — if the database is
  // unreachable, nothing downstream would have worked anyway.
  const { data: claim, error: claimErr } = await adminClient.rpc(
    "claim_stripe_webhook_event",
    { p_event_id: event.id, p_type: event.type },
  );
  if (claimErr) {
    console.error("claim_stripe_webhook_event failed:", claimErr.message);
    return new Response(JSON.stringify({ error: "claim failed" }), { status: 500 });
  }
  if (claim === "duplicate") {
    console.log(JSON.stringify({
      level: "info", fn: "stripe-webhook", note: "duplicate delivery ignored",
      event: event.id, type: event.type,
    }));
    return ok({ duplicate: true });
  }
  if (claim === "in_flight") {
    return new Response(JSON.stringify({ error: "already processing" }), { status: 409 });
  }

  // Any throw leaves the claim unfinished, which is deliberate: an unfinished
  // claim is retryable (0112 reclaims it after 5 minutes) where a completed one
  // is not.
  let res: Response;
  try {
    res = await handleEvent(event);
  } catch (err) {
    console.error("unhandled webhook error:", event.id, event.type, err);
    return new Response(JSON.stringify(failure(err, "stripe-webhook")), { status: 500 });
  }

  // Only a success closes the claim. The ticket branch returns 500 on purpose
  // when settlement fails — the buyer has paid and holds nothing until it
  // succeeds — and that retry has to stay live.
  if (res.status < 300) {
    const { error } = await adminClient.rpc("complete_stripe_webhook_event", {
      p_event_id: event.id,
    });
    if (error) console.error("complete_stripe_webhook_event failed:", error.message);
  }
  return res;
});

async function handleEvent(event: Stripe.Event): Promise<Response> {
  if (event.type === "checkout.session.completed") {
    const session = event.data.object as Stripe.Checkout.Session;
    const piId = (session.payment_intent as string) ?? session.id;

    // Ad-platform campaign: advertiser paid. Branched by create-ad-payment's
    // metadata.type so it never collides with ticket sales.
    //   standalone:"1" (A-4 external creative ad) → pending_review: checkout only
    //     AUTHORIZED the card (manual capture); admin approval (review-ad-campaign
    //     fn) captures the PaymentIntent and does the final → active, rejection
    //     cancels the authorization.
    //   otherwise (A-2 host boost) → active immediately (automatic capture).
    //   mode:"setup" (0095 sponsorship offer) → no money moved at all; see
    //     onSponsorshipCardSaved below.
    // Status guard: only transition rows still in pending_payment, so a replayed
    // or late Stripe event can never flip an already-reviewed (rejected/active/
    // paused) campaign back.
    if (session.metadata?.type === "ad_campaign") {
      const campaignId = session.metadata.campaign_id;
      if (campaignId && session.metadata.sponsorship_recovery === "1") {
        // A payment_pending offer's advertiser just paid through the hosted
        // recovery session. Checked before the mode branches: this is a
        // payment-mode session, but it must NOT take the generic path.
        await onSponsorshipPaymentRecovered(session, campaignId, piId);
      } else if (campaignId && session.mode === "setup") {
        // Sponsorship OFFER (0095–0097): checkout saved a card and nothing
        // else. Separate branch because there is no PaymentIntent to record and
        // the next status depends on the advertiser's trust tier.
        await onSponsorshipCardSaved(session, campaignId);
      } else if (campaignId) {
        const nextStatus =
          session.metadata.standalone === "1" ? "pending_review" : "active";
        const { data: updatedCampaign } = await adminClient
          .from("ad_campaigns")
          .update({ status: nextStatus, stripe_payment_intent_id: piId })
          .eq("id", campaignId)
          .eq("status", "pending_payment")
          .select("advertiser_accounts(name), ad_creatives(headline)")
          .maybeSingle();

        // New-submission admin alert (Part 2 of the hardening plan). Only
        // fires on a real pending_payment→pending_review transition — the
        // status guard above returns no row on a replay, so this can't
        // double-fire; the Klaviyo unique_id below is a second backstop.
        if (updatedCampaign && nextStatus === "pending_review") {
          await notifyAdminNeedsReview(
            campaignId,
            (updatedCampaign as any).advertiser_accounts?.name ?? "Unknown",
            (updatedCampaign as any).ad_creatives?.[0]?.headline ?? "Untitled ad",
          );
        }
      }
    } else if (session.metadata?.type === "tip") {
      // Tip completed (atomic Connect split already settled by Stripe). Flip the
      // pending ledger row to paid; the status guard makes replays idempotent.
      // The pending row was keyed on session.id (PI was null at create time).
      const { data: tip } = await adminClient
        .from("tips")
        .update({ status: "paid", stripe_payment_intent_id: piId })
        .eq("stripe_payment_intent_id", session.id)
        .eq("status", "pending")
        .select("host_id, tipper_id, event_id, amount_cents")
        .maybeSingle();

      // Announce it in the live chat, from here (review E1 + E10).
      //
      // The tipper's client used to do this on app-resume: a CANCELLED tip
      // re-announced their PREVIOUS tip (it just read the latest paid one), and
      // a tip that settled after they closed the screen was never announced at
      // all. Doing it on settlement is the only moment that's actually true.
      // It also means clients no longer need — and no longer have — the ability
      // to author a system message, which is what made the announcement style
      // forgeable by anyone in the room.
      if (tip) await announceTip(adminClient, tip);

      // Notify the host (only on a real transition, so replays don't re-notify).
      // Gated by the host's tip_received preference (fail-open); push delivery is
      // free via the phase-20 AFTER INSERT trigger on notifications.
      if (tip) {
        const { data: enabled } = await adminClient.rpc("notif_enabled", {
          p_uid: tip.host_id,
          p_type: "tip_received",
        });
        if (enabled !== false) {
          await adminClient.from("notifications").insert({
            recipient_id: tip.host_id,
            actor_id: tip.tipper_id,
            type: "tip_received",
            entity_id: tip.event_id,
          });
        }
      }
    } else {
      // Ticket sale (default). Settles through the ticket_checkouts ledger
      // (migration 0092/0093) rather than by rewriting the tickets row:
      //
      //  - it resolves by SESSION id, so a buyer who opened checkout twice and
      //    completed the first tab is still found (the old flow overwrote
      //    stripe_payment_intent_id and matched zero rows — card charged,
      //    ticket stuck pending forever);
      //  - it re-checks capacity under a row lock, so the last seat can only be
      //    sold once no matter how many people paid for it simultaneously;
      //  - it never erases a refund, because the refund lives in the ledger.
      const { data: outcome, error: settleErr } = await adminClient.rpc(
        "settle_ticket_checkout",
        { p_session_id: session.id, p_payment_intent_id: piId },
      );

      if (settleErr) {
        // Returning 500 makes Stripe retry, which is what we want: the buyer has
        // paid and holds no ticket until this succeeds.
        console.error("settle_ticket_checkout failed:", settleErr.message);
        return new Response(JSON.stringify({ error: settleErr.message }), {
          status: 500,
          headers: { "Content-Type": "application/json" },
        });
      }

      if (outcome === "oversold") {
        // Someone else took the last seat while this payment was in flight.
        // Refund immediately — holding money for a seat that doesn't exist is
        // the one outcome nobody can defend.
        try {
          await stripe.refunds.create({ payment_intent: piId });
          console.log(JSON.stringify({
            level: "warn", fn: "stripe-webhook", note: "oversold — refunded",
            session: session.id, payment_intent: piId,
          }));
        } catch (err) {
          console.error("oversold refund FAILED — manual refund owed:", piId, err);
        }
      } else if (outcome === "not_found") {
        console.error("no ticket_checkouts row for session", session.id);
      }
    }
  }

  if (event.type === "charge.refunded") {
    const charge = event.data.object as Stripe.Charge;
    const paymentIntentId = charge.payment_intent as string;
    if (paymentIntentId) {
      // Ticket sale refund (original path). FULL refunds only — `charge.refunded`
      // is Stripe's "nothing left on this charge" flag, and it is false for a
      // partial refund. Without this guard a $5 goodwill refund on a $20 ticket
      // revoked live + replay access mid-show and zeroed the host's $20. The tip
      // and ad branches below always had the guard; the ticket branch didn't.
      if (charge.refunded) {
        // Marks BOTH the ledger row and the entitlement (migration 0093), so
        // the refund survives a later replay purchase by the same buyer.
        await adminClient.rpc("refund_ticket_checkout", {
          p_payment_intent_id: paymentIntentId,
        });
      } else {
        // Partial refund: the buyer keeps their access and the host keeps the
        // remainder. Logged because nothing else records that it happened.
        console.log(JSON.stringify({
          level: "info",
          fn: "stripe-webhook",
          note: "partial refund — ticket access left intact",
          payment_intent: paymentIntentId,
          amount_refunded: charge.amount_refunded,
          amount: charge.amount,
        }));
      }

      // Tip refund (out-of-band dashboard refund). A destination-charge refund
      // also reverses the transfer, so keep host earnings honest by marking the
      // ledger row. Only full refunds; only a currently-paid tip.
      if (charge.refunded) {
        await adminClient
          .from("tips")
          .update({ status: "refunded" })
          .eq("stripe_payment_intent_id", paymentIntentId)
          .eq("status", "paid");
      }

      // Ad campaign refund (review finding #5): a refund issued from the Stripe
      // dashboard must also pull the campaign. Only FULL refunds (charge.refunded
      // = true) and only campaigns in a pullable state — pending_payment rows have
      // no captured charge, and rejected/completed are already terminal. The
      // normal reject path (cancel the manual-capture hold) emits no
      // charge.refunded, so this only catches out-of-band dashboard refunds.
      //
      // The new offer statuses are safe to leave out of this list: an offer only
      // acquires a real PaymentIntent at acceptance, so pending_review /
      // pending_host rows can never match a payment_intent_id at all, and a
      // payment_pending row's intent was never captured.
      if (charge.refunded) {
        await adminClient
          .from("ad_campaigns")
          .update({ status: "rejected" })
          .eq("stripe_payment_intent_id", paymentIntentId)
          .in("status", ["pending_review", "active", "paused"]);
      }
    }
  }

  // ── chargebacks (review #18) ───────────────────────────────────────────────
  // A dispute pulls the money AND a non-refundable fee out of the platform
  // balance the moment it is filed. Until now nothing here noticed: the buyer
  // kept live + replay access, the sponsor kept serving in the lobby, the
  // advertiser kept their trusted tier, and the host kept a destination
  // transfer funded by money that had already left. open_payment_dispute
  // (migration 0113) resolves the charge to whatever it bought, revokes it, and
  // records the exposure; everything below is the part that lives outside
  // Postgres.
  if (event.type === "charge.dispute.created") {
    const dispute = event.data.object as Stripe.Dispute;
    const { data: result, error } = await adminClient.rpc("open_payment_dispute", {
      p_dispute_id: dispute.id,
      p_charge_id: idOf(dispute.charge),
      p_payment_intent: idOf(dispute.payment_intent),
      p_amount_cents: dispute.amount ?? 0,
      p_reason: dispute.reason ?? null,
      p_status: dispute.status,
    });
    if (error) {
      // Retry rather than lose it: a dispute nobody records is a dispute
      // nobody answers, and the response window is days.
      console.error("open_payment_dispute failed:", dispute.id, error.message);
      return new Response(JSON.stringify({ error: error.message }), { status: 500 });
    }

    // deno-lint-ignore no-explicit-any
    const r = (result ?? {}) as any;
    if (!r.duplicate) {
      // Same posture as a refund mid-show: revoking access is only real if the
      // viewer actually leaves. The gate runs once, at token mint.
      if (r.kind === "ticket" && r.event_live) {
        await ejectFromLiveRoom(r.livekit_room ?? null, r.payer_id ?? null, "stripe-webhook");
      }
      console.log(JSON.stringify({
        level: "warn", fn: "stripe-webhook", note: "dispute opened",
        dispute: dispute.id, kind: r.kind, subject: r.subject_id,
        revoked: r.revoked, exposure_cents: r.exposure_cents,
        amount_cents: dispute.amount, reason: dispute.reason,
      }));
      await notifyAdminDispute(dispute, r, "opened");
    }
  }

  if (event.type === "charge.dispute.closed") {
    const dispute = event.data.object as Stripe.Dispute;
    // Stripe's closing statuses are won / lost / warning_closed. Only the first
    // two decide anything; an inquiry that closed without escalating leaves the
    // ledger row closed with no outcome.
    const outcome = dispute.status === "won" || dispute.status === "lost"
      ? dispute.status
      : null;
    const { data: result, error } = await adminClient.rpc("close_payment_dispute", {
      p_dispute_id: dispute.id,
      p_status: dispute.status,
      p_outcome: outcome,
    });
    if (error) {
      console.error("close_payment_dispute failed:", dispute.id, error.message);
      return new Response(JSON.stringify({ error: error.message }), { status: 500 });
    }
    console.log(JSON.stringify({
      level: "info", fn: "stripe-webhook", note: "dispute closed",
      dispute: dispute.id, status: dispute.status, result,
    }));
    // deno-lint-ignore no-explicit-any
    await notifyAdminDispute(dispute, (result ?? {}) as any, "closed");
  }

  // ── checkout died without paying ───────────────────────────────────────────
  // expire-abandoned-ticket-checkouts (cron, hourly) already sweeps these up,
  // but a held seat is the difference between "sold out" and a sale, so free it
  // the moment Stripe says the session is dead rather than up to an hour later.
  if (
    event.type === "checkout.session.expired" ||
    event.type === "checkout.session.async_payment_failed"
  ) {
    const session = event.data.object as Stripe.Checkout.Session;
    const { data: released } = await adminClient
      .from("ticket_checkouts")
      .update({
        status: "abandoned",
        settled_at: new Date().toISOString(),
        note: `stripe ${event.type}`,
      })
      .eq("session_id", session.id)
      .eq("status", "pending")
      .select("id")
      .maybeSingle();
    if (released) {
      console.log(JSON.stringify({
        level: "info", fn: "stripe-webhook", note: "seat released",
        session: session.id, type: event.type,
      }));
    }
  }

  return ok();
}

// Stripe hands these back as either a bare id or an expanded object.
function idOf(v: unknown): string | null {
  if (typeof v === "string") return v;
  // deno-lint-ignore no-explicit-any
  return (v as any)?.id ?? null;
}

// A payment_pending sponsorship recovered: the advertiser completed the hosted
// Checkout Session we created when their card soft-declined off-session. Money
// has ALREADY moved by the time this runs, so every failure below has to end in
// a refund — an advertiser paying for a lobby slot that is gone is the one
// outcome with no defence (same posture as the oversold-ticket refund above).
//
// The fee travels in session metadata rather than being recomputed: config can
// be retuned between the host's decision and the advertiser's second attempt,
// and the split the host agreed to is the one that must settle.
async function onSponsorshipPaymentRecovered(
  session: Stripe.Checkout.Session,
  campaignId: string,
  piId: string,
) {
  const fee = Number(session.metadata?.fee_cents ?? "");
  const { data: recovered, error } = await adminClient
    .from("ad_campaigns")
    .update({
      status: "active",
      stripe_payment_intent_id: piId,
      ...(Number.isFinite(fee) ? { application_fee_cents: fee } : {}),
      split_status: "split",
      payment_recovery_url: null,
      payment_retry_until: null,
    })
    .eq("id", campaignId)
    .eq("status", "payment_pending")
    .select("id, event_id, events(title)")
    .maybeSingle();

  // "No row" used to be read as one thing — this slot is gone — and answered
  // with a refund. It is actually three things, and only two of them are
  // that. Re-read before touching the money (review #19):
  //
  //   1. THIS payment already landed on an earlier delivery of this same
  //      event. Refunding here reverses a live sponsorship and claws back the
  //      host's transfer while the ad keeps serving. The PI on the row is the
  //      tell — if it is ours, the money is where it belongs.
  //   2. The offer left payment_pending (swept as expired, or declined because
  //      a sibling was accepted).
  //   3. The partial unique index rejected the write because another campaign
  //      is already this event's active sponsor.
  //
  // 0112's dedupe catches most of case 1 on its own. This check also covers
  // the case the dedupe cannot see: two DIFFERENT Stripe events for the same
  // recovered payment.
  if (error || !recovered) {
    const { data: current } = await adminClient
      .from("ad_campaigns")
      .select("id, status, stripe_payment_intent_id")
      .eq("id", campaignId)
      .maybeSingle();

    if (current?.stripe_payment_intent_id === piId) {
      console.log(JSON.stringify({
        level: "info",
        fn: "stripe-webhook",
        note: "sponsorship recovery already applied — not refunding",
        campaign_id: campaignId,
        payment_intent: piId,
        status: current?.status ?? null,
      }));
      return;
    }

    console.error(JSON.stringify({
      level: "error",
      fn: "stripe-webhook",
      note: "sponsorship recovery landed on a slot that was gone — refunding",
      campaign_id: campaignId,
      payment_intent: piId,
      error: error?.message ?? null,
    }));
    try {
      await stripe.refunds.create({
        payment_intent: piId,
        reverse_transfer: true,
        refund_application_fee: true,
      });
    } catch (refundErr) {
      console.error("RECOVERY REFUND FAILED — manual refund owed:", piId, refundErr);
    }
    return;
  }

  // This campaign is now the sponsor, so the offers it beat have to be told —
  // the losing side was never decided when the original charge soft-declined.
  // deno-lint-ignore no-explicit-any
  const title = (recovered as any).events?.title ?? "your event";
  await declineSponsorshipSiblings(
    adminClient,
    campaignId,
    // deno-lint-ignore no-explicit-any
    (recovered as any).event_id ?? null,
    title,
    new Date().toISOString(),
  );
}

// Sponsorship offer: the advertiser finished the setup-mode Checkout Session,
// so a card is now on file. Persist the payment method (the SetupIntent is the
// only place it exists — the Session doesn't carry it) and move the offer on.
//
// Trusted advertisers skip Nile's blocking queue and go straight in front of
// the host. That tier is earned by one approved creative and lost by one upheld
// report (moderate-report), and it exists because a 72h fuse can't afford to
// wait on a human for a brand we've already cleared once.
//
// Status-guarded on pending_payment, so a replayed delivery can't drag an
// already-decided offer backwards.
async function onSponsorshipCardSaved(session: Stripe.Checkout.Session, campaignId: string) {
  const setupIntentId = typeof session.setup_intent === "string"
    ? session.setup_intent
    : session.setup_intent?.id;
  if (!setupIntentId) {
    console.error("setup-mode session with no setup_intent:", session.id);
    return;
  }
  const si = await stripe.setupIntents.retrieve(setupIntentId);
  const paymentMethodId = typeof si.payment_method === "string"
    ? si.payment_method
    : si.payment_method?.id;
  if (!paymentMethodId) {
    console.error("SetupIntent has no payment method:", setupIntentId);
    return;
  }
  const customerId = (typeof session.customer === "string" ? session.customer : session.customer?.id) ??
    (typeof si.customer === "string" ? si.customer : si.customer?.id) ?? null;

  const { data: campaign } = await adminClient
    .from("ad_campaigns")
    .select("id, advertiser_accounts(name, trust_tier), ad_creatives(headline)")
    .eq("id", campaignId)
    .maybeSingle();
  // deno-lint-ignore no-explicit-any
  const acct = (campaign as any)?.advertiser_accounts;
  const trusted = acct?.trust_tier === "trusted";

  const { data: updated } = await adminClient
    .from("ad_campaigns")
    .update({
      status: trusted ? "pending_host" : "pending_review",
      stripe_payment_method_id: paymentMethodId,
      ...(customerId ? { stripe_customer_id: customerId } : {}),
    })
    .eq("id", campaignId)
    .eq("status", "pending_payment")
    .select("id")
    .maybeSingle();
  if (!updated) return; // replay, or the offer already moved on

  if (trusted) {
    // Straight to the host — and no "needs review" alert, since there is
    // nothing blocking. The spot-check list (Phase 5) is where admins see it.
    await notifyHostOfferCleared(adminClient, campaignId);
    return;
  }
  await notifyAdminNeedsReview(
    campaignId,
    acct?.name ?? "Unknown",
    // deno-lint-ignore no-explicit-any
    (campaign as any)?.ad_creatives?.[0]?.headline ?? "Untitled sponsorship",
  );
}

// Broadcast "@someone tipped $20 🎉" onto the event's read-only announcement
// topic. Clients may subscribe to live_system:<slug> but have no INSERT grant
// on it (migration 0099), so this is the only way such a message can exist.
// Never throws: an announcement is not worth failing a settled payment over.
// deno-lint-ignore no-explicit-any
async function announceTip(admin: any, tip: any) {
  try {
    const [{ data: event }, { data: tipper }] = await Promise.all([
      admin.from("events").select("livekit_room").eq("id", tip.event_id).maybeSingle(),
      admin.from("profiles").select("username").eq("id", tip.tipper_id).maybeSingle(),
    ]);
    const slug = event?.livekit_room as string | undefined;
    if (!slug) return;

    const cents = Number(tip.amount_cents ?? 0);
    if (!cents) return;
    const dollars = cents / 100;
    const amount = Number.isInteger(dollars)
      ? `$${dollars.toFixed(0)}`
      : `$${dollars.toFixed(2)}`;
    const who = tipper?.username ? `@${tipper.username}` : "Someone";

    const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/realtime/v1/api/broadcast`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
        Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!}`,
      },
      body: JSON.stringify({
        messages: [
          {
            topic: `live_system:${slug}`,
            event: "msg",
            private: true,
            payload: {
              sender_id: tip.tipper_id,
              username: "",
              content: `${who} tipped ${amount} 🎉`,
              sent_at: new Date().toISOString(),
              kind: "system",
            },
          },
        ],
      }),
    });
    if (!res.ok) console.error("tip announce failed:", res.status, await res.text());
  } catch (err) {
    console.error("tip announce error:", err);
  }
}

// Admin alert: a chargeback was filed, or one closed. Same env-gated Klaviyo
// posture as notifyAdminNeedsReview — no-ops when KLAVIYO_API_KEY or
// ADMIN_ALERT_EMAIL is unset, and never throws. This one matters more than the
// review alert: the money is already gone, the evidence window is measured in
// days, and Stripe's own email goes to whoever owns the Stripe login rather
// than to whoever can pull the ticket, the stream logs, and the chat record.
// unique_id keys on dispute id + phase, so redelivery can't double-send.
async function notifyAdminDispute(
  dispute: Stripe.Dispute,
  // deno-lint-ignore no-explicit-any
  result: any,
  phase: "opened" | "closed",
) {
  const key = Deno.env.get("KLAVIYO_API_KEY");
  const adminEmail = Deno.env.get("ADMIN_ALERT_EMAIL");
  if (!key || !adminEmail) return;
  const payload = {
    data: {
      type: "event",
      attributes: {
        unique_id: `${dispute.id}:${phase}`,
        properties: {
          phase,
          dispute_id: dispute.id,
          kind: result?.kind ?? "unknown",
          subject_id: result?.subject_id ?? null,
          host_id: result?.host_id ?? null,
          amount_cents: dispute.amount ?? 0,
          exposure_cents: result?.exposure_cents ?? 0,
          reason: dispute.reason ?? null,
          status: dispute.status,
          revoked: result?.revoked ?? false,
          restored: result?.restored ?? false,
          due_by: dispute.evidence_details?.due_by ?? null,
          stripe_url: `https://dashboard.stripe.com/disputes/${dispute.id}`,
        },
        metric: { data: { type: "metric", attributes: { name: "Nile Payment Dispute" } } },
        profile: { data: { type: "profile", attributes: { email: adminEmail } } },
      },
    },
  };
  try {
    const res = await fetch("https://a.klaviyo.com/api/events/", {
      method: "POST",
      headers: {
        Authorization: `Klaviyo-API-Key ${key}`,
        revision: "2024-10-15",
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(payload),
    });
    if (!res.ok) console.error("dispute alert failed:", res.status, await res.text());
  } catch (err) {
    console.error("dispute alert error:", err);
  }
}

// Admin alert: a paid standalone ad just entered pending_review (Part 2 of
// the hardening plan — the Stripe auth window is only ~7 days, so a silent
// submission is a real risk). Env-gated on KLAVIYO_API_KEY + ADMIN_ALERT_EMAIL:
// no-ops cleanly when either is unset, same posture as notifyAdvertiser in
// review-ad-campaign. Fires "Nile Ad Needs Review"; a Klaviyo flow owns the
// actual email. unique_id keys on campaign_id so this can never double-send.
// Never throws.
async function notifyAdminNeedsReview(campaignId: string, brand: string, headline: string) {
  const key = Deno.env.get("KLAVIYO_API_KEY");
  const adminEmail = Deno.env.get("ADMIN_ALERT_EMAIL");
  if (!key || !adminEmail) return;
  const payload = {
    data: {
      type: "event",
      attributes: {
        unique_id: `${campaignId}:needs_review`,
        properties: {
          brand,
          headline,
          campaign_id: campaignId,
          portal_url: "https://ads.joinnile.com/advertise/portal?view=review",
        },
        metric: { data: { type: "metric", attributes: { name: "Nile Ad Needs Review" } } },
        profile: { data: { type: "profile", attributes: { email: adminEmail } } },
      },
    },
  };
  try {
    const res = await fetch("https://a.klaviyo.com/api/events/", {
      method: "POST",
      headers: {
        Authorization: `Klaviyo-API-Key ${key}`,
        revision: "2024-10-15",
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(payload),
    });
    if (!res.ok) console.error("admin needs-review event failed:", res.status, await res.text());
  } catch (err) {
    console.error("admin needs-review event error:", err);
  }
}
