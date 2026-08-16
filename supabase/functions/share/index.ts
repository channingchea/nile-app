// Supabase Edge Function: share
//
// Serves the public web layer behind Nile's share links — the same
// https://links.joinnile.com/... URLs the app emits. Jobs:
//
//   1. Deep-link verification files (so the OS opens links in-app):
//        GET /.well-known/apple-app-site-association   (iOS Universal Links)
//        GET /.well-known/assetlinks.json              (Android App Links)
//
//   2. Web landing pages with Open Graph / Twitter Card meta:
//        GET /e/<eventId>   GET /p/<postId>   GET /u/<username>
//
//   3. Ad-platform host-boost portal (A-2), checkout on the web (off IAP):
//        GET /boost?event=<id>   → serves the standalone boost portal page.
//
// Deploy: supabase functions deploy share --no-verify-jwt  (public endpoint)

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ── Native app identifiers (keep in sync with the app's native config) ──
// <teamID>.<bundleID>. The team id MUST match what the app is actually signed
// with, or iOS silently refuses to associate the domain and every Universal
// Link falls through to the browser. Was LFRAVC4CVW until 2026-08-16 — stale
// since the signing team changed on 2026-08-06; verified against the signed
// binary (`codesign -d --entitlements :-` → application-identifier
// 9LTD86C5X7.com.nilestreaming.app) and DEVELOPMENT_TEAM in project.pbxproj.
const IOS_APP_ID = "9LTD86C5X7.com.nilestreaming.app";
const ANDROID_PKG = "com.nilestreaming.app";
// Comma-separated, because Play App Signing means TWO certificates sign Nile
// builds and App Links must verify against both:
//   • the UPLOAD key   — signs local + Firebase App Distribution builds
//   • the Play app signing key — signs whatever users install from Play
//     (Play Console → Test and release → Setup → App integrity)
// Set with: supabase secrets set ANDROID_CERT_SHA256="AA:BB:...,CC:DD:..."
const ANDROID_SHA256 = (
  Deno.env.get("ANDROID_CERT_SHA256") ??
    "REPLACE_WITH_RELEASE_SHA256_FINGERPRINT"
)
  .split(",")
  .map((f) => f.trim().toUpperCase())
  .filter((f) => f.length > 0);

const APP_STORE_URL = "https://apps.apple.com/app/nile/id000000000"; // TODO real ID
const PLAY_STORE_URL =
  `https://play.google.com/store/apps/details?id=${ANDROID_PKG}`;
const SITE_NAME = "Nile";

// Host-boost portal (A-2). Standalone HTML, base64-embedded to avoid template
// escaping. Source of truth: nile_app/web_portal/boost.html — keep in sync.
const BOOST_HTML_B64 = "PCFkb2N0eXBlIGh0bWw+CjxodG1sIGxhbmc9ImVuIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9InV0Zi04IiAvPgo8bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEsIHZpZXdwb3J0LWZpdD1jb3ZlciIgLz4KPG1ldGEgbmFtZT0icm9ib3RzIiBjb250ZW50PSJub2luZGV4IiAvPgo8dGl0bGU+Qm9vc3QgeW91ciBldmVudCDCtyBOaWxlPC90aXRsZT4KPCEtLQogIE5pbGUgYWQgcG9ydGFsIOKAlCBQaGFzZSBBLTIgaG9zdC1ib29zdCBjaGVja291dCAod2ViIG9ubHksIG9mZiB0aGUgQXBwIFN0b3JlKS4KICBTdGFuZGFsb25lIHBhZ2UgaG9zdGVkIGF0IGh0dHBzOi8vbGlua3MubmlsZS5hcHAvYm9vc3QuIFRoZSBpbi1hcHAgIkJvb3N0IgogIGJ1dHRvbiBkZWVwLWxpbmtzIGhlcmUgaW4gdGhlIEVYVEVSTkFMIGJyb3dzZXIgKG5vIGluLWFwcCB3ZWJ2aWV3KSwgc28gbm8KICBpT1MgSUFQIHBhdGggZXhpc3RzLiBIb3N0IHNpZ25zIGluLCBwaWNrcyBhICQxMC8kMjUvJDUwIGJ1ZGdldCArIGR1cmF0aW9uLAogIGFuZCBpcyByZWRpcmVjdGVkIHRvIFN0cmlwZSBDaGVja291dCB2aWEgdGhlIGNyZWF0ZS1hZC1wYXltZW50IEVkZ2UgRnVuY3Rpb24uCgogIERlbGliZXJhdGVseSBmcmFtZXdvcmstZnJlZSBhbmQgc2VsZi1jb250YWluZWQgc28gaXQgY2FuIGxhdGVyIGJlIGxpZnRlZCBpbnRvCiAgYSBWdWUuanMgc2l0ZSBvbiBjMWdudXMuY29tOiB0aGUgbG9naWMgbGl2ZXMgaW4gc21hbGwgZnVuY3Rpb25zIChib290L2F1dGgvCiAgbG9hZEV2ZW50L2NoZWNrb3V0KSB0aGF0IG1hcCBjbGVhbmx5IG9udG8gYSBjb21wb25lbnQuIEZpbGwgQ09ORklHIGJlbG93IGF0CiAgZGVwbG95IHRpbWUgKGFub24ga2V5IGlzIHB1YmxpYy9zYWZlIHRvIHNoaXA7IG5ldmVyIHB1dCB0aGUgc2VydmljZSByb2xlIGhlcmUpLgotLT4KPHN0eWxlPgogIDpyb290IHsKICAgIC0tYmc6IzBBMEEwQTsgLS1zdXJmYWNlOiMxODE4MUI7IC0tcmFpc2VkOiMyNzI3MkE7IC0tYm9yZGVyOiMzRjNGNDY7CiAgICAtLXZvbHQ6I0M4RkYwMDsgLS10eHQ6I0ZBRkFGQTsgLS10eHQyOiNBMUExQUE7IC0tdHh0MzojNzE3MTdBOyAtLXJhZGl1czoxNnB4OwogIH0KICAqIHsgYm94LXNpemluZzpib3JkZXItYm94OyB9CiAgYm9keSB7CiAgICBtYXJnaW46MDsgYmFja2dyb3VuZDp2YXIoLS1iZyk7IGNvbG9yOnZhcigtLXR4dCk7IG1pbi1oZWlnaHQ6MTAwdmg7CiAgICBmb250LWZhbWlseTotYXBwbGUtc3lzdGVtLEJsaW5rTWFjU3lzdGVtRm9udCwiU2Vnb2UgVUkiLFJvYm90byxzYW5zLXNlcmlmOwogICAgZGlzcGxheTpmbGV4OyBhbGlnbi1pdGVtczpmbGV4LXN0YXJ0OyBqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyOyBwYWRkaW5nOjI0cHg7CiAgfQogIC5jYXJkIHsgd2lkdGg6MTAwJTsgbWF4LXdpZHRoOjQ0MHB4OyB9CiAgaDEgeyBmb250LXNpemU6MjhweDsgbWFyZ2luOjAgMCA0cHg7IGxldHRlci1zcGFjaW5nOi0wLjAyZW07IH0KICAuc3ViIHsgY29sb3I6dmFyKC0tdHh0Mik7IG1hcmdpbjowIDAgMjRweDsgZm9udC1zaXplOjE1cHg7IH0KICAuZXZlbnQgewogICAgYmFja2dyb3VuZDp2YXIoLS1zdXJmYWNlKTsgYm9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpOwogICAgYm9yZGVyLXJhZGl1czp2YXIoLS1yYWRpdXMpOyBwYWRkaW5nOjE2cHg7IG1hcmdpbi1ib3R0b206MjRweDsKICAgIGRpc3BsYXk6ZmxleDsgZ2FwOjEycHg7IGFsaWduLWl0ZW1zOmNlbnRlcjsKICB9CiAgLmV2ZW50IGltZyB7IHdpZHRoOjY0cHg7IGhlaWdodDozNnB4OyBvYmplY3QtZml0OmNvdmVyOyBib3JkZXItcmFkaXVzOjhweDsgYmFja2dyb3VuZDp2YXIoLS1yYWlzZWQpOyBmbGV4OjAgMCBhdXRvOyB9CiAgLmV2ZW50IC50aXRsZSB7IGZvbnQtd2VpZ2h0OjYwMDsgZm9udC1zaXplOjE1cHg7IGxpbmUtaGVpZ2h0OjEuMzsgfQogIC5ldmVudCAuaG9zdCB7IGNvbG9yOnZhcigtLXR4dDMpOyBmb250LXNpemU6MTNweDsgbWFyZ2luLXRvcDoycHg7IH0KICAubGFiZWwgeyBmb250LXNpemU6MTNweDsgY29sb3I6dmFyKC0tdHh0Mik7IG1hcmdpbjowIDAgOHB4OyB0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7IGxldHRlci1zcGFjaW5nOjAuMDRlbTsgfQogIC5ncmlkIHsgZGlzcGxheTpncmlkOyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6cmVwZWF0KDMsMWZyKTsgZ2FwOjEwcHg7IG1hcmdpbi1ib3R0b206MjRweDsgfQogIC5vcHQgewogICAgYmFja2dyb3VuZDp2YXIoLS1zdXJmYWNlKTsgYm9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpOyBib3JkZXItcmFkaXVzOnZhcigtLXJhZGl1cyk7CiAgICBwYWRkaW5nOjE2cHggOHB4OyB0ZXh0LWFsaWduOmNlbnRlcjsgY3Vyc29yOnBvaW50ZXI7IHRyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4xNXMsYmFja2dyb3VuZCAuMTVzOwogICAgZm9udC1zaXplOjE4cHg7IGZvbnQtd2VpZ2h0OjYwMDsgdXNlci1zZWxlY3Q6bm9uZTsKICB9CiAgLm9wdCBzbWFsbCB7IGRpc3BsYXk6YmxvY2s7IGNvbG9yOnZhcigtLXR4dDMpOyBmb250LXdlaWdodDo0MDA7IGZvbnQtc2l6ZToxMnB4OyBtYXJnaW4tdG9wOjRweDsgfQogIC5vcHRbYXJpYS1zZWxlY3RlZD0idHJ1ZSJdIHsgYm9yZGVyLWNvbG9yOnZhcigtLXZvbHQpOyBiYWNrZ3JvdW5kOnJnYmEoMjAwLDI1NSwwLDAuMDgpOyB9CiAgYnV0dG9uLmN0YSB7CiAgICB3aWR0aDoxMDAlOyBiYWNrZ3JvdW5kOnZhcigtLXZvbHQpOyBjb2xvcjojMEEwQTBBOyBib3JkZXI6bm9uZTsgYm9yZGVyLXJhZGl1czo5OTlweDsKICAgIHBhZGRpbmc6MTZweDsgZm9udC1zaXplOjE2cHg7IGZvbnQtd2VpZ2h0OjcwMDsgY3Vyc29yOnBvaW50ZXI7IHRyYW5zaXRpb246b3BhY2l0eSAuMTVzOwogIH0KICBidXR0b24uY3RhOmRpc2FibGVkIHsgb3BhY2l0eTowLjQ7IGN1cnNvcjpub3QtYWxsb3dlZDsgfQogIC5ub3RlIHsgY29sb3I6dmFyKC0tdHh0Myk7IGZvbnQtc2l6ZToxMnB4OyB0ZXh0LWFsaWduOmNlbnRlcjsgbWFyZ2luLXRvcDoxNHB4OyBsaW5lLWhlaWdodDoxLjU7IH0KICAubXNnIHsgcGFkZGluZzoxNHB4IDE2cHg7IGJvcmRlci1yYWRpdXM6MTJweDsgZm9udC1zaXplOjE0cHg7IG1hcmdpbi1ib3R0b206MTZweDsgfQogIC5tc2cuZXJyIHsgYmFja2dyb3VuZDpyZ2JhKDI1NSw3NywxMDksMC4xMik7IGNvbG9yOiNGRjk5QUQ7IGJvcmRlcjoxcHggc29saWQgcmdiYSgyNTUsNzcsMTA5LDAuMyk7IH0KICAuY2VudGVyIHsgdGV4dC1hbGlnbjpjZW50ZXI7IGNvbG9yOnZhcigtLXR4dDIpOyBwYWRkaW5nOjQ4cHggMDsgfQogIGlucHV0W3R5cGU9ZW1haWxdLGlucHV0W3R5cGU9cGFzc3dvcmRdewogICAgd2lkdGg6MTAwJTsgYmFja2dyb3VuZDp2YXIoLS1yYWlzZWQpOyBib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7IGNvbG9yOnZhcigtLXR4dCk7CiAgICBib3JkZXItcmFkaXVzOjEycHg7IHBhZGRpbmc6MTRweDsgZm9udC1zaXplOjE1cHg7IG1hcmdpbi1ib3R0b206MTBweDsKICB9CiAgLmhpZGRlbiB7IGRpc3BsYXk6bm9uZTsgfQo8L3N0eWxlPgo8L2hlYWQ+Cjxib2R5Pgo8ZGl2IGNsYXNzPSJjYXJkIj4KICA8aDE+Qm9vc3QgeW91ciBldmVudDwvaDE+CiAgPHAgY2xhc3M9InN1YiI+UHJvbW90ZSB5b3VyIGV2ZW50IGluIHRoZSBOaWxlIGZlZWQuPC9wPgoKICA8ZGl2IGlkPSJtc2ciPjwvZGl2PgoKICA8IS0tIFNpZ24taW4gKHNob3duIHdoZW4gbm8gc2Vzc2lvbikgLS0+CiAgPGZvcm0gaWQ9ImF1dGgiIGNsYXNzPSJoaWRkZW4iIGF1dG9jb21wbGV0ZT0ib24iPgogICAgPHAgY2xhc3M9ImxhYmVsIj5TaWduIGluIHRvIHlvdXIgTmlsZSBhY2NvdW50PC9wPgogICAgPGlucHV0IGlkPSJlbWFpbCIgdHlwZT0iZW1haWwiIHBsYWNlaG9sZGVyPSJFbWFpbCIgcmVxdWlyZWQgLz4KICAgIDxpbnB1dCBpZD0icGFzc3dvcmQiIHR5cGU9InBhc3N3b3JkIiBwbGFjZWhvbGRlcj0iUGFzc3dvcmQiIHJlcXVpcmVkIC8+CiAgICA8YnV0dG9uIGNsYXNzPSJjdGEiIHR5cGU9InN1Ym1pdCI+U2lnbiBpbjwvYnV0dG9uPgogIDwvZm9ybT4KCiAgPCEtLSBCb29zdCBmbG93IChzaG93biB3aGVuIHNpZ25lZCBpbiArIGV2ZW50IGxvYWRlZCkgLS0+CiAgPGRpdiBpZD0iZmxvdyIgY2xhc3M9ImhpZGRlbiI+CiAgICA8ZGl2IGNsYXNzPSJldmVudCIgaWQ9ImV2ZW50Ij48L2Rpdj4KCiAgICA8cCBjbGFzcz0ibGFiZWwiPkJ1ZGdldDwvcD4KICAgIDxkaXYgY2xhc3M9ImdyaWQiIGlkPSJidWRnZXRzIj4KICAgICAgPGRpdiBjbGFzcz0ib3B0IiBkYXRhLWNlbnRzPSIxMDAwIiByb2xlPSJidXR0b24iIGFyaWEtc2VsZWN0ZWQ9ImZhbHNlIj4kMTA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ib3B0IiBkYXRhLWNlbnRzPSIyNTAwIiByb2xlPSJidXR0b24iIGFyaWEtc2VsZWN0ZWQ9InRydWUiPiQyNTwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJvcHQiIGRhdGEtY2VudHM9IjUwMDAiIHJvbGU9ImJ1dHRvbiIgYXJpYS1zZWxlY3RlZD0iZmFsc2UiPiQ1MDwvZGl2PgogICAgPC9kaXY+CgogICAgPHAgY2xhc3M9ImxhYmVsIj5EdXJhdGlvbjwvcD4KICAgIDxkaXYgY2xhc3M9ImdyaWQiIGlkPSJkdXJhdGlvbnMiPgogICAgICA8ZGl2IGNsYXNzPSJvcHQiIGRhdGEtZGF5cz0iMyIgcm9sZT0iYnV0dG9uIiBhcmlhLXNlbGVjdGVkPSJmYWxzZSI+MyBkYXlzPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9Im9wdCIgZGF0YS1kYXlzPSI3IiByb2xlPSJidXR0b24iIGFyaWEtc2VsZWN0ZWQ9InRydWUiPjcgZGF5czwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJvcHQiIGRhdGEtZGF5cz0iMTQiIHJvbGU9ImJ1dHRvbiIgYXJpYS1zZWxlY3RlZD0iZmFsc2UiPjE0IGRheXM8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxidXR0b24gY2xhc3M9ImN0YSIgaWQ9InBheSI+Q29udGludWUgdG8gcGF5bWVudDwvYnV0dG9uPgogICAgPHAgY2xhc3M9Im5vdGUiPllvdSdsbCBiZSByZWRpcmVjdGVkIHRvIFN0cmlwZSB0byBwYXkgc2VjdXJlbHkuIFBheW1lbnRzIGFyZSBwcm9jZXNzZWQgb24gdGhlIHdlYjsgeW91IGtlZXAgZnVsbCBjb250cm9sIG9mIHlvdXIgZXZlbnQuPC9wPgogIDwvZGl2PgoKICA8ZGl2IGlkPSJsb2FkaW5nIiBjbGFzcz0iY2VudGVyIj5Mb2FkaW5n4oCmPC9kaXY+CjwvZGl2PgoKPHNjcmlwdCB0eXBlPSJtb2R1bGUiPgppbXBvcnQgeyBjcmVhdGVDbGllbnQgfSBmcm9tICJodHRwczovL2VzbS5zaC9Ac3VwYWJhc2Uvc3VwYWJhc2UtanNAMiI7CgovLyDilIDilIAgQ09ORklHIChmaWxsIGF0IGRlcGxveSB0aW1lOyBhbm9uIGtleSBpcyBwdWJsaWMtc2FmZSkg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmNvbnN0IENPTkZJRyA9IHsKICBTVVBBQkFTRV9VUkw6ICJodHRwczovL2plbG1ra3Z5cmxpeXdjZGt6aHV1LnN1cGFiYXNlLmNvIiwKICBTVVBBQkFTRV9BTk9OX0tFWTogImV5SmhiR2NpT2lKSVV6STFOaUlzSW5SNWNDSTZJa3BYVkNKOS5leUpwYzNNaU9pSnpkWEJoWW1GelpTSXNJbkpsWmlJNkltcGxiRzFyYTNaNWNteHBlWGRqWkd0NmFIVjFJaXdpY205c1pTSTZJbUZ1YjI0aUxDSnBZWFFpT2pFM056azRORE00TkRNc0ltVjRjQ0k2TWpBNU5UUXhPVGcwTTMwLmZKVmtta1E2OTlKdllabDlQeVNYV1dpTWxmTVFOdjFmWmNZT3R0QzV2YkkiLAogIEZVTkNUSU9OX1VSTDogImh0dHBzOi8vamVsbWtrdnlybGl5d2Nka3podXUuZnVuY3Rpb25zLnN1cGFiYXNlLmNvL2NyZWF0ZS1hZC1wYXltZW50IiwKfTsKCmNvbnN0IHNiID0gY3JlYXRlQ2xpZW50KENPTkZJRy5TVVBBQkFTRV9VUkwsIENPTkZJRy5TVVBBQkFTRV9BTk9OX0tFWSk7CmNvbnN0ICQgPSAoaWQpID0+IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKY29uc3QgZXZlbnRJZCA9IG5ldyBVUkwobG9jYXRpb24uaHJlZikuc2VhcmNoUGFyYW1zLmdldCgiZXZlbnQiKTsKCmxldCBidWRnZXRDZW50cyA9IDI1MDA7CmxldCBkdXJhdGlvbkRheXMgPSA3OwoKZnVuY3Rpb24gc2hvd01zZyh0ZXh0KSB7ICQoIm1zZyIpLmlubmVySFRNTCA9IHRleHQgPyBgPGRpdiBjbGFzcz0ibXNnIGVyciI+JHt0ZXh0fTwvZGl2PmAgOiAiIjsgfQpmdW5jdGlvbiBzaG93KGVsKSB7ICQoZWwpLmNsYXNzTGlzdC5yZW1vdmUoImhpZGRlbiIpOyB9CmZ1bmN0aW9uIGhpZGUoZWwpIHsgJChlbCkuY2xhc3NMaXN0LmFkZCgiaGlkZGVuIik7IH0KCi8vIFRvZ2dsZS1zZWxlY3Rpb24gd2lyaW5nIGZvciB0aGUgcHJlc2V0IGdyaWRzLgpmdW5jdGlvbiB3aXJlR3JpZChncmlkSWQsIGF0dHIsIHNldCkgewogICQoZ3JpZElkKS5xdWVyeVNlbGVjdG9yQWxsKCIub3B0IikuZm9yRWFjaCgob3B0KSA9PiB7CiAgICBvcHQuYWRkRXZlbnRMaXN0ZW5lcigiY2xpY2siLCAoKSA9PiB7CiAgICAgICQoZ3JpZElkKS5xdWVyeVNlbGVjdG9yQWxsKCIub3B0IikuZm9yRWFjaCgobykgPT4gby5zZXRBdHRyaWJ1dGUoImFyaWEtc2VsZWN0ZWQiLCAiZmFsc2UiKSk7CiAgICAgIG9wdC5zZXRBdHRyaWJ1dGUoImFyaWEtc2VsZWN0ZWQiLCAidHJ1ZSIpOwogICAgICBzZXQoTnVtYmVyKG9wdC5kYXRhc2V0W2F0dHJdKSk7CiAgICB9KTsKICB9KTsKfQp3aXJlR3JpZCgiYnVkZ2V0cyIsICJjZW50cyIsICh2KSA9PiAoYnVkZ2V0Q2VudHMgPSB2KSk7CndpcmVHcmlkKCJkdXJhdGlvbnMiLCAiZGF5cyIsICh2KSA9PiAoZHVyYXRpb25EYXlzID0gdikpOwoKYXN5bmMgZnVuY3Rpb24gYm9vdCgpIHsKICBpZiAoIWV2ZW50SWQpIHsgaGlkZSgibG9hZGluZyIpOyBzaG93TXNnKCJNaXNzaW5nIGV2ZW50LiBPcGVuIEJvb3N0IGZyb20geW91ciBldmVudCBpbiB0aGUgYXBwLiIpOyByZXR1cm47IH0KICBjb25zdCB7IGRhdGE6IHsgc2Vzc2lvbiB9IH0gPSBhd2FpdCBzYi5hdXRoLmdldFNlc3Npb24oKTsKICBpZiAoIXNlc3Npb24pIHsgaGlkZSgibG9hZGluZyIpOyBzaG93KCJhdXRoIik7IHJldHVybjsgfQogIGF3YWl0IGxvYWRFdmVudCgpOwp9CgokKCJhdXRoIikuYWRkRXZlbnRMaXN0ZW5lcigic3VibWl0IiwgYXN5bmMgKGUpID0+IHsKICBlLnByZXZlbnREZWZhdWx0KCk7CiAgc2hvd01zZygiIik7CiAgY29uc3QgeyBlcnJvciB9ID0gYXdhaXQgc2IuYXV0aC5zaWduSW5XaXRoUGFzc3dvcmQoeyBlbWFpbDogJCgiZW1haWwiKS52YWx1ZSwgcGFzc3dvcmQ6ICQoInBhc3N3b3JkIikudmFsdWUgfSk7CiAgaWYgKGVycm9yKSB7IHNob3dNc2coZXJyb3IubWVzc2FnZSk7IHJldHVybjsgfQogIGhpZGUoImF1dGgiKTsgc2hvdygibG9hZGluZyIpOyBhd2FpdCBsb2FkRXZlbnQoKTsKfSk7Cgphc3luYyBmdW5jdGlvbiBsb2FkRXZlbnQoKSB7CiAgc2hvd01zZygiIik7CiAgLy8gUkxTIGxldHMgdGhlIGhvc3QgcmVhZCB0aGVpciBvd24gZXZlbnQ7IHRoZSBmdW5jdGlvbiByZS1jaGVja3Mgb3duZXJzaGlwLgogIGNvbnN0IHsgZGF0YTogZXYsIGVycm9yIH0gPSBhd2FpdCBzYgogICAgLmZyb20oImV2ZW50cyIpCiAgICAuc2VsZWN0KCJpZCwgdGl0bGUsIGhvc3RfaWQsIGNvdmVyX2ltYWdlX3VybCwgcHJvZmlsZXMhZXZlbnRzX2hvc3RfaWRfZmtleSh1c2VybmFtZSkiKQogICAgLmVxKCJpZCIsIGV2ZW50SWQpCiAgICAubWF5YmVTaW5nbGUoKTsKICBoaWRlKCJsb2FkaW5nIik7CiAgaWYgKGVycm9yIHx8ICFldikgeyBzaG93TXNnKCJDb3VsZG4ndCBsb2FkIHRoYXQgZXZlbnQuIik7IHJldHVybjsgfQogIGNvbnN0IGNvdmVyID0gZXYuY292ZXJfaW1hZ2VfdXJsCiAgICA/IGA8aW1nIHNyYz0iJHtldi5jb3Zlcl9pbWFnZV91cmx9IiBhbHQ9IiIgLz5gCiAgICA6IGA8ZGl2IHN0eWxlPSJ3aWR0aDo2NHB4O2hlaWdodDozNnB4O2JvcmRlci1yYWRpdXM6OHB4O2JhY2tncm91bmQ6dmFyKC0tcmFpc2VkKTtmbGV4OjAgMCBhdXRvIj48L2Rpdj5gOwogICQoImV2ZW50IikuaW5uZXJIVE1MID0gYCR7Y292ZXJ9PGRpdj48ZGl2IGNsYXNzPSJ0aXRsZSI+JHtldi50aXRsZX08L2Rpdj48ZGl2IGNsYXNzPSJob3N0Ij5AJHtldi5wcm9maWxlcz8udXNlcm5hbWUgPz8gInlvdSJ9PC9kaXY+PC9kaXY+YDsKICBzaG93KCJmbG93Iik7Cn0KCiQoInBheSIpLmFkZEV2ZW50TGlzdGVuZXIoImNsaWNrIiwgYXN5bmMgKCkgPT4gewogIHNob3dNc2coIiIpOwogICQoInBheSIpLmRpc2FibGVkID0gdHJ1ZTsgJCgicGF5IikudGV4dENvbnRlbnQgPSAiUmVkaXJlY3RpbmfigKYiOwogIHRyeSB7CiAgICBjb25zdCB7IGRhdGE6IHsgc2Vzc2lvbiB9IH0gPSBhd2FpdCBzYi5hdXRoLmdldFNlc3Npb24oKTsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IGZldGNoKENPTkZJRy5GVU5DVElPTl9VUkwsIHsKICAgICAgbWV0aG9kOiAiUE9TVCIsCiAgICAgIGhlYWRlcnM6IHsgIkNvbnRlbnQtVHlwZSI6ICJhcHBsaWNhdGlvbi9qc29uIiwgQXV0aG9yaXphdGlvbjogYEJlYXJlciAke3Nlc3Npb24uYWNjZXNzX3Rva2VufWAgfSwKICAgICAgYm9keTogSlNPTi5zdHJpbmdpZnkoeyBldmVudF9pZDogZXZlbnRJZCwgYnVkZ2V0X2NlbnRzOiBidWRnZXRDZW50cywgZHVyYXRpb25fZGF5czogZHVyYXRpb25EYXlzIH0pLAogICAgfSk7CiAgICBjb25zdCBvdXQgPSBhd2FpdCByZXMuanNvbigpOwogICAgaWYgKCFyZXMub2sgfHwgIW91dC5jaGVja291dF91cmwpIHRocm93IG5ldyBFcnJvcihvdXQuZXJyb3IgfHwgIlBheW1lbnQgc2V0dXAgZmFpbGVkIik7CiAgICBsb2NhdGlvbi5ocmVmID0gb3V0LmNoZWNrb3V0X3VybDsKICB9IGNhdGNoIChlcnIpIHsKICAgIHNob3dNc2coU3RyaW5nKGVyci5tZXNzYWdlIHx8IGVycikpOwogICAgJCgicGF5IikuZGlzYWJsZWQgPSBmYWxzZTsgJCgicGF5IikudGV4dENvbnRlbnQgPSAiQ29udGludWUgdG8gcGF5bWVudCI7CiAgfQp9KTsKCmJvb3QoKTsKPC9zY3JpcHQ+CjwvYm9keT4KPC9odG1sPgo=";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

serve(async (req) => {
  let segs = new URL(req.url).pathname.split("/").filter(Boolean);
  if (segs[0] === "share") segs = segs.slice(1);

  if (segs[0] === ".well-known") {
    if (segs[1] === "apple-app-site-association") return aasa();
    if (segs[1] === "assetlinks.json") return assetlinks();
    return new Response("Not found", { status: 404 });
  }

  // Post-checkout landing for a boost (Stripe success_url). Cosmetic only —
  // the webhook activates the campaign server-side regardless of this page.
  if (segs[0] === "boost-success") return boostSuccess();

  // Host-boost portal — served as-is; its own JS reads ?event=<id>.
  if (segs[0] === "boost") return boostPortal();

  const [kind, value] = segs;
  if (!kind || !value) return html(genericPage(), 200);

  try {
    if (kind === "e") return await eventPage(value);
    if (kind === "p") return await postPage(value);
    if (kind === "u") return await profilePage(value);
  } catch (_) {
    return html(genericPage(), 200);
  }
  return new Response("Not found", { status: 404 });
});

// ── boost portal ──

function boostPortal(): Response {
  const bytes = Uint8Array.from(atob(BOOST_HTML_B64), (c) => c.charCodeAt(0));
  return new Response(bytes, {
    headers: { "content-type": "text/html; charset=utf-8" },
  });
}

// Confirmation page hosts land on after paying. Self-contained, Nile-themed.
function boostSuccess(): Response {
  const body = `<!doctype html><html lang="en"><head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"/>
<meta name="robots" content="noindex"/>
<title>Boost live · Nile</title>
<style>
  :root{--bg:#0A0A0A;--surface:#18181B;--border:#3F3F46;--volt:#C8FF00;--txt:#FAFAFA;--txt2:#A1A1AA}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--txt);min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
  .card{width:100%;max-width:440px;text-align:center}
  .badge{width:72px;height:72px;border-radius:999px;background:rgba(200,255,0,0.12);border:1px solid var(--volt);display:flex;align-items:center;justify-content:center;margin:0 auto 24px}
  .badge svg{width:36px;height:36px;stroke:var(--volt)}
  h1{font-size:26px;margin:0 0 8px;letter-spacing:-0.02em}
  p{color:var(--txt2);margin:0 0 28px;font-size:15px;line-height:1.5}
  a.cta{display:inline-block;background:var(--volt);color:#0A0A0A;font-weight:700;text-decoration:none;padding:15px 28px;border-radius:999px;font-size:16px}
  .note{color:#71717A;font-size:12px;margin-top:18px;line-height:1.5}
</style></head><body><div class="card">
  <div class="badge"><svg viewBox="0 0 24 24" fill="none" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg></div>
  <h1>Your boost is live</h1>
  <p>Payment received. Your event will start appearing in the Nile feed shortly — you can close this tab and head back to the app.</p>
  <a class="cta" href="nile://home">Open Nile</a>
  <p class="note">It can take a moment for the campaign to activate. Your boost runs for the duration you selected.</p>
</div></body></html>`;
  return html(body);
}

// ── .well-known responders ──

function aasa(): Response {
  const body = {
    applinks: {
      apps: [],
      details: [{ appID: IOS_APP_ID, paths: ["/e/*", "/p/*", "/u/*"] }],
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
        sha256_cert_fingerprints: ANDROID_SHA256,
      },
    },
  ];
  return new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json" },
  });
}

