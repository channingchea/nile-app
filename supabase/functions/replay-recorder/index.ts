// replay-recorder — Nile's recorder page (LiveKit's recording browser, see
// recorder/index.html) reports the grid replay's tile layout and overlay
// changes here. No user session: the page proves itself with the recorder key
// that travels in its URL (replay_grids.recorder_key). Deployed with
// --no-verify-jwt; plain-text POST so the page needs no CORS preflight.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cleanUpload } from "../_shared/replay_marks.ts";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "content-type",
      "Content-Type": "application/json",
    },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return reply({});
  if (req.method !== "POST") return reply({ error: "POST only" }, 405);

  let body: unknown;
  try {
    body = JSON.parse(await req.text());
  } catch {
    return reply({ error: "bad json" }, 400);
  }
  const upload = cleanUpload(body);
  if ("error" in upload) return reply(upload, 400);

  // A late final upload can land after egress_ended marked the grid ready.
  const { data: grid } = await admin
    .from("replay_grids")
    .select("id, status, created_at")
    .eq("recorder_key", upload.key)
    .maybeSingle();
  const fresh = grid && Date.now() - Date.parse(grid.created_at) < 14 * 60 * 60 * 1000;
  if (!grid || grid.status === "failed" || !fresh) return reply({ error: "unknown recorder" }, 404);

  const rows = upload.marks.map((m) => ({ grid_id: grid.id, ...m }));
  if (rows.length) {
    const { error } = await admin
      .from("replay_marks")
      .upsert(rows, { onConflict: "grid_id,seq", ignoreDuplicates: true });
    if (error) {
      console.error(JSON.stringify({ fn: "replay-recorder", error: error.message }));
      return reply({ error: "store failed" }, 500);
    }
    const start = upload.marks.find((m) => m.kind === "start");
    if (start) {
      await admin
        .from("replay_grids")
        .update({ recorder_started_at: new Date((start.data as { wall: number }).wall).toISOString() })
        .eq("id", grid.id)
        .is("recorder_started_at", null);
    }
  }
  return reply({ ok: true, stored: rows.length });
});
