// Supabase Edge Function: dm-image-url (security hardening fix #3)
//
// The messages bucket is private; DM image attachments are served via
// short-lived signed URLs. Given a message id, this verifies the caller is a
// participant of that message's conversation, then returns a ~1h signed URL
// for the attachment. Stored image_url values are the legacy public-style
// URLs — the object path is extracted from them.
//
// Request (POST, Bearer = user JWT): { "message_id": "uuid" }
// Response: { "url": "https://...signed..." } or { "error": "..." }

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

const SIGNED_URL_TTL_SECONDS = 3600;

serve(async (req) => {
  const cors = corsHeaders(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Missing Authorization header" }, 401);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return json({ error: "Unauthorized" }, 401);

    const { message_id } = await req.json();
    if (!message_id) return json({ error: "message_id required" }, 400);

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: msg } = await admin
      .from("messages")
      .select("image_url, conversation_id")
      .eq("id", message_id)
      .maybeSingle();
    if (!msg?.image_url) return json({ error: "Not found" }, 404);

    const { data: conv } = await admin
      .from("conversations")
      .select("participant_a, participant_b")
      .eq("id", msg.conversation_id)
      .maybeSingle();
    if (
      !conv ||
      (conv.participant_a !== user.id && conv.participant_b !== user.id)
    ) {
      return json({ error: "Not found" }, 404); // don't leak existence
    }

    // image_url is "{SUPABASE_URL}/storage/v1/object/public/messages/{path}"
    // (legacy public-style). Fall back to treating the value as a bare path.
    const marker = "/storage/v1/object/public/messages/";
    const i = (msg.image_url as string).indexOf(marker);
    const path = i >= 0
      ? decodeURIComponent(msg.image_url.slice(i + marker.length).split("?")[0])
      : msg.image_url;

    const { data: signed, error: signError } = await admin.storage
      .from("messages")
      .createSignedUrl(path, SIGNED_URL_TTL_SECONDS);
    if (signError || !signed?.signedUrl) {
      return json({ error: "Could not sign URL" }, 500);
    }

    return json({ url: signed.signedUrl });
  } catch (err) {
    console.error(err);
    return json({ error: String(err) }, 500);
  }
});
