// Supabase Edge Function: share
//
// Serves the public web layer behind Nile's share links — the same
// https://links.nile.app/... URLs the app emits. Two jobs:
//
//   1. Deep-link verification files (so the OS opens links in-app):
//        GET /.well-known/apple-app-site-association   (iOS Universal Links)
//        GET /.well-known/assetlinks.json              (Android App Links)
//
//   2. Web landing pages with Open Graph / Twitter Card meta so a pasted link
//      unfurls into a rich preview in iMessage/WhatsApp/Slack/social, with a
//      JS fallback that bounces real humans to the app store / app:
//        GET /e/<eventId>
//        GET /p/<postId>
//        GET /u/<username>
//
// Deploy:
//   supabase functions deploy share --no-verify-jwt
//   (public — link unfurlers and browsers send no auth header)
//
// DNS: point links.nile.app at this function. Until then it's reachable at
//   https://<ref>.functions.supabase.co/share/<path>
// and the routing below tolerates the extra leading "/share" segment.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ── Native app identifiers (keep in sync with the app's native config) ──
const IOS_APP_ID = "LFRAVC4CVW.com.nilestreaming.app"; // <teamID>.<bundleID>
const ANDROID_PKG = "com.nilestreaming.app";
// SHA-256 fingerprint(s) of the Android signing cert. Replace the placeholder
// with the real value from: keytool -list -v -keystore <release.keystore>
// (Play App Signing: Play Console → Setup → App integrity).
const ANDROID_SHA256 =
  Deno.env.get("ANDROID_CERT_SHA256") ??
  "REPLACE_WITH_RELEASE_SHA256_FINGERPRINT";

// Store fallbacks for visitors without the app installed.
const APP_STORE_URL = "https://apps.apple.com/app/nile/id000000000"; // TODO real ID
const PLAY_STORE_URL =
  `https://play.google.com/store/apps/details?id=${ANDROID_PKG}`;
const SITE_NAME = "Nile";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

serve(async (req) => {
  // Normalize path; tolerate the "/share" prefix when hit via the raw
  // functions.supabase.co URL before DNS is pointed at links.nile.app.
  let segs = new URL(req.url).pathname.split("/").filter(Boolean);
  if (segs[0] === "share") segs = segs.slice(1);

  // ── .well-known verification files ──
  if (segs[0] === ".well-known") {
    if (segs[1] === "apple-app-site-association") return aasa();
    if (segs[1] === "assetlinks.json") return assetlinks();
    return new Response("Not found", { status: 404 });
  }

  const [kind, value] = segs;
  if (!kind || !value) return landingRedirect();

  try {
    if (kind === "e") return await eventPage(value);
    if (kind === "p") return await postPage(value);
    if (kind === "u") return await profilePage(value);
  } catch (_) {
    return html(genericPage(), 200);
  }
  return new Response("Not found", { status: 404 });
});

// ── .well-known responders ───────────────────────────────────────────────────

function aasa(): Response {
  const body = {
    applinks: {
      apps: [],
      details: [
        { appID: IOS_APP_ID, paths: ["/e/*", "/p/*", "/u/*"] },
      ],
    },
  };
  return new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json" },
  });
}

function assetlinks(): Response {
  const body = [
    {
      relation: ["delegate_permission/common.handle_all_urls"],
      target: {
        namespace: "android_app",
        package_name: ANDROID_PKG,
        sha256_cert_fingerprints: [ANDROID_SHA256],
      },
    },
  ];
  return new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json" },
  });
}

// ── Landing pages ────────────────────────────────────────────────────────────

async function eventPage(id: string): Promise<Response> {
  const { data } = await admin
    .from("events")
    .select("title, description, cover_image_url, host:profiles!events_host_id_fkey(username)")
    .eq("id", id)
    .maybeSingle();
  if (!data) return html(genericPage(), 404);
  const host = (data.host as { username?: string } | null)?.username;
  return html(page({
    title: data.title ?? "Event on Nile",
    description: data.description ?? (host ? `Hosted by @${host} on Nile` : "Watch on Nile"),
    image: data.cover_image_url ?? null,
    canonical: `/e/${id}`,
  }));
}

async function postPage(id: string): Promise<Response> {
  const { data } = await admin
    .from("posts")
    .select("content, image_url, author:profiles!posts_user_id_fkey(username, display_name)")
    .eq("id", id)
    .maybeSingle();
  if (!data) return html(genericPage(), 404);
  const author = data.author as { username?: string; display_name?: string } | null;
  const who = author?.display_name || (author?.username ? `@${author.username}` : "Someone");
  return html(page({
    title: `${who} on Nile`,
    description: data.content ?? "See this post on Nile",
    image: data.image_url ?? null,
    canonical: `/p/${id}`,
  }));
}

