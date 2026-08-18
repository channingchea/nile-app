// Supabase Edge Function: manage-admins
//
// Admin management, four-eyes. (P4 #42 of the 2026-08-16 platform review.)
//
// `public.admins` has no client write policies by design (migrations 0032 and
// 0055), so every change comes through here. What changed in 0126 is WHO may
// make one and HOW:
//
//   • Ordinary admins keep every operational power — moderation, reports,
//     appeals, ad review, featured placement — and lose exactly one: changing
//     who is an admin. That is the power worth separating, because it is the
//     only one that can be used to keep all the others.
//   • A super_admin PROPOSES a change; a DIFFERENT super_admin approves it;
//     only then does anything happen. Tier alone doesn't help if the account
//     that gets phished is the super_admin.
//   • With exactly one super_admin there is nobody who could ever approve, so
//     that person acts alone and the request is stamped `unilateral`. Adding a
//     second super_admin turns the four-eyes rule on — which is the incentive
//     we want.
//
// Actions (POST, Bearer = user JWT):
//   { action: "list" }
//     → { admins, requests, audit, me: { user_id, role } }        any admin
//   { action: "propose", change: "add"|"remove"|"promote"|"demote",
//     email?, user_id?, reason? }                                 super_admin
//   { action: "approve", request_id }                             super_admin
//   { action: "reject",  request_id }                             super_admin
//   { action: "cancel",  request_id }        the requester, on their own row
//
// The mutation itself lives in admin_apply_change_request() so the guardrail
// checks and the write share one transaction — two concurrent approvals must
// not each believe another super_admin remains and between them leave zero.
//
// Deploy: supabase functions deploy manage-admins   (KEEP JWT on)

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders as corsHeadersFor } from "../_shared/cors.ts";
import { failure } from "../_shared/errors.ts";

type Json = (body: unknown, status?: number) => Response;
const makeJson = (cors: Record<string, string>): Json =>
  (body, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

// Human wording for every status admin_apply_change_request can return. Kept
// here rather than in the DB so the copy can change without a migration.
const APPLY_MESSAGES: Record<string, string> = {
  not_pending: "That request has already been decided.",
  expired: "That request expired before anyone approved it. Propose it again.",
  same_person: "Someone other than the person who proposed it has to approve.",
  last_admin: "That would remove the last admin.",
  last_super_admin: "That would leave nobody able to manage admins.",
  already_admin: "They were already an admin — nothing to do.",
};

serve(async (req) => {
  const corsHeaders = corsHeadersFor(req);
  const json = makeJson(corsHeaders);
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Missing Authorization header" }, 401);

    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) return json({ error: "Unauthorized" }, 401);

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Service-role read, so this gate doesn't depend on RLS.
    const { data: me } = await admin
      .from("admins").select("user_id, role").eq("user_id", user.id).maybeSingle();
    if (!me) return json({ error: "Admins only" }, 403);
    const isSuper = me.role === "super_admin";

    const body = await req.json();
    const { action } = body;

    if (action === "list") return await list(admin, me, json);

    // Everything past here changes the admin list.
    if (!isSuper && action !== "cancel") {
      return json({
        error:
          "Only a super admin can change who is an admin. Ask one of them to propose it.",
      }, 403);
    }

    if (action === "propose") return await propose(admin, user.id, body, json);
    if (action === "approve") return await decide(admin, user.id, body, "approve", json);
    if (action === "reject") return await decide(admin, user.id, body, "reject", json);
    if (action === "cancel") return await cancel(admin, user.id, body, json);
    return json({ error: "Invalid action" }, 400);
  } catch (err) {
    return json(failure(err, "manage-admins"), 500);
  }
});

