// Supabase Edge Function: review-ad-campaign
//
// Admin actions on ad campaigns (A-4 Part 3). Caller must be in the `admins`
// table (migration 0032). Standalone checkout authorizes only (manual capture,
// see create-ad-payment), so money moves HERE, on approval — and never moves at
// all for rejects.
//
//   { campaign_id, action: "approve" | "reject" | "pause" | "resume" | "withdraw",
//     note? }   — note: optional rejection reason (reject only, shown to advertiser)
//
//   approve  pending_review → active. Captures the PaymentIntent, then resets
//            starts_at/ends_at to NOW + the originally purchased duration —
//            the flight clock starts at activation, not checkout, so the brand
//            gets the full window they paid for.
//            LOBBY SPONSORSHIPS (0095–0097) are different: approve is a POLICY
//            CLEARANCE, not a purchase. The target is pending_host, no Stripe
//            call happens, and the host owns the money decision from there
//            (respond-sponsorship-offer). The action vocabulary is unchanged —
//            the portal still sends approve/reject — only the destination is.
//   reject   pending_review → rejected. Cancels the uncaptured authorization
//            (refunds instead if a legacy pre-manual-capture payment was
//            already captured). No out-of-band refund runbook needed. Lobby
//            rejects touch Stripe not at all: there is no hold to release, only
//            a saved card that is simply never used.
//            The advertiser's clearance email is "Offer Cleared", not
//            "Ad Approved" — nothing is booked until the host says yes.
//   withdraw OWNER action (not admin-gated): the advertiser pulls their own
//            campaign before it goes live. Feed/currents ads are hard-deleted
//            from pending_review (cancelling the authorization first) or
//            rejected (hold already released). LOBBY offers in pending_review /
//            pending_host are instead RETIRED IN PLACE to 'expired' — the row
//            is what the 3-offer cap counts, so deleting it would let an
//            advertiser reset their own counter. A lobby offer that has already
//            been decided (declined / expired) is refused outright; a rejected
//            one is still hard-deleted, since 'rejected' is excluded from the
//            cap everywhere. Either way the creative assets are best-effort
//            removed from the ad-creatives / ad-videos buckets.
//   pause    active → paused.   (no Stripe involvement; flight dates unchanged)
//   resume   paused → active.
//
// Deploy: supabase functions deploy review-ad-campaign   (KEEP JWT on)

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14?target=deno";
import { corsHeaders as corsHeadersFor } from "../_shared/cors.ts";
import {
  acceptSponsorshipOffer,
  dollars,
  notifyHostOfferCleared,
  PLATFORM_MIN_OFFER_CENTS,
} from "../_shared/sponsorship.ts";

// CORS headers are per-request, so the JSON responder is built per-request too
// and handed to the helpers below (they run outside the handler's scope).
type Json = (body: unknown, status?: number) => Response;
const makeJson = (cors: Record<string, string>): Json =>
  (body, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
  httpClient: Stripe.createFetchHttpClient(),
});

// action → { from: required current status, to: next status }
const TRANSITIONS: Record<string, { from: string; to: string }> = {
  approve: { from: "pending_review", to: "active" },
  reject:  { from: "pending_review", to: "rejected" },
  pause:   { from: "active",         to: "paused" },
  resume:  { from: "paused",         to: "active" },
};

