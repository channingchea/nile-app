// Supabase Edge Function: delete-account
//
// Permanently deletes the authenticated user's account and all associated
// data. Self-service GDPR-style erasure — a user may only delete themselves.
//
// Setup (secrets are already present from other functions):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
//   supabase functions deploy delete-account
//
// Request (POST, Bearer = user JWT): no body required.
// Response: { "ok": true }  or  { "error": "..." }
//
// Why an Edge Function: deleting the auth.users row requires the service
// role, and the app tables FK to public.profiles without ON DELETE CASCADE,
// so child rows must be removed in dependency order first. Deleting the
// auth user is the final, irreversible step.

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

    // Identify the caller from their JWT.
    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );
    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) return json({ error: "Unauthorized" }, 401);

    const uid = user.id;
    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Guard against deleting an account that still holds paid tickets which
    // have not been refunded — surface to the user instead of silently
    // dropping their purchase records.
    const { count: paidCount } = await admin
      .from("tickets")
      .select("id", { count: "exact", head: true })
      .eq("buyer_id", uid)
      .eq("status", "paid");
    if ((paidCount ?? 0) > 0) {
      return json(
        { error: "You have active paid tickets. Please request refunds before deleting your account." },
        409
      );
    }

    // Stripe Connect account id — capture before the profile row is deleted.
    const { data: profile } = await admin
      .from("profiles")
      .select("stripe_account_id")
      .eq("id", uid)
      .maybeSingle();
    const stripeAccountId = profile?.stripe_account_id as string | null;

    // Guard against deleting a host who still has money in Stripe. Deleting the
    // Connect account discards the only pointer to it (stripe_account_id), so
    // any un-paid-out balance would be stranded. Block until it disperses.
    if (stripeAccountId) {
      try {
        const balance = await stripe.balance.retrieve(
          {},
          { stripeAccount: stripeAccountId }
        );
        const outstanding = [...balance.available, ...balance.pending]
          .reduce((sum, b) => sum + b.amount, 0);
        if (outstanding > 0) {
          return json(
            { error: "You still have a Stripe balance pending payout. Please wait until your funds have been paid out to your bank before deleting your account." },
            409
          );
        }
      } catch (e) {
        // If we can't confirm the balance is clear, fail safe: don't delete.
        console.error(`Could not verify Stripe balance for ${stripeAccountId}:`, e);
        return json(
          { error: "We couldn't verify your Stripe balance right now. Please try again later or contact support." },
          503
        );
      }
    }

    // Events this user hosts — needed to clean their dependent rows + storage.
    const { data: hostedEvents } = await admin
      .from("events")
      .select("id")
      .eq("host_id", uid);
    const eventIds = (hostedEvents ?? []).map((e) => e.id as string);

    // Posts authored by the user — needed to drop their cover images.
    const { data: ownPosts } = await admin
      .from("posts")
      .select("id, image_url")
      .eq("user_id", uid);
    const postIds = (ownPosts ?? []).map((p) => p.id as string);

    // 1. Rows keyed directly to the user (no other rows depend on these).
    await admin.from("post_likes").delete().eq("user_id", uid);
    await admin.from("event_likes").delete().eq("user_id", uid);
    await admin.from("event_attendees").delete().eq("user_id", uid);
    await admin.from("follows").delete().eq("follower_id", uid);
    await admin.from("follows").delete().eq("following_id", uid);
    await admin.from("blocks").delete().eq("blocker_id", uid);
    await admin.from("blocks").delete().eq("blocked_id", uid);
    await admin.from("reports").delete().eq("reporter_id", uid);
    await admin.from("notifications").delete().eq("recipient_id", uid);
    await admin.from("notifications").delete().eq("actor_id", uid);
    await admin.from("device_tokens").delete().eq("user_id", uid);
    await admin.from("notification_preferences").delete().eq("user_id", uid);
    await admin.from("tickets").delete().eq("buyer_id", uid);

    // 2. Comments the user wrote, plus all comments/likes on their own posts.
    await admin.from("post_comments").delete().eq("user_id", uid);
    if (postIds.length) {
      await admin.from("post_comments").delete().in("post_id", postIds);
      await admin.from("post_likes").delete().in("post_id", postIds);
    }

    // 3. Direct messages + conversations the user took part in.
    const { data: convos } = await admin
      .from("conversations")
      .select("id")
      .or(`participant_a.eq.${uid},participant_b.eq.${uid}`);
    const convoIds = (convos ?? []).map((c) => c.id as string);
    if (convoIds.length) {
      await admin.from("messages").delete().in("conversation_id", convoIds);
      await admin.from("conversations").delete().in("id", convoIds);
    }
    await admin.from("messages").delete().eq("sender_id", uid);

    // 4. The user's posts.
    await admin.from("posts").delete().eq("user_id", uid);

    // 5. Hosted events + everything that FKs to them.
    if (eventIds.length) {
      await admin.from("tickets").delete().in("event_id", eventIds);
      await admin.from("event_attendees").delete().in("event_id", eventIds);
      await admin.from("event_likes").delete().in("event_id", eventIds);
      await admin.from("posts").delete().in("event_id", eventIds);
      await admin.from("events").delete().in("id", eventIds);
    }

    // 6. Storage: per-user folders in avatars/posts, per-event covers.
    await removeFolder(admin, "avatars", uid);
    await removeFolder(admin, "posts", uid);
    for (const eid of eventIds) {
      await admin.storage.from("events").remove([`events/${eid}/cover.jpg`]);
    }

    // 7. Stripe Connect account, if the user was an onboarded host. Best-effort:
    // a Stripe failure must not block account deletion, but is logged so it can
    // be reconciled manually. Stripe blocks deletion of accounts with a negative
    // balance — that case surfaces here as a logged error.
    if (stripeAccountId) {
      try {
        await stripe.accounts.del(stripeAccountId);
      } catch (e) {
        console.error(`Stripe account ${stripeAccountId} not deleted:`, e);
      }
    }

    // 8. Profile row, then the auth user (irreversible).
    await admin.from("profiles").delete().eq("id", uid);
    const { error: delErr } = await admin.auth.admin.deleteUser(uid);
    if (delErr) return json({ error: delErr.message }, 500);

    return json({ ok: true });
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});

// Remove every object under `{prefix}/` in a bucket.
// deno-lint-ignore no-explicit-any
async function removeFolder(admin: any, bucket: string, prefix: string) {
  const { data: files } = await admin.storage.from(bucket).list(prefix);
  if (files && files.length) {
    await admin.storage
      .from(bucket)
      .remove(files.map((f: { name: string }) => `${prefix}/${f.name}`));
  }
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