// deno-lint-ignore no-explicit-any
async function list(admin: any, me: { user_id: string; role: string }, json: Json) {
  const { data: admins, error } = await admin.rpc("admin_list_admins");
  if (error) return json({ error: "Failed to load admins" }, 500);

  // Anything still pending past its expiry is dead; say so on read rather than
  // running a cron for it. The apply path re-checks, so this is display only.
  const { data: requests } = await admin
    .from("admin_change_requests")
    .select(
      "id, action, target_user_id, target_email, reason, requested_by, " +
        "requested_by_email, status, decided_by_email, decided_at, unilateral, " +
        "created_at, expires_at",
    )
    .order("created_at", { ascending: false })
    .limit(30);

  const { data: audit } = await admin
    .from("admin_management_audit")
    .select("actor, actor_email, action, target_email, created_at")
    .order("created_at", { ascending: false })
    .limit(20);

  const now = Date.now();
  // deno-lint-ignore no-explicit-any
  const requestsOut = (requests ?? []).map((r: any) => ({
    ...r,
    status: r.status === "pending" && Date.parse(r.expires_at) < now
      ? "expired"
      : r.status,
    // The portal needs to know whether THIS admin may decide it, and the rule
    // (not your own proposal) is easier to state once here than in the UI.
    can_decide: r.status === "pending" && r.requested_by !== me.user_id,
  }));

  return json({
    admins: admins ?? [],
    requests: requestsOut,
    audit: audit ?? [],
    me,
  });
}

// deno-lint-ignore no-explicit-any
async function propose(admin: any, actorId: string, body: any, json: Json) {
  const change = body.change;
  if (!["add", "remove", "promote", "demote"].includes(change)) {
    return json({ error: "Invalid change" }, 400);
  }

  // Resolve the target to a real user + email, whichever identifier came in.
  let targetId: string | null = null;
  let targetEmail = "";

  if (change === "add") {
    const cleaned = typeof body.email === "string" ? body.email.trim() : "";
    if (!cleaned || !cleaned.includes("@")) {
      return json({ error: "Enter a valid email" }, 400);
    }
    const { data: users, error: lookupErr } = await admin
      .rpc("admin_lookup_user_by_email", { p_email: cleaned });
    if (lookupErr) return json({ error: "Lookup failed" }, 500);
    const target = users?.[0];
    if (!target) {
      return json({
        error: "No Nile account found with that email — they need to sign up first",
      }, 404);
    }
    targetId = target.id;
    targetEmail = target.email;

    const { data: existing } = await admin
      .from("admins").select("user_id").eq("user_id", targetId).maybeSingle();
    if (existing) return json({ error: "That person is already an admin" }, 409);
  } else {
    if (typeof body.user_id !== "string" || !body.user_id) {
      return json({ error: "Invalid user_id" }, 400);
    }
    targetId = body.user_id;
    const { data: row } = await admin
      .from("admins").select("user_id, role").eq("user_id", targetId).maybeSingle();
    if (!row) return json({ error: "That person isn't an admin" }, 404);
    if (change === "promote" && row.role === "super_admin") {
      return json({ error: "They're already a super admin" }, 409);
    }
    if (change === "demote" && row.role !== "super_admin") {
      return json({ error: "They're not a super admin" }, 409);
    }

    const { data: u } = await admin.auth.admin.getUserById(targetId);
    targetEmail = u?.user?.email ?? targetId;
  }

  // Removing yourself is still refused outright. It isn't a safety rule so
  // much as a footgun: the four-eyes flow means you can't undo it alone.
  if (change === "remove" && targetId === actorId) {
    return json({ error: "You can't remove yourself — ask another super admin" }, 400);
  }

  const { data: actor } = await admin.auth.admin.getUserById(actorId);

  const { data: created, error: insErr } = await admin
    .from("admin_change_requests")
    .insert({
      action: change,
      target_user_id: targetId,
      target_email: targetEmail,
      reason: typeof body.reason === "string" ? body.reason.slice(0, 500) : null,
      requested_by: actorId,
      requested_by_email: actor?.user?.email ?? null,
    })
    .select("id")
    .single();

  if (insErr) {
    // 23505 is the partial unique index: one open proposal per target.
    if (insErr.code === "23505") {
      return json({
        error: "There's already an open request for that person.",
      }, 409);
    }
    return json({ error: "Couldn't record that request" }, 500);
  }

  await admin.from("admin_management_audit").insert({
    actor: actorId,
    action: "proposed",
    target_user_id: targetId,
    target_email: targetEmail,
  });

  // Bootstrap: with one super_admin nobody could ever approve, so apply now
  // and mark it. Not an exception to the rule so much as the honest reading
  // of it — four eyes requires four eyes to exist.
  const { count: superCount } = await admin
    .from("admins")
    .select("user_id", { count: "exact", head: true })
    .eq("role", "super_admin");

  if ((superCount ?? 0) <= 1) {
    const { data: status } = await admin.rpc("admin_apply_change_request", {
      p_request_id: created.id,
      p_decider: actorId,
      p_unilateral: true,
    });
    if (status !== "applied") {
      return json({ error: APPLY_MESSAGES[status] ?? "Couldn't apply that change" }, 409);
    }
    return json({
      ok: true,
      applied: true,
      unilateral: true,
      note:
        "Applied immediately — you're the only super admin, so there was nobody " +
        "to approve it. Add a second super admin and future changes will need two people.",
    });
  }

  return json({ ok: true, applied: false, request_id: created.id });
}

