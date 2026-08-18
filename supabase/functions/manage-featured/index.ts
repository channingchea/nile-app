// Supabase Edge Function: manage-featured
//
// Lets existing admins curate the `featured_content` table from the portal
// (the table has no client write policies — see migration 0063). Caller must
// be in `admins`. Powers the app's Featured rails (Discover + onboarding).
//
//   { action: "list" }
//     → { events:  [{ target_id, position, title, cover_image_url, status,
//                      scheduled_at, host_username, missing }],
//         creators:[{ target_id, position, username, display_name,
//                      avatar_url, follower_count, missing }] }
//   { action: "add",     kind, target_id }   → appends to the end of its section
//   { action: "remove",  kind, target_id }   → removes
//   { action: "reorder", kind, target_ids }  → sets position by array index
//   { action: "search",  kind, query }       → candidates to feature (top 20)
//
// `kind` is "event" | "creator". CORS is inlined (rather than importing
// ../_shared/cors.ts) so the function deploys as a single self-contained file;
// keep the allowlist in sync with _shared/cors.ts.
//
// Deploy: supabase functions deploy manage-featured   (KEEP JWT on)

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { failure } from "../_shared/errors.ts";

const ALLOWED_ORIGINS = new Set([
  "https://ads.joinnile.com",
  "https://links.joinnile.com",
]);

function corsHeadersFor(req: Request): Record<string, string> {
  const origin = req.headers.get("Origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ALLOWED_ORIGINS.has(origin)
      ? origin
      : "https://joinnile.com",
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Vary": "Origin",
  };
}

serve(async (req) => {
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

    // Admin gate — service-role read of the admins table (RLS-independent).
    const { data: adminRow } = await admin
      .from("admins").select("user_id").eq("user_id", user.id).maybeSingle();
    if (!adminRow) return json({ error: "Admins only" }, 403);

    const body = await req.json();
    const action = body?.action;

    if (action === "list") {
      const [events, creators] = await Promise.all([
        listEvents(admin),
        listCreators(admin),
      ]);
      return json({ events, creators });
    }

    if (action === "add") {
      const kind = validKind(body?.kind);
      const targetId = body?.target_id;
      if (!kind) return json({ error: "Invalid kind" }, 400);
      if (typeof targetId !== "string" || !targetId) {
        return json({ error: "Invalid target_id" }, 400);
      }
      // Confirm the target still exists before featuring it.
      const table = kind === "event" ? "events" : "profiles";
      const { data: target } = await admin
        .from(table).select("id").eq("id", targetId).maybeSingle();
      if (!target) return json({ error: "That item no longer exists" }, 404);

      const { data: existing } = await admin
        .from("featured_content").select("id")
        .eq("kind", kind).eq("target_id", targetId).maybeSingle();
      if (existing) return json({ error: "That's already featured" }, 409);

      const { data: last } = await admin
        .from("featured_content").select("position")
        .eq("kind", kind).order("position", { ascending: false }).limit(1);
      const nextPos = ((last?.[0]?.position as number | undefined) ?? -1) + 1;

      const { error: insErr } = await admin.from("featured_content").insert({
        kind, target_id: targetId, position: nextPos, created_by: user.id,
      });
      if (insErr) return json({ error: "Failed to feature" }, 500);
      return json({ ok: true });
    }

    if (action === "remove") {
      const kind = validKind(body?.kind);
      const targetId = body?.target_id;
      if (!kind) return json({ error: "Invalid kind" }, 400);
      if (typeof targetId !== "string" || !targetId) {
        return json({ error: "Invalid target_id" }, 400);
      }
      const { error: delErr } = await admin
        .from("featured_content").delete()
        .eq("kind", kind).eq("target_id", targetId);
      if (delErr) return json({ error: "Failed to remove" }, 500);
      return json({ ok: true });
    }

    if (action === "reorder") {
      const kind = validKind(body?.kind);
      const targetIds = body?.target_ids;
      if (!kind) return json({ error: "Invalid kind" }, 400);
      if (!Array.isArray(targetIds)) {
        return json({ error: "Invalid target_ids" }, 400);
      }
      // Persist each row's new position (its index in the ordered list).
      for (let i = 0; i < targetIds.length; i++) {
        const { error } = await admin
          .from("featured_content").update({ position: i })
          .eq("kind", kind).eq("target_id", targetIds[i]);
        if (error) return json({ error: "Failed to reorder" }, 500);
      }
      return json({ ok: true });
    }

    if (action === "search") {
      const kind = validKind(body?.kind);
      if (!kind) return json({ error: "Invalid kind" }, 400);
      const query = typeof body?.query === "string" ? body.query.trim() : "";
      const results = kind === "event"
        ? await searchEvents(admin, query)
        : await searchCreators(admin, query);
      return json({ results });
    }

    return json({ error: "Invalid action" }, 400);
  } catch (err) {
    console.error(err);
    return json(failure(err, "manage-featured"), 500);
  }
});