serve(async (req) => {
  // Per-request CORS (fix #4): allowlisted origins only — see _shared/cors.ts.
  const corsHeaders = corsHeadersFor(req);
  const json = makeJson(corsHeaders);
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Missing Authorization header" }, 401);

    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );
    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) return json({ error: "Unauthorized" }, 401);

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const { campaign_id, action, note } = await req.json();

    // withdraw is owner-gated (advertiser deletes their own unapproved ad);
    // everything else stays admins-only.
    if (action === "withdraw") {
      return await withdraw(admin, user.id, campaign_id, json);
    }

    // Admin gate — service-role read of the admins table (RLS-independent).
    const { data: adminRow } = await admin
      .from("admins").select("user_id").eq("user_id", user.id).maybeSingle();
    if (!adminRow) return json({ error: "Admins only" }, 403);

    const t = TRANSITIONS[action];
    if (!campaign_id || !t) return json({ error: "Invalid campaign_id or action" }, 400);

    const { data: c } = await admin
      .from("ad_campaigns")
      .select("id, name, status, starts_at, ends_at, stripe_payment_intent_id, placement, split_status, budget_cents, advertiser_account_id, advertiser_accounts(name, contact_email), ad_creatives(headline), events(title, host_id, sponsorship_auto_accept, sponsorship_min_offer_cents)")
      .eq("id", campaign_id)
      .maybeSingle();
    if (!c) return json({ error: "Campaign not found" }, 404);
    if (c.status !== t.from) {
      return json({ error: `Campaign is ${c.status}, expected ${t.from}` }, 409);
    }

    // Lobby approve clears the offer for the host instead of buying it, so the
    // DB target differs from the action table even though the action doesn't.
    // deno-lint-ignore no-explicit-any
    const isLobby = (c as any).placement === "lobby";
    const target = action === "approve" && isLobby ? "pending_host" : t.to;

    // ── Stripe: money moves only on approve/reject, and never for lobby ─────
    const piId = c.stripe_payment_intent_id ?? "";
    const hasPi = piId.startsWith("pi_"); // webhook stored the real PI on payment

    if (action === "approve" && !isLobby) {
      if (!hasPi) return json({ error: "No PaymentIntent on campaign — was it paid?" }, 409);
      const pi = await stripe.paymentIntents.retrieve(piId);
      if (pi.status === "requires_capture") {
        try {
          await stripe.paymentIntents.capture(piId);
        } catch (err) {
          // Most likely the ~7-day auth window expired. Nothing was charged;
          // the brand must check out again.
          return json({ error: `Capture failed (authorization likely expired): ${err}` }, 409);
        }
      } else if (pi.status !== "succeeded") {
        return json({ error: `PaymentIntent not capturable (status ${pi.status})` }, 409);
      }
      // pi.status === "succeeded" ⇒ legacy auto-capture payment; nothing to do.
    }

    if (action === "reject" && !isLobby && hasPi) {
      await releaseHold(piId, (c as any).split_status === "split");
    }

    // ── DB transition (status-guarded against races) ────────────────────────
    const update: Record<string, string> = { status: target };
    if (action === "reject") {
      // Optional reason, shown to the advertiser on their dashboard.
      const trimmed = typeof note === "string" ? note.trim().slice(0, 300) : "";
      if (trimmed) update.review_note = trimmed;
    }
    if (action === "approve" && !isLobby) {
      // Flight clock starts at activation: preserve the purchased duration but
      // shift the window to now (fixes daily-burn accruing before serving).
      // Lobby sponsorships skip this: the event's schedule is the flight.
      const durationMs =
        new Date(c.ends_at).getTime() - new Date(c.starts_at).getTime();
      const now = new Date();
      update.starts_at = now.toISOString();
      update.ends_at = new Date(now.getTime() + durationMs).toISOString();
    }

    const { data: updated, error: updErr } = await admin
      .from("ad_campaigns")
      .update(update)
      .eq("id", campaign_id)
      .eq("status", t.from)
      .select("id, status, starts_at, ends_at")
      .single();
    if (updErr || !updated) return json({ error: "Update failed (status changed concurrently?)" }, 409);

    // Permanent audit trail (fire-and-forget; never fails the action).
    await logAudit(admin, {
      campaign_id,
      campaign_name: (c as any).name ?? null,
      actor: user.id,
      action,
      note: update.review_note ?? null,
    });

    // Advertiser notification (approve/reject only; host boosts have no account).
    // Fire-and-forget: a send failure must never fail the review action.
    if (action === "approve" || action === "reject") {
      const acct = (c as any).advertiser_accounts;
      const to = acct?.contact_email as string | undefined;
      if (to) {
        await notifyAdvertiser(
          action, to, acct?.name ?? "there",
          (c as any).ad_creatives?.[0]?.headline ?? "your ad",
          campaign_id, update.review_note,
          isLobby
            ? {
              eventTitle: (c as any).events?.title ?? "an event",
              amountCents: Number((c as any).budget_cents ?? 0),
            }
            : null,
        );
      }
    }

    // Lobby clearance: hand the offer to the host. The "your event has a
    // sponsor" email no longer fires here — nothing has been bought yet — it
    // moved to acceptance in _shared/sponsorship.ts.
    if (action === "approve" && isLobby) {
      // Trust is earned by one creative getting through us; from here this
      // advertiser's lobby offers skip the blocking queue. moderate-report
      // takes it straight back on an upheld report.
      await promoteTrust(admin, (c as any).advertiser_account_id);

      // Opted-in hosts get the offer taken off their hands immediately. If it
      // lands anywhere other than pending_host there is nothing left to notify
      // the host about — the accept path already emailed the outcome.
      const decided = await maybeAutoAccept(admin, campaign_id, (c as any).events, (c as any).budget_cents);
      if (!decided) await notifyHostOfferCleared(admin, campaign_id);
    }

    return json({ campaign: updated });
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});

