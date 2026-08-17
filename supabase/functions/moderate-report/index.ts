// Supabase Edge Function: moderate-report
//
// Admin actions on reported content (Reported-Content Review Page, Phase 2).
// Caller must be in the `admins` table (migration 0032), re-checked here with
// the service role — mirrors `review-ad-campaign`. Every write is guarded
// against races (return 409 if the target already moved) and every action
// leaves a row in `moderation_audit` (fire-and-forget; never fails the call).
//
//   { target_type: "user" | "post" | "event" | "comment" | "ad"
//                | "current" | "current_comment" | "live_chat_message",
//     target_id: uuid,
//     action: "resolve" | "dismiss" | "remove_content" | "restore_content"
//           | "suspend_user" | "unsuspend_user",
//     note?: string }
//
//   resolve / dismiss    — flips ALL open/reviewing reports for
//                          (target_type, target_id) to resolved/dismissed.
//                          Valid for every target_type, including "ad" (the
//                          portal calls review-ad-campaign separately for
//                          the actual pause/reject of an ad campaign).
//   remove_content       — post/comment/event/current/current_comment. Sets
//                          removed_at/removed_by (0053/0065 RLS then hides it
//                          app-wide) and resolves the target's open/reviewing
//                          reports. Decrements the parent's comment_count for
//                          comment-shaped targets (soft-remove doesn't fire
//                          the delete trigger).
//   restore_content      — post/comment/event/current/current_comment. Clears
//                          removed_at/removed_by. Reports are left resolved —
//                          restoring doesn't reopen them. Re-increments the
//                          parent's comment_count for comment-shaped targets.
//   suspend_user         — user only. Bans the auth user (indefinite) via
//                          auth.admin.updateUserById + sets
//                          profiles.suspended_at, and resolves that user's
//                          open/reviewing reports. Their content stays up
//                          unless removed individually (non-goal: cascading
//                          content takedown on suspend).
//   unsuspend_user       — user only. Clears the ban + suspended_at.
//
// Deploy: supabase functions deploy moderate-report   (KEEP JWT on)

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders as corsHeadersFor } from "../_shared/cors.ts";

// CORS headers are per-request, so the JSON responder is built per-request too
// and handed to the helpers below (they run outside the handler's scope).
type Json = (body: unknown, status?: number) => Response;
const makeJson = (cors: Record<string, string>): Json =>
  (body, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

const CONTENT_TABLES: Record<string, string> = {
  post: "posts",
  comment: "post_comments",
  event: "events",
  current: "currents",
  current_comment: "current_comments",
  // #16 phase 3. live_chat_messages carries the same id/removed_at/removed_by
  // shape the generic remove path expects, so this entry is the whole change —
  // remove_content and restore_content need no new code.
  live_chat_message: "live_chat_messages",
};

// Comment-shaped tables keep a denormalized count on their parent; soft
// removal doesn't fire the count trigger, so it's adjusted by hand.
const COMMENT_PARENTS: Record<string, { parentTable: string; parentCol: string }> = {
  post_comments: { parentTable: "posts", parentCol: "post_id" },
  current_comments: { parentTable: "currents", parentCol: "current_id" },
};

const TARGET_TYPES = new Set([
  "user", "post", "event", "comment", "ad", "current", "current_comment",
  "live_chat_message",
]);
const ACTIONS = new Set([
  "resolve", "dismiss", "remove_content", "restore_content",
  "suspend_user", "unsuspend_user",
]);

// GoTrue bans take a duration, not "forever" — ~100 years reads as indefinite.
const BAN_DURATION = "876000h";

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

    // Admin gate — service-role read of the admins table (RLS-independent).
    const { data: adminRow } = await admin
      .from("admins").select("user_id").eq("user_id", user.id).maybeSingle();
    if (!adminRow) return json({ error: "Admins only" }, 403);

    const { target_type, target_id, action, note } = await req.json();

    if (!TARGET_TYPES.has(target_type) || !target_id || !ACTIONS.has(action)) {
      return json({ error: "Invalid target_type, target_id, or action" }, 400);
    }
    if ((action === "suspend_user" || action === "unsuspend_user") && target_type !== "user") {
      return json({ error: "suspend_user/unsuspend_user require target_type 'user'" }, 400);
    }

    const trimmedNote = typeof note === "string" ? note.trim().slice(0, 300) || null : null;

    if (action === "resolve" || action === "dismiss") {
      return await resolveOrDismiss(admin, user.id, target_type, target_id, action, trimmedNote, json);
    }
    if (action === "remove_content") {
      return await removeContent(admin, user.id, target_type, target_id, trimmedNote, json);
    }
    if (action === "restore_content") {
      return await restoreContent(admin, user.id, target_type, target_id, trimmedNote, json);
    }
    if (action === "suspend_user") {
      return await suspendUser(admin, user.id, target_id, trimmedNote, json);
    }
    // action === "unsuspend_user"
    return await unsuspendUser(admin, user.id, target_id, trimmedNote, json);
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});