function validKind(k: unknown): "event" | "creator" | null {
  return k === "event" || k === "creator" ? k : null;
}

// ── Hydration helpers (service-role reads; bypass RLS) ──────────────────────

// deno-lint-ignore no-explicit-any
async function listEvents(admin: any) {
  const { data: rows } = await admin
    .from("featured_content")
    .select("target_id, position")
    .eq("kind", "event")
    .order("position", { ascending: true });
  const ids = (rows ?? []).map((r: any) => r.target_id);
  if (ids.length === 0) return [];
  const { data: events } = await admin
    .from("events")
    .select(
      "id, title, cover_image_url, status, scheduled_at, profiles!events_host_id_fkey(username)",
    )
    .in("id", ids);
  // The explicit <string, any> matters. `admin` is any, so the mapped array
  // is any too, and Map's constructor overloads resolve to Map<{}, {}> from
  // it — which makes every property read off byId.get() a type error. This
  // file has never passed deno check because of these two lines.
  const byId = new Map<string, any>((events ?? []).map((e: any) => [e.id, e]));
  return (rows ?? []).map((r: any) => {
    const e = byId.get(r.target_id);
    return {
      target_id: r.target_id,
      position: r.position,
      title: e?.title ?? "(deleted event)",
      cover_image_url: e?.cover_image_url ?? null,
      status: e?.status ?? null,
      scheduled_at: e?.scheduled_at ?? null,
      host_username: e?.profiles?.username ?? null,
      missing: !e,
    };
  });
}

// deno-lint-ignore no-explicit-any
async function listCreators(admin: any) {
  const { data: rows } = await admin
    .from("featured_content")
    .select("target_id, position")
    .eq("kind", "creator")
    .order("position", { ascending: true });
  const ids = (rows ?? []).map((r: any) => r.target_id);
  if (ids.length === 0) return [];
  const { data: profiles } = await admin
    .from("profiles")
    .select("id, username, display_name, avatar_url, follower_count")
    .in("id", ids);
  const byId = new Map<string, any>((profiles ?? []).map((p: any) => [p.id, p]));
  return (rows ?? []).map((r: any) => {
    const p = byId.get(r.target_id);
    return {
      target_id: r.target_id,
      position: r.position,
      username: p?.username ?? "(deleted)",
      display_name: p?.display_name ?? "(deleted creator)",
      avatar_url: p?.avatar_url ?? null,
      follower_count: p?.follower_count ?? 0,
      missing: !p,
    };
  });
}

// deno-lint-ignore no-explicit-any
async function searchEvents(admin: any, query: string) {
  let b = admin
    .from("events")
    .select(
      "id, title, cover_image_url, status, scheduled_at, profiles!events_host_id_fkey(username)",
    )
    .neq("status", "draft");
  if (query) b = b.ilike("title", `%${query}%`);
  const { data } = await b.order("created_at", { ascending: false }).limit(20);
  return (data ?? []).map((e: any) => ({
    target_id: e.id,
    title: e.title,
    cover_image_url: e.cover_image_url ?? null,
    status: e.status,
    scheduled_at: e.scheduled_at ?? null,
    host_username: e.profiles?.username ?? null,
  }));
}

// deno-lint-ignore no-explicit-any
async function searchCreators(admin: any, query: string) {
  let b = admin
    .from("profiles")
    .select("id, username, display_name, avatar_url, follower_count")
    .not("onboarded_at", "is", null);
  if (query) {
    b = b.or(`username.ilike.%${query}%,display_name.ilike.%${query}%`);
  }
  const { data } = await b
    .order("follower_count", { ascending: false })
    .limit(20);
  return (data ?? []).map((p: any) => ({
    target_id: p.id,
    username: p.username,
    display_name: p.display_name,
    avatar_url: p.avatar_url ?? null,
    follower_count: p.follower_count ?? 0,
  }));
}
