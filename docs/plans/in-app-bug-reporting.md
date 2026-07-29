# In-App Bug & Feature Reporting — Implementation Plan

## Overview
Signed-in users file bugs and feature requests from Settings, and beta testers can
also trigger the form by shaking the device. Each report carries auto-collected
diagnostics, up to 3 screenshots, and a captured in-app error log. Admins triage in
the existing portal with status + internal notes; resolving a report notifies the
reporter in-app.

## Non-goals / Out of scope
- Anonymous or pre-login reporting
- Email replies to reporters (in-app notification only)
- Public bug tracker or feature-request voting
- Sentry linkage — the existing hooks stay in place untouched, but nothing reads from Sentry
- Shake-to-report in App Store / Play Store builds
- Threaded back-and-forth with the reporter

## Phase 1: Data layer (migration 0076)
- Enums `feedback_kind` (`bug`, `feature`) and `feedback_status` (`new`, `triaged`,
  `in_progress`, `resolved`, `wont_fix`)
- Table `feedback_reports`: `id`, `reporter_id` (→ `auth.users`, on delete set null),
  `kind`, `title`, `body`, `status` default `new`, `admin_note`, `diagnostics jsonb`,
  `error_log jsonb`, `image_paths text[]`, `resolved_at`, `resolved_by`, `created_at`
- Check constraints: `title` ≤ 120 chars, `body` 10–4000 chars,
  `array_length(image_paths) ≤ 3`
- Indexes on `(status, created_at desc)` and `(reporter_id, created_at desc)`
- RLS: reporter inserts + selects own rows; admins (`exists (select 1 from admins …)`)
  select + update all; no deletes for anyone
- `before insert` trigger raising on more than 5 reports per user per hour
- Private `feedback` storage bucket, 10 MB limit, `image/jpeg|png|webp` allowlist;
  users write under `{uid}/`, admins read all
- `alter type notification_type add value 'feedback_resolved'` + default in `notif_enabled`

## Phase 2: App — service, diagnostics, error buffer, form
- `lib/services/diagnostics.dart` — app version + build (`package_info_plus`), platform,
  OS version, device model, locale, logical screen size, connectivity, user id → `Map`
- `lib/services/error_log.dart` — ring buffer of the last 20 errors (message, truncated
  stack, timestamp), installed in `main.dart` *alongside* the Sentry hooks rather than
  replacing them; strip anything token-shaped before storing
- `lib/services/feedback_service.dart` — `submit({kind, title, body, images})`:
  compress + upload images to `feedback/{uid}/{reportId}/n.jpg` (reuse the Currents
  compression path), then insert the row; plus `myReports()`
- `lib/screens/report_issue_screen.dart` — Bug/Idea segmented toggle, title field, body
  field with counter, image picker capped at 3, an expandable "device info attached" row
  showing exactly what's sent, submit with loading/error/success states
- `settings_screen.dart` — new `SUPPORT` section with `Icons.bug_report_outlined` →
  "Report a bug or idea"

## Phase 3: Shake to report (beta builds only)
- Add `sensors_plus` and `screenshot` dependencies
- `lib/services/shake_detector.dart` — accelerometer threshold + cooldown, ignores repeat
  shakes within 3s
- `RepaintBoundary` with a global key at the app root; capture PNG on shake and pre-attach it
- Gate on `const bool.fromEnvironment('NILE_BETA')` so store builds ship it disabled
- Suppress while `CameraScreen` is live — a phone on a tripod during a stream must not pop
  the form
- One-time consent dialog on first shake explaining the auto-screenshot

## Phase 4: Admin triage view in the portal
- `AdvertiserPortal.vue`: add `"feedback"` to the `view` union, `?view=feedback` bookmark,
  and an `openFeedback()` guard mirroring `openReports()`
- Cursor-paginated list on `created_at` using the existing `PAGE` pattern; filter chips for
  status and kind; a new-count badge next to the existing report count
- Detail modal: body, diagnostics table, error log, signed URLs for the screenshots,
  reporter handle
- Actions: status dropdown + `admin_note` textarea, saved in place with the existing
  re-pull-window refresh

## Phase 5: Notify the reporter
- Trigger on `feedback_reports` update: status → `resolved` inserts a `feedback_resolved`
  notification honoring `notif_enabled`
- `notification_preferences_screen.dart`: add the toggle
- Tapping the notification opens a read-only view of the report plus your admin note
- `send-push` function: copy for the new type

## Phase 6: Retention and polish
- Scheduled job purging screenshots older than 90 days and nulling `image_paths`, keeping
  the text rows
- `privacy.astro`: a line covering what a bug report collects
- Empty / offline / rate-limited states ("you've reported a few times recently — try again
  shortly")
- QA: submit from iOS, Android, macOS; verify diagnostics accuracy; RLS negative test that
  a non-admin can't read another user's report

## Open questions / risks
- Screenshots can capture DMs or payout details, and shake auto-capture makes that likelier
  — the Phase 3 consent dialog is the mitigation, but skipping auto-capture on the payouts
  and messages screens may also be worth it.
- 5 reports/hour may be tight for a tester in a bug-heavy session; consider exempting a
  beta-tester flag.
- If Sentry is reactivated later, prefer storing its event ID on the row over growing the
  in-app buffer.