// Advertiser notification on approve/reject via a Klaviyo server-side event.
// Env-gated on KLAVIYO_API_KEY (private pk_ key): no-ops cleanly when unset.
// Fires the metric "Nile Ad Approved" / "Nile Ad Rejected" against the
// advertiser's email profile; two Klaviyo flows (one per metric) own the
// actual email + template. Never throws — all failures are logged only.
async function notifyAdvertiser(
  action: "approve" | "reject",
  to: string,
  brand: string,
  headline: string,
  campaignId: string,
  note?: string,
  // Non-null ⇒ lobby sponsorship; carries what a sponsorship email renders
  // that an ad email doesn't.
  lobby: { eventTitle: string; amountCents: number } | null = null,
) {
  const key = Deno.env.get("KLAVIYO_API_KEY");
  if (!key) return;
  // A cleared sponsorship is not an approved ad: nothing is booked and nothing
  // is charged until the host says yes, and "Your ad is live" copy here would
  // be a lie the advertiser finds out about later.
  const metric = action === "reject"
    ? "Nile Ad Rejected"
    : lobby
    ? "Nile Sponsorship Offer Cleared"
    : "Nile Ad Approved";
  const payload = {
    data: {
      type: "event",
      attributes: {
        // Stable id so a retried review action can't double-fire the flow.
        unique_id: `${campaignId}:${action}`,
        properties: {
          brand,
          headline,
          campaign_id: campaignId,
          // Money is formatted at the source: Klaviyo templates are Django,
          // and "$45" is not something a Django filter should be deriving.
          ...(lobby
            ? {
              event_title: lobby.eventTitle,
              amount: dollars(lobby.amountCents),
              amount_cents: lobby.amountCents,
            }
            : {}),
          ...(action === "reject" ? { reason: note ?? "" } : {}),
          dashboard_url: "https://ads.joinnile.com/advertise/portal",
        },
        metric: { data: { type: "metric", attributes: { name: metric } } },
        profile: { data: { type: "profile", attributes: { email: to } } },
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
    if (!res.ok) console.error("advertiser event failed:", res.status, await res.text());
  } catch (err) {
    console.error("advertiser event error:", err);
  }
}

// Permanent record of a review action. Written with the service role (RLS on
// ad_admin_audit only grants reads). Fire-and-forget: an insert failure is
// logged but never fails the action — same posture as the Klaviyo notify.
// deno-lint-ignore no-explicit-any
async function logAudit(admin: any, row: {
  campaign_id: string;
  campaign_name: string | null;
  actor: string;
  action: string;
  note: string | null;
}) {
  try {
    const { error } = await admin.from("ad_admin_audit").insert(row);
    if (error) console.error("audit insert failed:", error);
  } catch (err) {
    console.error("audit insert error:", err);
  }
}

// Release an authorization: cancel if still a hold, refund if a legacy
// pre-manual-capture payment already moved money. Split payments (lobby
// sponsorships — Connect destination charges) must also pull the host's
// transfer back and return the platform fee.
async function releaseHold(piId: string, isSplit = false) {
  const pi = await stripe.paymentIntents.retrieve(piId);
  if (pi.status === "requires_capture") {
    await stripe.paymentIntents.cancel(piId); // releases the hold, no charge
  } else if (pi.status === "succeeded") {
    await stripe.refunds.create(
      isSplit
        ? { payment_intent: piId, reverse_transfer: true, refund_application_fee: true }
        : { payment_intent: piId },
    );
  }
}

// First lobby clearance promotes the advertiser to the trusted tier: their
// future sponsorship creatives go straight to the host and land in the admin
// spot-check list instead of blocking on it. Guarded on trust_tier='new' so a
// later re-approval can't quietly undo a moderate-report demotion in the same
// breath it was applied. Fire-and-forget.
// deno-lint-ignore no-explicit-any
async function promoteTrust(admin: any, advertiserAccountId: string | null) {
  if (!advertiserAccountId) return;
  const { error } = await admin
    .from("advertiser_accounts")
    .update({ trust_tier: "trusted", trusted_at: new Date().toISOString() })
    .eq("id", advertiserAccountId)
    .eq("trust_tier", "new");
  if (error) console.error("trust promotion failed:", error);
}

// Auto-accept on behalf of a host who opted in and set a number they're happy
// with. Returns true when the offer has left pending_host — accepted, parked in
// payment_pending, or hard-declined — so the caller knows not to also tell the
// host an offer is waiting. First cleared offer wins; the partial unique index
// on the event settles any race with a competing acceptance.
// deno-lint-ignore no-explicit-any
async function maybeAutoAccept(admin: any, campaignId: string, ev: any, budgetCents: number) {
  if (!ev?.sponsorship_auto_accept) return false;
  const { data: cfg } = await admin
    .from("app_config").select("sponsorship_min_offer_cents").eq("id", 1).maybeSingle();
  const floor = Math.max(
    Number(ev.sponsorship_min_offer_cents ?? 0),
    Number(cfg?.sponsorship_min_offer_cents ?? PLATFORM_MIN_OFFER_CENTS),
  );
  if (Number(budgetCents) < floor) return false;

  const outcome = await acceptSponsorshipOffer(admin, campaignId, { auto: true });
  if (outcome.result === "error") {
    console.error("auto-accept failed:", campaignId, outcome.error);
    return false; // leave it with the host to decide by hand
  }
  return true;
}

// Feed/currents ads: unchanged — nothing counts them, so deleting the row costs
// nothing. Lobby offers are different, because the row IS the offer cap. A
// withdrawn offer is retired in place (→ expired) rather than deleted, so an
// advertiser at 3-of-3 can't clear the counter and come back for a fourth bite.
// 'rejected' is the exception: it is already excluded from the cap everywhere,
// so deleting one changes nothing that anything reads.
const WITHDRAWABLE = new Set(["pending_review", "rejected"]);
const WITHDRAWABLE_LOBBY = new Set(["pending_review", "pending_host", "rejected"]);

// Owner withdrawal of a campaign that never went live.
// deno-lint-ignore no-explicit-any
async function withdraw(admin: any, userId: string, campaignId: string, json: Json) {
  if (!campaignId) return json({ error: "Invalid campaign_id" }, 400);

  const { data: c } = await admin
    .from("ad_campaigns")
    .select("id, name, status, placement, stripe_payment_intent_id, advertiser_account_id, split_status, ad_creatives(image_url, kind, video_path, thumb_path)")
    .eq("id", campaignId)
    .maybeSingle();
  if (!c) return json({ error: "Campaign not found" }, 404);

  // Owner gate: caller must own the advertiser account on the campaign.
  const { data: owner } = await admin
    .from("advertiser_accounts")
    .select("id")
    .eq("id", c.advertiser_account_id ?? "00000000-0000-0000-0000-000000000000")
    .eq("auth_user_id", userId)
    .maybeSingle();
  if (!owner) return json({ error: "Not your campaign" }, 403);

  const isLobby = c.placement === "lobby";
  if (isLobby && (c.status === "declined" || c.status === "expired")) {
    return json({ error: "A decided offer can't be withdrawn" }, 409);
  }
  if (!(isLobby ? WITHDRAWABLE_LOBBY : WITHDRAWABLE).has(c.status)) {
    return json({ error: `Campaign is ${c.status} — only ads that never went live can be withdrawn` }, 409);
  }

  const creative = c.ad_creatives?.[0];
  const imageUrl: string | undefined = creative?.image_url;
  const videoPaths: string[] = [creative?.video_path, creative?.thumb_path]
    .filter((p: unknown): p is string => typeof p === "string" && p.length > 0);

  // Live lobby offer: retire the row, keep the evidence. host_decided_at stays
  // null — no host ever ruled on this one, and the dashboard reads that field
  // to tell "the host said no" apart from "the brand walked away".
  const softWithdraw = isLobby && c.status !== "rejected";
  if (softWithdraw) {
    const { data: retired, error: updErr } = await admin
      .from("ad_campaigns")
      .update({ status: "expired", review_note: "Withdrawn by the advertiser." })
      .eq("id", campaignId)
      .eq("status", c.status)
      .select("id")
      .maybeSingle();
    if (updErr || !retired) {
      return json({ error: "Withdraw failed (status changed concurrently?)" }, 409);
    }
  } else {
    // 1) Release the card hold first (rejected ads already had it released).
    //    Sponsorship offers never had one — the "pi_" guard is what makes this
    //    a no-op for them.
    const piId = c.stripe_payment_intent_id ?? "";
    if (c.status === "pending_review" && piId.startsWith("pi_")) {
      await releaseHold(piId, c.split_status === "split");
    }

    // 2) Delete the campaign (creative/targeting/events cascade), guarded
    //    against a concurrent status change.
    const { data: deleted, error: delErr } = await admin
      .from("ad_campaigns")
      .delete()
      .eq("id", campaignId)
      .eq("status", c.status)
      .select("id");
    if (delErr || !deleted?.length) {
      return json({ error: "Delete failed (status changed concurrently?)" }, 409);
    }
  }

  // Audit: actor is the owner (withdraw is owner-gated). Name snapshotted in
  // case the campaign row is now gone.
  await logAudit(admin, {
    campaign_id: campaignId,
    campaign_name: c.name ?? null,
    actor: userId,
    action: "withdraw",
    note: null,
  });

  // 3) Best-effort creative asset cleanup — an orphaned object is cosmetic, and
  //    a retired offer will never serve its creative again either way.
  const path = imageUrl?.split("/ad-creatives/")[1];
  if (path) {
    const { error: rmErr } = await admin.storage
      .from("ad-creatives")
      .remove([decodeURIComponent(path)]);
    if (rmErr) console.error("creative cleanup failed:", rmErr);
  }
  // Video creatives store bucket-relative paths in the ad-videos bucket (0068).
  if (videoPaths.length) {
    const { error: rmErr } = await admin.storage
      .from("ad-videos")
      .remove(videoPaths);
    if (rmErr) console.error("video creative cleanup failed:", rmErr);
  }

  return softWithdraw
    ? json({ withdrawn: campaignId, status: "expired" })
    : json({ deleted: campaignId });
}

