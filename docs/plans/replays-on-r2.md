# Replays on Cloudflare R2 — Plan

_Planned 2026-11-24. Status: built and live 2026-11-24 (livekit v75, livekit-webhook v30). Android playback check and test cleanup remain._

## Why
Replays have never recorded on prod: the `REPLAYS_S3_*` secrets were never set. Pointing them at Supabase Storage won't work either, because the Free plan caps each file at 50 MB (a replay passes that after ~4 minutes at 1500 kbps) and the whole project at 1 GB. Cloudflare R2 has no per-file cap that matters here, costs about $0.015/GB a month, charges nothing to stream out, and is already on Channing's Cloudflare account (`nile-downloads`).

## Decisions
- New private bucket `nile-replays`. Same file names as today (`<eventId>/<startedAt>.mp4`, `-grid.mp4`), so the database doesn't change.
- A Cloudflare API token that can only read and write that one bucket. Stored only in Supabase secrets, moved there from the clipboard (never in chat or files).
- Replays are watched through short-lived signed links, as now — just signed for R2 instead of Supabase Storage.
- R2 deletes replay files after 31 days by itself (a bucket rule). The nightly purge job keeps deleting the database rows at 30 days, as it does now.

## Phase 1: Bucket and keys
- [x] Create bucket `nile-replays` (Cloudflare connector).
- [x] Add a 31-day delete rule to it.
- [x] Create an R2 token scoped to `nile-replays`, Object Read & Write (Cloudflare dashboard, built-in browser).
- [x] Set `REPLAYS_S3_ENDPOINT` (`https://<account>.r2.cloudflarestorage.com`), `REPLAYS_S3_REGION` (`auto`), `REPLAYS_S3_ACCESS_KEY`, `REPLAYS_S3_SECRET_KEY`, `REPLAYS_BUCKET` (`nile-replays`).

## Phase 2: Code (livekit function only)
- [x] Read the bucket name from `REPLAYS_BUCKET` (falls back to `replays`).
- [x] New `_shared/r2.ts`: a small signer that makes a time-limited GET link (AWS Signature V4, WebCrypto, no new packages), with a unit test against AWS's published example.
- [x] `replay-url` and `replay-grid` hand out R2 signed links instead of Supabase Storage ones.
- [x] Deploy `livekit`.

## Phase 3: Test
- [ ] 5-minute paid test show on the Mac: both files appear in R2 at about 12 MB/min, the replay row turns `ready`, and the replay plays (including seeking) on Mac and Android.
- [ ] Delete the test files and events.

## Results (2026-11-24)
- 5.2-minute test show: main replay 58.8 MB, grid 57.1 MB in `nile-replays` (~11.3 MB/min). Played and seeked on the Mac from a signed R2 link; paused while the window was minimised and resumed on restore.
- Found and fixed: `livekit-webhook` wrote a fractional duration into the bigint `duration_ms`, so every finished replay failed to turn `ready` (never seen before because nothing had recorded). Now rounded.
- LiveKit also writes a small `EG_*.json` manifest beside each file; the 31-day rule removes those too.

## Not changing
- `livekit-webhook` (it only reads duration from LiveKit), the purge SQL (rows still go at 30 days; with no Supabase object the row is deleted anyway), the app.

## Risks
- If the R2 token leaks it can only touch `nile-replays`.
- Existing Supabase `replays` bucket stays (empty); can be removed later.
