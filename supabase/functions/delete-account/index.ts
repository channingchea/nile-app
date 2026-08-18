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
import { corsHeaders as corsHeadersFor } from "../_shared/cors.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
  httpClient: Stripe.createFetchHttpClient(),
});

serve(async (req) => {
  // Per-request CORS (fix #4): allowlisted origins only — see _shared/cors.ts.
  const corsHeaders = corsHeadersFor(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
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

    // P3 #32. This used to 409 on ANY paid ticket, and a ticket only leaves
    // 'paid' via a host refund — so a single purchase locked the account out of
    // deletion forever (Guideline 5.1.1(v)). Only a show that has not happened
    // yet is a live entitlement worth stopping for: refund it first, or it is
    // silently forfeited. Everything already watched is anonymized below.
    const { data: paidTickets } = await admin
      .from("tickets")
      .select(
        "id, events!tickets_event_id_fkey(title, status, scheduled_at, end_at)"
      )
      .eq("buyer_id", uid)
      .eq("status", "paid");

    const now = Date.now();
    const blocking = (paidTickets ?? []).filter((t: Record<string, unknown>) => {
      const e = t.events as {
        title?: string;
        status?: string;
        scheduled_at?: string | null;
        end_at?: string | null;
      } | null;
      if (!e) return false;
      if (e.status === "live" || e.status === "soundcheck") return true;
      if (e.status !== "scheduled") return false; // ended, cancelled, draft
      const endsAt = e.end_at ?? e.scheduled_at;
      // A scheduled show with no date on it can't be proven to be over.
      return !endsAt || new Date(endsAt).getTime() > now;
    });

    if (blocking.length > 0) {
      const first =
        (blocking[0].events as { title?: string } | null)?.title ?? "an event";
      const more = blocking.length - 1;
      return json(
        {
          error:
            `You have a ticket for ${first}${
              more > 0 ? ` and ${more} other upcoming event${more > 1 ? "s" : ""}` : ""
            }, which hasn't happened yet. Ask the host for a refund first, or wait until it's over — then you can delete your account.`,
        },
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
    // livekit_room is the cover image's folder name; the old code guessed
    // `events/<uuid>/cover.jpg`, which matched nothing and left every cover
    // this host ever uploaded sitting in the bucket.
    const { data: hostedEvents } = await admin
      .from("events")
      .select("id, livekit_room")
      .eq("host_id", uid);
    const eventIds = (hostedEvents ?? []).map((e) => e.id as string);
    const eventRooms = (hostedEvents ?? [])
      .map((e) => e.livekit_room as string | null)
      .filter((r): r is string => !!r);

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

    // Tickets are NOT deleted (P3 #32). Migration 0118 made buyer_id nullable
    // with ON DELETE SET NULL, so dropping the profile below severs the link
    // while the sale stays on the host's books. This stamp is what tells the
    // difference between "anonymized buyer" and "corrupt row".
    await admin
      .from("tickets")
      .update({ buyer_deleted_at: new Date().toISOString() })
      .eq("buyer_id", uid);

    // Tips are likewise NOT deleted. tips_tipper_id_fkey used to be ON DELETE
    // CASCADE, so a tipper erasing themselves wiped the HOST's earnings record
    // too — the same bug as tickets, missed in the P3 pass. Migration 0121 made
    // tipper_id nullable with SET NULL; this stamp marks the NULL as deliberate.
    await admin
      .from("tips")
      .update({ tipper_deleted_at: new Date().toISOString() })
      .eq("tipper_id", uid);

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

    // 6. Storage (P3 #33). Only avatars, posts and (nominally) event covers
    // were cleared before, so Currents videos, DM photos and bug-report
    // screenshots outlived the account — a GDPR erasure failure and an
    // unbounded storage bill. Every bucket that keys objects on the user id is
    // now swept. Replay recordings need no entry here: deleting the events in
    // step 5 already fired trg_delete_event_replay_objects.
    for (const bucket of ["avatars", "posts", "currents", "messages", "feedback"]) {
      await removeFolder(admin, bucket, uid);
    }
    for (const room of eventRooms) {
      await removeFolder(admin, "events", room);
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

// Remove every object under `{prefix}/` in a bucket, at any depth.
//
// The old version called list() once with no options — Supabase defaults to
// 100 rows and does not recurse — so a user with 101 objects kept the rest,
// and feedback screenshots (stored at `<uid>/<ts>/<n>.jpg`) were never
// reachable at all. Pages, walks subfolders, and deletes in batches.
// deno-lint-ignore no-explicit-any
async function removeFolder(admin: any, bucket: string, prefix: string) {
  const PAGE = 100;
  const dirs = [prefix];
  const objects: string[] = [];

  while (dirs.length) {
    const dir = dirs.pop()!;
    for (let offset = 0; ; offset += PAGE) {
      const { data: entries, error } = await admin.storage
        .from(bucket)
        .list(dir, { limit: PAGE, offset });
      if (error) {
        console.error(`list ${bucket}/${dir} failed:`, error);
        break;
      }
      if (!entries?.length) break;
      for (const e of entries as { name: string; id: string | null }[]) {
        // A folder is synthesized by the API and carries no id; a real object
        // always has one.
        if (e.id === null) dirs.push(`${dir}/${e.name}`);
        else objects.push(`${dir}/${e.name}`);
      }
      if (entries.length < PAGE) break;
    }
  }

  for (let i = 0; i < objects.length; i += PAGE) {
    const { error } = await admin.storage
      .from(bucket)
      .remove(objects.slice(i, i + PAGE));
    if (error) console.error(`remove from ${bucket} failed:`, error);
  }
}