async function profilePage(username: string): Promise<Response> {
  const { data } = await admin
    .from("profiles")
    .select("username, display_name, bio, avatar_url")
    .ilike("username", username)
    .maybeSingle();
  if (!data) return html(genericPage(), 404);
  const name = data.display_name || `@${data.username}`;
  return html(page({
    title: `${name} (@${data.username}) on Nile`,
    description: data.bio ?? `Follow @${data.username} on Nile`,
    image: data.avatar_url ?? null,
    canonical: `/u/${data.username}`,
  }));
}

// ── HTML rendering ───────────────────────────────────────────────────────────

interface Meta {
  title: string;
  description: string;
  image: string | null;
  canonical: string;
}

function page(m: Meta): string {
  const t = esc(m.title);
  const d = esc(truncate(m.description, 200));
  const url = `https://links.nile.app${m.canonical}`;
  const img = m.image ? esc(m.image) : "";
  const imgTags = img
    ? `<meta property="og:image" content="${img}"/>
    <meta name="twitter:card" content="summary_large_image"/>
    <meta name="twitter:image" content="${img}"/>`
    : `<meta name="twitter:card" content="summary"/>`;
  return `<!doctype html><html lang="en"><head>
    <meta charset="utf-8"/>
    <meta name="viewport" content="width=device-width,initial-scale=1"/>
    <title>${t}</title>
    <meta name="description" content="${d}"/>
    <link rel="canonical" href="${url}"/>
    <meta property="og:type" content="website"/>
    <meta property="og:site_name" content="${SITE_NAME}"/>
    <meta property="og:title" content="${t}"/>
    <meta property="og:description" content="${d}"/>
    <meta property="og:url" content="${url}"/>
    <meta name="twitter:title" content="${t}"/>
    <meta name="twitter:description" content="${d}"/>
    ${imgTags}
    ${storeRedirectScript()}
    <style>
      body{margin:0;background:#0A0A0A;color:#fff;font-family:-apple-system,system-ui,sans-serif;
        display:flex;min-height:100vh;align-items:center;justify-content:center;text-align:center;padding:24px}
      .card{max-width:480px}
      ${img ? `.cover{width:100%;max-width:360px;border-radius:16px;margin:0 0 20px;object-fit:cover}` : ""}
      h1{font-size:24px;margin:0 0 8px}
      p{color:#A1A1AA;margin:0 0 24px;line-height:1.5}
      a.cta{display:inline-block;background:#C8FF00;color:#0A0A0A;font-weight:700;
        text-decoration:none;padding:14px 28px;border-radius:999px}
    </style></head><body><div class="card">
    ${img ? `<img class="cover" src="${img}" alt=""/>` : ""}
    <h1>${t}</h1><p>${d}</p>
    <a class="cta" href="${url}">Open in ${SITE_NAME}</a>
    </div></body></html>`;
}

// Client-side: try the app first (custom scheme deep link); if it doesn't take
// focus, bounce to the right app store. Skipped for bots/unfurlers (no UA match
// needed — they don't run JS, so they keep the OG tags above).
function storeRedirectScript(): string {
  return `<script>
    (function(){
      var p=location.pathname.replace(/^\\/share/,'').split('/').filter(Boolean);
      var kind=p[0], val=p[1];
      if(!kind||!val) return;
      var scheme = kind==='e' ? 'nile://event/'+val
                 : kind==='p' ? 'nile://post/'+val : null;
      var ua=navigator.userAgent||'';
      var store = /android/i.test(ua) ? ${JSON.stringify(PLAY_STORE_URL)}
                : /iphone|ipad|ipod/i.test(ua) ? ${JSON.stringify(APP_STORE_URL)} : null;
      if(!store) return; // desktop: leave the landing page up
      var t=Date.now();
      if(scheme){ window.location.href=scheme; }
      setTimeout(function(){ if(Date.now()-t<1600) window.location.href=store; }, 1200);
    })();
  </script>`;
}

function genericPage(): string {
  return page({
    title: SITE_NAME,
    description: "Live events and posts on Nile.",
    image: null,
    canonical: "/",
  });
}

function landingRedirect(): Response {
  return html(genericPage(), 200);
}

// ── helpers ──

function html(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: { "content-type": "text/html; charset=utf-8" },
  });
}

function esc(s: string): string {
  return s
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function truncate(s: string, n: number): string {
  return s.length <= n ? s : s.slice(0, n - 1).trimEnd() + "…";
}