// ── resolve / dismiss ────────────────────────────────────────────────────
// deno-lint-ignore no-explicit-any
async function resolveOrDismiss(
  admin: any, actorId: string, targetType: string, targetId: string,
  action: "resolve" | "dismiss", note: string | null, json: Json,
) {
  const toStatus = action === "resolve" ? "resolved" : "dismissed";
  const { data: updated, error } = await admin
    .from("reports")
    .update({ status: toStatus })
    .eq("target_type", targetType)
    .eq("target_id", targetId)
    .in("status", ["open", "reviewing"])
    .select("id");
  if (error) return json({ error: "Update failed" }, 500);
  if (!updated?.length) {
    return json({ error: "No open/reviewing reports for this target (already handled?)" }, 409);
  }

  // An upheld ad report is the exact signal the sponsorship trusted tier is
  // meant to react to: this advertiser's creative got in front of people
  // without a human looking at it, and it shouldn't have. Back to the blocking
  // queue until an admin clears them again. (dismiss means the report was
  // wrong, so it leaves the tier alone.)
  if (action === "resolve" && targetType === "ad") {
    await demoteAdvertiserTrust(admin, targetId);
  }

  await logAudit(admin, { actor: actorId, action, target_type: targetType, target_id: targetId, note });
  return json({ target_type: targetType, target_id: targetId, action, reports_updated: updated.length });
}

// reports.target_id for an 'ad' is the ad_campaigns row. Fire-and-forget: a
// failed demotion is logged, never a reason to fail the moderation action.
// deno-lint-ignore no-explicit-any
async function demoteAdvertiserTrust(admin: any, campaignId: string) {
  try {
    const { data: c } = await admin
      .from("ad_campaigns").select("advertiser_account_id").eq("id", campaignId).maybeSingle();
    const accountId = c?.advertiser_account_id as string | null;
    if (!accountId) return; // host boost — no advertiser account to demote
    const { error } = await admin
      .from("advertiser_accounts")
      .update({ trust_tier: "new", trusted_at: null })
      .eq("id", accountId);
    if (error) console.error("trust demotion failed:", error);
  } catch (err) {
    console.error("trust demotion error:", err);
  }
}

// ── remove_content ───────────────────────────────────────────────────────
// deno-lint-ignore no-explicit-any
async function removeContent(
  admin: any, actorId: string, targetType: string, targetId: string, note: string | null,
  json: Json,
) {
  const table = CONTENT_TABLES[targetType];
  if (!table) return json({ error: "remove_content is only valid for content targets" }, 400);

  const parent = COMMENT_PARENTS[table];
  const cols = parent ? `id, ${parent.parentCol}` : "id";
  const { data: updated, error } = await admin
    .from(table)
    .update({ removed_at: new Date().toISOString(), removed_by: actorId })
    .eq("id", targetId)
    .is("removed_at", null)
    .select(cols);
  if (error) return json({ error: "Update failed" }, 500);
  if (!updated?.length) {
    return json({ error: "Already removed (or not found)" }, 409);
  }

  // Denormalized counter: a soft-removed comment doesn't fire the delete
  // trigger, so decrement the parent's comment_count by hand.
  if (parent) {
    const parentId = (updated[0] as any)[parent.parentCol];
    if (parentId) await bumpCommentCount(admin, parent.parentTable, parentId, -1);
  }

  // Close out the reports that flagged this target.
  const { data: resolved, error: rErr } = await admin
    .from("reports")
    .update({ status: "resolved" })
    .eq("target_type", targetType)
    .eq("target_id", targetId)
    .in("status", ["open", "reviewing"])
    .select("id");
  if (rErr) console.error("report resolve failed:", rErr);

  await logAudit(admin, { actor: actorId, action: "remove_content", target_type: targetType, target_id: targetId, note });
  return json({
    target_type: targetType, target_id: targetId, removed: true,
    reports_resolved: resolved?.length ?? 0,
  });
}

