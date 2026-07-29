# Sign in with Google & Apple — Implementation Plan

**Status:** Approved 2026-07-29 · Not yet started
**Repo:** `nile-app` (`nile_app/`), branch `main`
**Supabase project:** `jelmkkvyrliywcdkzhuu`

## Overview

Add Google and Apple sign-in to Nile alongside the existing email/password flow, using
Supabase's native ID-token path (`signInWithIdToken`) rather than a browser redirect. iOS
gets both providers; Android gets Google only. Because neither provider supplies a
username, OAuth users are routed through a new username-claim screen before onboarding.

Phase 2 (database hardening) is independently shippable and should go out ahead of the
rest — it fixes two bugs current beta testers can hit today.

## Non-goals / Out of scope

- Apple sign-in on Android (needs a Services ID, .p8 signing key, and browser redirect flow — deferred)
- macOS and web (no URL schemes configured; Firebase deliberately skipped on macOS; no beta testers on either)
- Additional providers (Facebook, X, GitHub)
- Merging two *already-separate* existing accounts — scope is limited to automatic identity
  linking at first OAuth sign-in

## Decisions taken

| Question | Decision |
|---|---|
| Username for OAuth users | Required claim screen after sign-in, before onboarding; prefilled with a generated suggestion |
| Platforms | iOS + Android only |
| Email collision with existing password account | Auto-link into one account (Supabase default when provider email is verified) |
| Apple private relay addresses | Accept normally (required for App Store review) |
| App Check on OAuth signups | Exempt — Google and Apple perform their own fraud screening |
| Apple on Android | Skipped for v1 |
| Rollout | Ship in the next Firebase App Distribution beta build |

---

## Phase 1: Console & credentials

Browser-driven; pause for passwords, 2FA, and legal agreements.

- Google Cloud (project `nile-35c48`): configure OAuth consent screen — External, app name
  Nile, support email, `email` + `profile` scopes
- Create **iOS** OAuth client, bundle `com.nilestreaming.app` → yields client ID + reversed client ID
- Retrieve SHA-1 from the release keystore (and debug keystore) via `keytool` on Channing's
  Mac; create **Android** OAuth client(s), package `com.nilestreaming.app`
- Create **Web** OAuth client — this is the `serverClientId` both mobile platforms use as the
  ID-token audience
- Firebase → Authentication → Sign-in method → enable Google; re-download
  `google-services.json` and `GoogleService-Info.plist` (they will now carry `oauth_client` entries)
- Apple Developer (team `9LTD86C5X7`) → Identifiers → `com.nilestreaming.app` → enable
  **Sign in with Apple**, save
- Regenerate the Ad Hoc provisioning profile — the capability change invalidates the current one
- Supabase → Auth → Providers → **Google**: enable, Client IDs = web + iOS + Android IDs.
  **Apple**: enable, Client IDs = `com.nilestreaming.app`. No client secret required for native flows.
- Record every ID into a scratch note for Phase 3

## Phase 2: Database hardening

Independently shippable — fixes live bugs even without OAuth.

- Migration `0063`: add `profiles.username_is_provisional boolean not null default false`
- Add `public.gen_username(seed text)` — lowercases, strips anything outside `[a-z0-9_]`,
  truncates to 20 chars, pads to a 3-char minimum, then appends a random 4-digit suffix in a
  retry loop until unique
- Rewrite `handle_new_user` to call `gen_username()` whenever `raw_user_meta_data->>'username'`
  is absent, and set `username_is_provisional = true` in that case

  > Current fallback is `split_part(NEW.email, '@', 1)`. Two failure modes: it can emit
  > usernames containing dots, plus signs, and capitals that violate the app's own
  > `^[a-z0-9_]+$` rule; and on a uniqueness collision it raises, which rolls back the entire
  > `auth.users` insert and surfaces as an opaque 500.

- Add `ProfileService.isUsernameAvailable(String)`; catch Postgres `23505` in `updateProfile`
  and surface "That username is taken" — wire into both `signup_screen.dart` and
  `edit_profile_screen.dart` (currently a taken username throws a raw Postgres error)
- Change `ProfileService.isOnboarded()` to fail closed on a missing row — it currently returns
  `true` when `row == null`, dropping a user with a broken profile straight into `HomeScreen`
- Optional hardening: unique index on `lower(username)` to close the `John`/`john` gap

## Phase 3: Packages & platform config

