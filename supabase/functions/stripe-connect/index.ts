// Supabase Edge Function: stripe-connect
//
// Host Stripe Connect onboarding + account status.
//
// Setup:
//   supabase secrets set STRIPE_SECRET_KEY=sk_test_...
//   supabase secrets set STRIPE_CONNECT_REFRESH_URL=https://your-app.com/payouts-refresh
//   supabase secrets set STRIPE_CONNECT_RETURN_URL=https://your-app.com/payouts-return
//   supabase functions deploy stripe-connect
//
// Request (POST, Bearer = user JWT):
//   { "action": "onboard" }  → { "url": "https://connect.stripe.com/setup/..." }
//   { "action": "status" }   → { "connected": bool, "charges_enabled": bool,
//                                "payouts_enabled": bool, "details_submitted": bool,
//                                "dashboard_url": string | null }

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14?target=deno";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
  httpClient: Stripe.createFetchHttpClient(),
});

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Missing Authorization header" }, 401);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) return json({ error: "Unauthorized" }, 401);

    const { action } = await req.json().catch(() => ({ action: "status" }));

    const adminClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Load (or lazily create) the host's connected account id.
    const { data: profile } = await adminClient
      .from("profiles")
      .select("stripe_account_id")
      .eq("id", user.id)
      .maybeSingle();

    let accountId = profile?.stripe_account_id as string | null;

    if (action === "onboard") {
      // Defense in depth: paid hosts must have 2FA enabled. The client gates
      // this too, but never let onboarding start without a verified factor.
      const { data: mfa } = await adminClient.auth.admin.mfa.listFactors({
        userId: user.id,
      });
      const hasVerified = (mfa?.factors ?? []).some(
        (f) => f.status === "verified",
      );
      if (!hasVerified) {
        return json(
          { error: "two_factor_required", message: "Enable two-factor authentication before setting up payouts." },
          403,
        );
      }

      if (!accountId) {
        const account = await stripe.accounts.create({
          type: "express",
          email: user.email ?? undefined,
          capabilities: {
            card_payments: { requested: true },
            transfers: { requested: true },
          },
          metadata: { user_id: user.id },
        });
        accountId = account.id;
        await adminClient
          .from("profiles")
          .update({ stripe_account_id: accountId })
          .eq("id", user.id);
      }

      const link = await stripe.accountLinks.create({
        account: accountId,
        refresh_url: Deno.env.get("STRIPE_CONNECT_REFRESH_URL")!,
        return_url: Deno.env.get("STRIPE_CONNECT_RETURN_URL")!,
        type: "account_onboarding",
      });

      return json({ url: link.url });
    }

    // action === "status" (default)
    if (!accountId) {
      return json({
        connected: false,
        charges_enabled: false,
        payouts_enabled: false,
        details_submitted: false,
        dashboard_url: null,
      });
    }

    const account = await stripe.accounts.retrieve(accountId);

    // Put newly-payable accounts on a monthly payout schedule (end of month).
    // Idempotent — skip if already monthly. Done here (polled on the Payouts
    // screen after onboarding) so we don't need a Connect webhook.
    if (account.payouts_enabled &&
        account.settings?.payouts?.schedule?.interval !== "monthly") {
      try {
        await stripe.accounts.update(accountId, {
          settings: { payouts: { schedule: { interval: "monthly", monthly_anchor: 31 } } },
        });
      } catch (e) {
        console.warn("payout schedule update failed", e);
      }
    }

    // Express dashboard login link — only valid once details are submitted.
    let dashboardUrl: string | null = null;
    if (account.details_submitted) {
      try {
        const loginLink = await stripe.accounts.createLoginLink(accountId);
        dashboardUrl = loginLink.url;
      } catch (_) {/* login link unavailable until fully active */}
    }

    return json({
      connected: true,
      charges_enabled: account.charges_enabled,
      payouts_enabled: account.payouts_enabled,
      details_submitted: account.details_submitted,
      dashboard_url: dashboardUrl,
    });
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
