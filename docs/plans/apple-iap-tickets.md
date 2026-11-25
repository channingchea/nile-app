# Apple In-App Purchase (tickets, replays, tips) — Implementation Plan

Planned 2026-11-24 (rev 3). Wireframes: https://claude.ai/artifact/Vvwp7AjxYTV3YFprM2pL1B

## Overview
App Review requires Apple's in-app purchase for ticketed livestreams (guideline 3.1.3(d)). This plan adds it for tickets and replays on iPhone and iPad. The iPhone price is the web price ÷ 0.70, rounded up to the next .99, so hosts earn the same everywhere. US buyers also get a small link to the cheaper web checkout. Hosts get Apple earnings in the same month-end payout as web sales; Nile fronts the money until Apple pays. iPhone/iPad tips stay on Stripe with a 0% Nile fee, so they qualify to skip Apple.

## Decisions (2026-11-24)
- Plan at Apple's 30% (`app_config.apple_fee_pct` 0.30). Small Business Program not enrolled for now.
- Fixed price ladder of 99 consumable products, $1.99–$99.99. Advanced Commerce API (flexible prices) not pursued for now.
- iPhone price = ceil(web ÷ 0.70) rounded up to .99. $10 → $14.99.
- US App Store buyers: Apple button + small web link. Everyone else: Apple only. Country comes from StoreKit, not phone settings.
- Shows over ~$69 on web (iPhone price above $99.99): US gets the web link only; elsewhere "Available on joinnile.com" with no link.
- Replays follow the same rules as tickets.
- Tips from iPhone/iPad: 0% Nile fee (Nile pays Stripe's fee). Web, Mac and Android keep 10%.
- Host payout: Apple sales go in the same month-end payout as web sales (host Stripe accounts already pay out monthly, anchor 31). Nile fronts the money.
- Apple refunds after a payout come off the host's next payout.
- Cancelled shows: Apple buyers get a one-tap in-app refund request (Apple's refund form).
- Host screens use platform-neutral words ("card", "app store") so the same copy passes Apple's 2.3.10 and Google's equivalent rule. Never name Android on Apple builds or Apple platforms on Android.

## Non-goals
- Google Play billing (separate plan before a Play Store release)
- Mac app purchases (ships outside the App Store, keeps Stripe)
- Small Business Program, Advanced Commerce API
- Nile credit for cancelled shows
- Replies to Apple's "consumption information" requests
- iPhone sales above $99.99

## Phase 1: App Store setup + database
- [ ] Channing: accept the Paid Apps agreement and fill in tax + banking in App Store Connect.
- [x] Script (`tool/asc_iap.mjs`, existing App Store Connect API key) creates 99 consumables `<bundle>.ppv.0199` … `.ppv.9999`, named "Show access – $X.99", each with a localization. Review screenshot still to attach (`node tool/asc_iap.mjs screenshot <png>`, once the buy panel is on a device).
- [x] Migration (next free number — list first, numbers aren't unique): add to `tickets` `payment_provider` ('stripe'|'apple'), `apple_transaction_id` (unique), `store_price_cents`, `host_share_cents`, `host_paid_at`, `host_clawback_at`.
- [x] SQL `compute_iap_price_cents(web_cents)` → ceil(web ÷ (1 − `apple_fee_pct`)) up to .99; null above $99.99.
- [x] Mirror `PricingConfig.iapPriceCentsFor` in the app + a test that both agree.

## Phase 2: Server
- [x] `create-payment-intent` with `provider: 'apple'`: same price/status/capacity/replay checks; creates a pending Apple ticket; returns `product_id` + `ticket_id`.
- [x] New `apple-iap` fn, `/verify`: check Apple's signed transaction with the App Store Server Library (signature, bundle ID, environment, `appAccountToken` = ticket id, product matches); mark the ticket paid, idempotent on `apple_transaction_id`. Grant even if the show sold out meanwhile.
- [x] `apple-iap` `/notifications` (Server Notifications v2, production + sandbox): purchase notice = backup grant; `REFUND` → ticket refunded.
- [x] `create-tip-payment`: origin `ios` → Nile fee 0.
- [x] Deno tests: bad signature, wrong product, replayed transaction, sandbox-to-prod, refund.

## Phase 3: App purchase flow (iPhone/iPad only)
- [x] `in_app_purchase` package + `IapService`: buy with the ticket id attached, call `/verify`, finish the transaction only after the server confirms.
- [x] Listen for purchases from app start so interrupted ones finish on next launch.
- [x] StoreKit storefront country; unknown = non-US.
- [x] Buy panel: main "Buy ticket · $14.99"; US-only "Or pay $10.00 at joinnile.com" link; over-$69 cases per Decisions.
- [x] iPhone price on event cards, event detail and replay screens.
- [x] "Confirming…" → ticket; on failure "Your purchase is safe — we're finishing up" with silent retries + support link.
- [x] Event creator: "Card checkout $X · App store purchases $Y · You earn $Z, the same on every device".
- [x] Tip sheet on iPhone: "100% goes to the host".
- [x] Hide all Apple purchase UI on Mac, web and Android.

## Phase 4: Refunds and cancellations
- [x] Small Swift method channel for StoreKit `beginRefundRequest`.
- [x] My Tickets "Refund": card tickets keep today's flow; Apple tickets open Apple's refund form.
- [x] Cancelled show → Apple buyers get a push + My Tickets notice with a "Request refund" button. (Migration 0159, live.)
- [x] Host attendee list: app store rows show "Refunds through the app store" instead of a refund button.

## Phase 5: Month-end host payouts
- [x] Scheduled job on the 28th per host: Σ `host_share_cents` of paid Apple tickets for ended shows not yet paid, minus already-paid refunded ones not yet clawed back. One Stripe transfer per host per month (host+month idempotency key); stamp `host_paid_at` / `host_clawback_at`. Negative totals or unpayable hosts roll to next month. The existing month-end payout (31st) sends it to the bank with web sales.
- [x] Monthly cross-check before the job runs: pull Apple's sales + refund reports via the App Store Connect API, compare to Nile's Apple tickets, flag mismatches in the admin portal.
- [x] Payouts screen + `host_event_ticket_totals`: "Tickets paid by card", "Tickets bought through the app store", app store refund deductions.

## Phase 6: Test and submit
- [ ] TestFlight sandbox pass, US + non-US sandbox accounts: interrupted purchase, refund, cancelled show, over-$69 show, 0% tip, one payout run in Stripe test mode. (Apple's refund sheet is flaky in sandbox — may need Xcode StoreKit testing.)
- [ ] Re-read guidelines 3.1.1, 3.1.3(d), 3.2.1(vii), 2.3.10 on submission day; App Review notes covering the two ways to pay and the US-only link.
- [ ] Ship with build 9 or later, products submitted alongside.

## Open questions / risks
- App Review may question 99 near-identical products.
- A tip's chat shout-out could be read as content tied to the tip, forcing tips through Apple.
- Outside the US, Apple pays in local currency; Nile absorbs exchange-rate gains/losses (host share is fixed in USD).
- Nile fronts ~45 days of Apple host payouts.
- Epic v. Apple Supreme Court argument 2027-01-11 could remove the US web link.

## Build status (2026-11-24)
Built, not yet tested on a device. Server pieces are live on prod; the app side ships with build 9 or later.
- Migrations: 0157 (ticket columns, `compute_iap_price_cents`, settle/refund RPCs, `apple_reconciliations`), 0158 (settlement: Apple vs card on the same ticket row), 0160 (payout claim/complete/release, `host_ticket_earnings_by_source`), 0161 (sandbox purchases left out of host totals), 0159 (cancel notice + no deleting a show with app store sales) — all live.
- Functions live: `apple-iap` (verify + notifications, `--no-verify-jwt`), `apple-payouts` (cron `apple-payouts`, 28th 16:10 UTC, `--no-verify-jwt`), `create-payment-intent` (provider apple), `create-tip-payment` (0% from iOS), `refund-ticket` (refuses app store tickets), `send-push` (`event_cancelled`).
- App: `lib/services/iap_service.dart`, `lib/widgets/iap_confirm_sheet.dart`, buy panel in `event_detail_screen.dart`, My Tickets refund, attendee list, payouts split, host price preview, tip copy, refund channel in `ios/Runner/AppDelegate.swift`.
- Verification of Apple's signed data is local (Apple Root CA - G3 pinned, chain + marker extensions + ES256), `_shared/apple_iap.ts`, via `npm:@peculiar/x509`.

### Still needed before submission
1. Channing: Paid Apps agreement + tax + banking (products show "Missing Metadata" until a review screenshot is attached, and can't be bought in sandbox until the agreement is active).
2. App Store Connect → App Information → App Store Server Notifications: Production and Sandbox URL `https://jelmkkvyrliywcdkzhuu.functions.supabase.co/apple-iap/notifications`, Version 2.
3. Cross-check secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY`, `ASC_VENDOR_NUMBER` (needs a key with the Finance or Sales role; the current key is App Manager).
4. Stripe balance must hold enough USD for the month-end transfers (Apple pays Nile's bank, not Stripe).
5. TestFlight sandbox pass (Phase 6), then attach the review screenshot to all 99 products.

### App Review notes (draft)
Nile sells access to live and recorded shows. On iPhone and iPad, tickets and replays are in-app purchases (consumables `com.nilestreaming.app.ppv.XXXX`, one per price point; the product used depends on the show's price). In the United States storefront only, the ticket panel also shows a link to buy the same ticket on joinnile.com, as allowed for US storefronts. Shows priced above our top in-app price point are offered through that link in the US and are not sold in the app elsewhere. Tips go 100% to the show's host with no fee to Nile. Demo account: appreview@joinnile.com. To test: open any ticketed show from Discover → Get Ticket.

