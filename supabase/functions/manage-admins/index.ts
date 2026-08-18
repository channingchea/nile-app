// Supabase Edge Function: manage-admins
//
// Lets existing admins manage the `admins` table from the portal (the table
// has no client write policies by design — see migrations 0032 and 0055).
// Caller must be in `admins`; every mutation is audited in
// admin_management_audit.
//
//   { action: "list" }
//     → { admins: [{ user_id, email, created_at }], audit: [...last 20] }
//   { action: "add", email }
//     → adds the user with that email (must already have a Nile account)
//   { action: "remove", user_id }
//     → removes an admin. Guardrails: can't remove yourself, can't remove
//       the last admin.
//
// Deploy: supabase functions deploy manage-admins   (KEEP JWT on)

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders as corsHeadersFor } from "../_shared/cors.ts";
import { failure } from "../_shared/errors.ts";

// CORS headers are per-request, so the JSON responder is built per-request too
// and handed to the helpers below (they run outside the handler's scope).
type Json = (body: unknown, status?: number) => Response;
const makeJson = (cors: Record<string, string>): Json =>
  (body, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

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

    const { action, email, user_id } = await req.json();

    if (action === "list") return await list(admin, json);
    if (action === "add") return await add(admin, user.id, email, json);
    if (action === "remove") return await remove(admin, user.id, user_id, json);
    return json({ error: "Invalid action" }, 400);
  } catch (err) {
    console.error(err);
    return json(failure(err, "manage-admins"), 500);
  }
});

// deno-lint-ignore no-explicit-any
async function list(admin: any, json: Json) {
  const { data: admins, error } = await admin.rpc("admin_list_admins");
  if (error) return json({ error: "Failed to load admins" }, 500);

  const { data: audit } = await admin
    .from("admin_management_audit")
    .select("actor, action, target_email, created_at")
    .order("created_at", { ascending: false })
    .limit(20);

  // Resolve actor emails from the list we already have (actors are admins;
  // a removed actor just shows a truncated id — acceptable for v1).
  const byId = new Map((admins ?? []).map((a: any) => [a.user_id, a.email]));
  const auditOut = (audit ?? []).map((r: any) => ({
    ...r,
    actor_email: byId.get(r.actor) ?? `${String(r.actor).slice(0, 8)}…`,
  }));

  return json({ admins: admins ?? [], audit: auditOut });
}

// deno-lint-ignore no-explicit-any
async function add(admin: any, actorId: string, email: unknown, json: Json) {
  const cleaned = typeof email === "string" ? email.trim() : "";
  if (!cleaned || !cleaned.includes("@")) return json({ error: "Enter a valid email" }, 400);

  const { data: users, error: lookupErr } = await admin
    .rpc("admin_lookup_user_by_email", { p_email: cleaned });
  if (lookupErr) return json({ error: "Lookup failed" }, 500);
  const target = users?.[0];
  if (!target) {
    return json({ error: "No Nile account found with that email — they need to sign up first" }, 404);
  }

  const { data: existing } = await admin
    .from("admins").select("user_id").eq("user_id", target.id).maybeSingle();
  if (existing) return json({ error: "That person is already an admin" }, 409);

  const { error: insErr } = await admin.from("admins").insert({ user_id: target.id });
  if (insErr) return json({ error: "Failed to add admin" }, 500);

  await logAudit(admin, actorId, "added", target.id, target.email);
  return json({ ok: true, added: { user_id: target.id, email: target.email } });
}

// deno-lint-ignore no-explicit-any
async function remove(admin: any, actorId: string, targetId: unknown, json: Json) {
  if (typeof targetId !== "string" || !targetId) return json({ error: "Invalid user_id" }, 400);

  if (targetId === actorId) {
    return json({ error: "You can't remove yourself — ask another admin" }, 400);
  }

  const { count } = await admin
    .from("admins").select("user_id", { count: "exact", head: true });
  if ((count ?? 0) <= 1) return json({ error: "Can't remove the last admin" }, 400);

  const { data: target } = await admin
    .from("admins").select("user_id").eq("user_id", targetId).maybeSingle();
  if (!target) return json({ error: "That person isn't an admin" }, 404);

  // Snapshot the email for the audit row before deleting.
  let targetEmail: string | null = null;
  try {
    const { data } = await admin.auth.admin.getUserById(targetId);
    targetEmail = data?.user?.email ?? null;
  } catch (_) { /* audit email is best-effort */ }

  const { error: delErr } = await admin.from("admins").delete().eq("user_id", targetId);
  if (delErr) return json({ error: "Failed to remove admin" }, 500);

  await logAudit(admin, actorId, "removed", targetId, targetEmail);
  return json({ ok: true });
}

// Fire-and-forget audit insert — a failure logs but never fails the action.
// deno-lint-ignore no-explicit-any
async function logAudit(
  admin: any, actor: string, action: "added" | "removed",
  targetUserId: string, targetEmail: string | null,
) {
  try {
    const { error } = await admin.from("admin_management_audit").insert({
      actor, action, target_user_id: targetUserId, target_email: targetEmail,
    });
    if (error) console.error("audit insert failed:", error);
  } catch (err) {
    console.error("audit insert error:", err);
  }
}