- Add to `pubspec.yaml`: `google_sign_in: ^7.2.0`, `sign_in_with_apple: ^8.1.0`, `crypto: ^3.0.7`
- iOS: add `com.apple.developer.applesignin` to `ios/Runner/Runner.entitlements`; add the
  Sign in with Apple capability in Xcode
- iOS: add the reversed client ID as a second `CFBundleURLSchemes` entry in
  `ios/Runner/Info.plist`, alongside the existing `nile` scheme
- Drop in the refreshed `GoogleService-Info.plist` and `google-services.json`
- Android: no manifest change needed for native Google sign-in — verify `minSdk` ≥ 21

## Phase 4: Social auth service

- New `lib/services/social_auth_service.dart`
- `signInWithGoogle()` — `GoogleSignIn.instance.initialize(clientId:, serverClientId:)` then
  `authenticate()`; pass the resulting `idToken` to
  `supabase.auth.signInWithIdToken(provider: OAuthProvider.google, …)`
- `signInWithApple()` — generate a raw nonce, SHA-256 it for
  `SignInWithApple.getAppleIDCredential(nonce:)`, then pass `identityToken` plus the **raw**
  nonce to `signInWithIdToken`
- On first Apple sign-in only, capture `givenName` / `familyName` and write to `display_name`
  — Apple never returns them on subsequent sign-ins
- Map user cancellation to a silent no-op; map network and configuration failures to
  user-readable messages
- Add client IDs to `lib/config.dart` alongside the existing Turnstile keys

## Phase 5: Username claim flow

- New `lib/screens/auth/claim_username_screen.dart` — prefilled with the generated
  suggestion, debounced live availability check, same `^[a-z0-9_]+$` and 3-char minimum rules
  as signup
- On submit: update `username` and set `username_is_provisional = false`
- `_AuthGate` in `lib/main.dart`: insert a provisional-username check between the MFA
  challenge and the onboarding check. **Blocking — no skip option.**
- Extend `ProfileService` and the `UserProfile` model with the new field
- Body wrapped in `NileMaxWidth` per project convention

## Phase 6: UI integration

- Shared `_SocialAuthButtons` widget: an "or continue with" divider, then Apple (iOS only,
  gated on `Platform.isIOS`) and Google buttons
- Build on the existing `OutlinedButtonTheme` (stadium shape, `borderStrong` hairline,
  `labelLg`) with `padding: EdgeInsets.symmetric(vertical: NileSpacing.s16)` to match the
  Sign In button's height
- Insert into `lib/screens/auth/login_screen.dart` after line 209 (between the Sign In button
  and the sign-up link Row)
- Insert into `lib/screens/auth/signup_screen.dart` after line 335
- Apple HIG: Apple button rendered at least as prominently as Google's, and placed first on iOS

## Phase 7: Bot protection & ship

- Update `supabase/functions/before-user-created/index.ts` to skip App Check verification when
  the incoming identity provider is `google` or `apple`; redeploy
- Verify:
  - fresh Google signup end-to-end
  - fresh Apple signup using Hide My Email
  - Apple sign-in on a second device (no name returned — confirm `display_name` survives)
  - OAuth sign-in with an email matching an existing password account (confirm auto-link)
  - cancellation mid-flow on both providers
  - username claim screen blocks progress and rejects taken usernames
- `flutter analyze` clean; commit and push to `nile-app`
- Fresh iOS Ad Hoc archive → export → Firebase App Distribution upload (entitlements changed,
  so this is mandatory); Android release APK rebuild and upload

## Open questions / risks

- **Provisioning profile churn.** Enabling Sign in with Apple invalidates the current Ad Hoc
  profile. Combined with the pending tester UDID additions from the beta readiness checklist,
  plan on one profile regeneration covering both.
- **`google_sign_in` 7.x is an API rewrite.** The old `signIn()` method is gone in favour of
  `initialize()` + `authenticate()` + an event stream. Most online tutorials still show the
  6.x API — follow the official migration guide, not search results.
- **Auto-linking depends on verified emails.** Supabase links identities only when the provider
  marks the email as verified. Google always does, and Apple relay addresses do too — but
  confirm on a real device rather than trusting the docs.
- **Turnstile cannot cover OAuth.** `signInWithIdToken` accepts no captcha token. If Supabase's
  global captcha protection is enabled later, confirm it does not reject the OAuth path.
- **Provisional usernames are visible in share links.** A user who signs in with Apple and
  abandons the claim screen mid-flow will briefly hold a generated username. Acceptable given
  the claim screen blocks all other navigation.