// ── restore_content ──────────────────────────────────────────────────────
// deno-lint-ignore no-explicit-any
async function restoreContent(
  admin: any, actorId: string, targetType: string, targetId: string, note: string | null,
  json: Json,
) {
  const table = CONTENT_TABLES[targetType];
  if (!table) return json({ error: "restore_content is only valid for content targets" }, 400);

  const parent = COMMENT_PARENTS[table];
  const cols = parent ? `id, ${parent.parentCol}` : "id";
  const { data: updated, error } = await admin
    .from(table)
    .update({ removed_at: null, removed_by: null })
    .eq("id", targetId)
    .not("removed_at", "is", null)
    .select(cols);
  if (error) return json({ error: "Update failed" }, 500);
  if (!updated?.length) {
    return json({ error: "Not currently removed (or not found)" }, 409);
  }

  if (parent) {
    const parentId = (updated[0] as any)[parent.parentCol];
    if (parentId) await bumpCommentCount(admin, parent.parentTable, parentId, 1);
  }

  // Reports intentionally stay resolved — restoring doesn't reopen them.
  await logAudit(admin, { actor: actorId, action: "restore_content", target_type: targetType, target_id: targetId, note });
  return json({ target_type: targetType, target_id: targetId, restored: true });
}

// deno-lint-ignore no-explicit-any
async function bumpCommentCount(admin: any, parentTable: string, parentId: string, delta: number) {
  const { data: row, error } = await admin
    .from(parentTable).select("comment_count").eq("id", parentId).maybeSingle();
  if (error || !row) { console.error("comment_count lookup failed:", error); return; }
  const next = Math.max(0, row.comment_count + delta);
  const { error: updErr } = await admin.from(parentTable).update({ comment_count: next }).eq("id", parentId);
  if (updErr) console.error("comment_count update failed:", updErr);
}

// ── suspend_user / unsuspend_user ────────────────────────────────────────
// deno-lint-ignore no-explicit-any
async function suspendUser(admin: any, actorId: string, targetId: string, note: string | null, json: Json) {
  const { data: profile, error: pErr } = await admin
    .from("profiles").select("id, suspended_at").eq("id", targetId).maybeSingle();
  if (pErr) return json({ error: "Lookup failed" }, 500);
  if (!profile) return json({ error: "User not found" }, 404);
  if (profile.suspended_at) return json({ error: "Already suspended" }, 409);

  const { error: banErr } = await admin.auth.admin.updateUserById(targetId, { ban_duration: BAN_DURATION });
  if (banErr) return json({ error: `Ban failed: ${banErr.message}` }, 500);

  const { error: updErr } = await admin
    .from("profiles").update({ suspended_at: new Date().toISOString() }).eq("id", targetId);
  if (updErr) {
    console.error("suspended_at update failed:", updErr);
    return json({ error: "Ban applied but profile update failed" }, 500);
  }

  const { data: resolved, error: rErr } = await admin
    .from("reports")
    .update({ status: "resolved" })
    .eq("target_type", "user")
    .eq("target_id", targetId)
    .in("status", ["open", "reviewing"])
    .select("id");
  if (rErr) console.error("report resolve failed:", rErr);

  await logAudit(admin, { actor: actorId, action: "suspend_user", target_type: "user", target_id: targetId, note });
  return json({ target_id: targetId, suspended: true, reports_resolved: resolved?.length ?? 0 });
}

// deno-lint-ignore no-explicit-any
async function unsuspendUser(admin: any, actorId: string, targetId: string, note: string | null, json: Json) {
  const { data: profile, error: pErr } = await admin
    .from("profiles").select("id, suspended_at").eq("id", targetId).maybeSingle();
  if (pErr) return json({ error: "Lookup failed" }, 500);
  if (!profile) return json({ error: "User not found" }, 404);
  if (!profile.suspended_at) return json({ error: "Not currently suspended" }, 409);

  const { error: banErr } = await admin.auth.admin.updateUserById(targetId, { ban_duration: "none" });
  if (banErr) return json({ error: `Unban failed: ${banErr.message}` }, 500);

  const { error: updErr } = await admin
    .from("profiles").update({ suspended_at: null }).eq("id", targetId);
  if (updErr) {
    console.error("suspended_at clear failed:", updErr);
    return json({ error: "Unban applied but profile update failed" }, 500);
  }

  await logAudit(admin, { actor: actorId, action: "unsuspend_user", target_type: "user", target_id: targetId, note });
  return json({ target_id: targetId, suspended: false });
}

// Permanent record of a moderation action. Written with the service role
// (RLS on moderation_audit only grants reads). Fire-and-forget: an insert
// failure is logged but never fails the action — same posture as
// review-ad-campaign's logAudit.
// deno-lint-ignore no-explicit-any
async function logAudit(admin: any, row: {
  actor: string; action: string; target_type: string; target_id: string; note: string | null;
}) {
  try {
    const { error } = await admin.from("moderation_audit").insert(row);
    if (error) console.error("audit insert failed:", error);
  } catch (err) {
    console.error("audit insert error:", err);
  }
}

