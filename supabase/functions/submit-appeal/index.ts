// Supabase Edge Function: submit-appeal
//
// Takes an appeal against a moderation decision from joinnile.com/appeal
// (P3 #35, DSA Art. 17).
//
// Deliberately UNAUTHENTICATED. The people who most need to appeal are the
// ones GoTrue has banned — they cannot hold a session, so an authenticated
// endpoint would only serve the users who don't need it. The trade is that
// anyone can post here, which is why this writes to a table no client can read
// or write directly and does its own validation and rate limiting.
//
// Request (POST): { "email": "...", "body": "...", "kind"?: "suspension" | "content" }
// Response: { "ok": true } | { "error": "..." }
//
// Deploy: supabase functions deploy submit-appeal --no-verify-jwt

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders as corsHeadersFor } from "../_shared/cors.ts";

const BODY_MIN = 20;
const BODY_MAX = 4000;
const EMAIL_MAX = 320;
// Three attempts a day is plenty to say what happened, and low enough that
// this can't be used to flood the queue.
const MAX_PER_DAY = 3;

const EMAIL_RE = /^[^@\s]+@[^@\s.]+\.[^@\s]+$/;

serve(async (req) => {
  const corsHeaders = corsHeadersFor(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const payload = await req.json().catch(() => ({}));
    const email = String(payload.email ?? "").trim().toLowerCase();
    const rawBody = String(payload.body ?? "").trim();
    const kind = payload.kind === "content" ? "content" : "suspension";

    if (!email || email.length > EMAIL_MAX || !EMAIL_RE.test(email)) {
      return json({ error: "Enter the email address on your Nile account." }, 400);
    }
    if (rawBody.length < BODY_MIN) {
      return json({ error: "Tell us a little more about what happened." }, 400);
    }
    const body = rawBody.slice(0, BODY_MAX);

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    const { count } = await admin
      .from("appeals")
      .select("id", { count: "exact", head: true })
      .eq("email", email)
      .gte("created_at", since);
    if ((count ?? 0) >= MAX_PER_DAY) {
      return json(
        { error: "You've already sent us a few appeals today. We'll reply to those first." },
        429,
      );
    }

    // Best-effort link to the account, so an admin opening the queue can see
    // the history without searching. An appeal from an address we don't
    // recognise is still recorded — the person may have typed it wrong, and
    // that is not a reason to drop what they said.
    let userId: string | null = null;
    let noticeId: string | null = null;
    const { data: authUser } = await admin.rpc("appeal_user_id_for_email", {
      p_email: email,
    });
    if (typeof authUser === "string") {
      userId = authUser;
      const { data: notice } = await admin
        .from("moderation_notices")
        .select("id")
        .eq("user_id", userId)
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle();
      noticeId = (notice?.id as string | null) ?? null;
    }

    const { error } = await admin.from("appeals").insert({
      email,
      body: `[${kind}] ${body}`,
      user_id: userId,
      notice_id: noticeId,
    });
    if (error) {
      console.error("appeal insert failed:", error);
      return json({ error: "We couldn't record that. Please try again shortly." }, 500);
    }

    return json({ ok: true });
  } catch (err) {
    console.error(err);
    return json({ error: "Something went wrong." }, 500);
  }
});