// deno-lint-ignore no-explicit-any
async function decide(
  admin: any,
  actorId: string,
  body: any,
  verdict: "approve" | "reject",
  json: Json,
) {
  const id = body.request_id;
  if (typeof id !== "string" || !id) return json({ error: "Invalid request_id" }, 400);

  const { data: r } = await admin
    .from("admin_change_requests")
    .select("id, status, requested_by, target_user_id, target_email")
    .eq("id", id)
    .maybeSingle();
  if (!r) return json({ error: "No such request" }, 404);
  if (r.status !== "pending") return json({ error: APPLY_MESSAGES.not_pending }, 409);
  if (r.requested_by === actorId) {
    return json({ error: APPLY_MESSAGES.same_person }, 403);
  }

  if (verdict === "reject") {
    const { data: actor } = await admin.auth.admin.getUserById(actorId);
    await admin.from("admin_change_requests").update({
      status: "rejected",
      decided_by: actorId,
      decided_by_email: actor?.user?.email ?? null,
      decided_at: new Date().toISOString(),
    }).eq("id", id);
    await admin.from("admin_management_audit").insert({
      actor: actorId,
      action: "rejected",
      target_user_id: r.target_user_id,
      target_email: r.target_email,
    });
    return json({ ok: true, status: "rejected" });
  }

  const { data: status, error } = await admin.rpc("admin_apply_change_request", {
    p_request_id: id,
    p_decider: actorId,
    p_unilateral: false,
  });
  if (error) return json({ error: "Couldn't apply that change" }, 500);
  if (status !== "applied") {
    return json({ error: APPLY_MESSAGES[status] ?? "Couldn't apply that change" }, 409);
  }
  return json({ ok: true, status: "applied" });
}

// deno-lint-ignore no-explicit-any
async function cancel(admin: any, actorId: string, body: any, json: Json) {
  const id = body.request_id;
  if (typeof id !== "string" || !id) return json({ error: "Invalid request_id" }, 400);

  // Only the person who proposed it, and only while it's still open. Anyone
  // else wanting it gone should reject it, which is recorded.
  const { data: updated } = await admin
    .from("admin_change_requests")
    .update({ status: "cancelled", decided_at: new Date().toISOString() })
    .eq("id", id)
    .eq("requested_by", actorId)
    .eq("status", "pending")
    .select("id");

  if (!updated?.length) {
    return json({ error: "Nothing to cancel — it isn't yours or it's already decided." }, 409);
  }
  return json({ ok: true, status: "cancelled" });
}