// ── Landing pages ──

async function eventPage(id: string): Promise<Response> {
  const { data } = await admin
    .from("events")
    .select("title, description, cover_image_url, status, host:profiles!events_host_id_fkey(username)")
    // This runs through the service-role client, which bypasses RLS — so the
    // `events_select_visible` policy that correctly hides drafts in-app did
    // nothing here, and an unreleased title + cover unfurled to anyone with the
    // id in Slack or iMessage. RLS is right; this query has to say so too.
    .neq("status", "draft")
    .eq("id", id)
    .maybeSingle();
  if (!data) return html(genericPage(), 404);
  const host = (data.host as { username?: string } | null)?.username;
  return html(page({
    title: (data.title as string) ?? "Event on Nile",
    description: (data.description as string) ?? (host ? `Hosted by @${host} on Nile` : "Watch on Nile"),
    image: (data.cover_image_url as string) ?? null,
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
    description: (data.content as string) ?? "See this post on Nile",
    image: (data.image_url as string) ?? null,
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
  const name = (data.display_name as string) || `@${data.username}`;
  return html(page({
    title: `${name} (@${data.username}) on Nile`,
    description: (data.bio as string) ?? `Follow @${data.username} on Nile`,
    image: (data.avatar_url as string) ?? null,
    canonical: `/u/${data.username}`,
  }));
}

// ── HTML rendering ──

interface Meta {
  title: string;
  description: string;
  image: string | null;
  canonical: string;
}

function page(m: Meta): string {
  const t = esc(m.title);
  const d = esc(truncate(m.description, 200));
  const url = `https://links.joinnile.com${m.canonical}`;
  const img = m.image ? esc(m.image) : "";
  const imgTags = img
    ? `<meta property="og:image" content="${img}"/>\n    <meta name="twitter:card" content="summary_large_image"/>\n    <meta name="twitter:image" content="${img}"/>`
    : `<meta name="twitter:card" content="summary"/>`;
  return `<!doctype html><html lang="en"><head>\n    <meta charset="utf-8"/>\n    <meta name="viewport" content="width=device-width,initial-scale=1"/>\n    <title>${t}</title>\n    <meta name="description" content="${d}"/>\n    <link rel="canonical" href="${url}"/>\n    <meta property="og:type" content="website"/>\n    <meta property="og:site_name" content="${SITE_NAME}"/>\n    <meta property="og:title" content="${t}"/>\n    <meta property="og:description" content="${d}"/>\n    <meta property="og:url" content="${url}"/>\n    <meta name="twitter:title" content="${t}"/>\n    <meta name="twitter:description" content="${d}"/>\n    ${imgTags}\n    ${storeRedirectScript()}\n    <style>\n      body{margin:0;background:#0A0A0A;color:#fff;font-family:-apple-system,system-ui,sans-serif;display:flex;min-height:100vh;align-items:center;justify-content:center;text-align:center;padding:24px}\n      .card{max-width:480px}\n      ${img ? `.cover{width:100%;max-width:360px;border-radius:16px;margin:0 0 20px;object-fit:cover}` : ""}\n      h1{font-size:24px;margin:0 0 8px}\n      p{color:#A1A1AA;margin:0 0 24px;line-height:1.5}\n      a.cta{display:inline-block;background:#C8FF00;color:#0A0A0A;font-weight:700;text-decoration:none;padding:14px 28px;border-radius:999px}\n    </style></head><body><div class="card">\n    ${img ? `<img class="cover" src="${img}" alt=""/>` : ""}\n    <h1>${t}</h1><p>${d}</p>\n    <a class="cta" href="${url}">Open in ${SITE_NAME}</a>\n    </div></body></html>`;
}

function storeRedirectScript(): string {
  return `<script>\n    (function(){\n      var p=location.pathname.replace(/^\\/share/,'').split('/').filter(Boolean);\n      var kind=p[0], val=p[1];\n      if(!kind||!val) return;\n      var scheme = kind==='e' ? 'nile://event/'+val : kind==='p' ? 'nile://post/'+val : null;\n      var ua=navigator.userAgent||'';\n      var store = /android/i.test(ua) ? ${JSON.stringify(PLAY_STORE_URL)} : /iphone|ipad|ipod/i.test(ua) ? ${JSON.stringify(APP_STORE_URL)} : null;\n      if(!store) return;\n      var t=Date.now();\n      if(scheme){ window.location.href=scheme; }\n      setTimeout(function(){ if(Date.now()-t<1600) window.location.href=store; }, 1200);\n    })();\n  </script>`;
}

function genericPage(): string {
  return page({ title: SITE_NAME, description: "Live events and posts on Nile.", image: null, canonical: "/" });
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
