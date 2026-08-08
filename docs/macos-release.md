# Releasing Nile for macOS

Direct download, Developer ID + notarization — **not** the Mac App Store. See
`docs/plans/nile-macos.md` for why.

## One command

```bash
cd nile_app
./scripts/build_macos.sh --upload
```

Produces `build/macos/dist/Nile-<version>.dmg`, notarized and stapled, and
publishes it to `https://downloads.joinnile.com/mac/`.

| Flag | Effect |
|---|---|
| _(none)_ | build → sign → notarize → DMG → notarize → staple → verify |
| `--skip-build` | reuse the existing Release build (fast iteration on signing/DMG) |
| `--skip-notarize` | sign and build the DMG only; skips both Apple round trips |
| `--upload` | also PUT the DMG to R2 as `mac/Nile-<version>.dmg` and `mac/Nile.dmg` |

The version comes from `pubspec.yaml`. Bump it before every release —
`CFBundleShortVersionString` and `CFBundleVersion` both read from it.

## Prerequisites

All established in Phase 0; listed here so a fresh machine can be set up.

- **Signing identity** `Developer ID Application: CYGNUS INNOVATIONS, LLC (9LTD86C5X7)`
  in the login keychain (`security find-identity -v -p codesigning`).
- **Provisioning profile** "Nile macOS Developer ID" in
  `~/Library/MobileDevice/Provisioning Profiles/`. Not optional — without an
  embedded profile the app has no keychain access group and Google sign-in
  fails with `secd` error `-34018`.
- **notarytool keychain profile** named `nile`:
  ```bash
  xcrun notarytool store-credentials nile \
    --key ~/.appstoreconnect/private_keys/AuthKey_QPG32KNFL8.p8 \
    --key-id QPG32KNFL8 --issuer b7187ac6-2b39-4787-afe9-ab77f39676d1
  ```
- **create-dmg**: `brew install create-dmg`
- **R2 credentials** for `--upload`, read from
  `~/Desktop/Developers Account info/macos-signing/r2-credentials.txt`, or
  supplied as `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` environment variables
  (which is how CI will pass them in Phase 4).

## Why the script re-signs everything

`flutter build macos --release` signs the app bundle with hardened runtime, but
Xcode's framework-embed step signs the 42 nested frameworks and resource bundles
with `flags=0x0(none)` and no secure timestamp. Notarization rejects every one of
them. The script re-signs them deepest-first (`find -depth`) with
`--options runtime --timestamp`, then re-seals the outer bundle — nested code
gets no entitlements, only the app does.

It also aborts if `com.apple.security.get-task-allow` survives into the Release
build, which is an automatic rejection. `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`
on the Runner Release config is what keeps it out.

## Reading a rejection

Notarization failures are opaque — the status is just `Invalid`. The log is the
only useful artifact, and the script prints it automatically on failure. To pull
it by hand:

```bash
xcrun notarytool history --keychain-profile nile          # find the submission id
xcrun notarytool log <submission-id> --keychain-profile nile
xcrun notarytool info <submission-id> --keychain-profile nile
```

The log is JSON with an `issues` array; each entry names the exact path inside
the bundle and the reason. The four that actually happen:

| Log message | Cause |
|---|---|
| `The binary is not signed with a valid Developer ID certificate` | signed ad-hoc, or with an Apple Development cert |
| `The signature does not include a secure timestamp` | missing `--timestamp` |
| `The executable does not have the hardened runtime enabled` | missing `--options runtime` on a nested framework |
| `The executable requests the com.apple.security.get-task-allow entitlement` | Xcode injected base entitlements |

## Verifying by hand

```bash
codesign --verify --deep --strict --verbose=4 build/macos/Build/Products/Release/Nile.app
spctl -a -t exec -vvv                          build/macos/Build/Products/Release/Nile.app
xcrun stapler validate                         build/macos/Build/Products/Release/Nile.app
xcrun stapler validate                         build/macos/dist/Nile-<version>.dmg
```

`spctl` should say `source=Notarized Developer ID`. Anything else — most often
`source=Unnotarized Developer ID` — means the ticket was never stapled.

## The real test

Signature checks pass on the machine that built the app whether or not
notarization worked. The only test that counts is downloading the DMG over the
network onto a Mac that has never run Nile, under a different user account, and
confirming first launch is a single **Open** with no warning dialog.

To simulate the quarantine flag without a second machine:

```bash
xattr -w com.apple.quarantine \
  "0083;00000000;Safari;|com.apple.Safari" build/macos/dist/Nile-<version>.dmg
```

## DMG artwork

`macos/dmg/background.png` (660×400) and `macos/dmg/background@2x.png` are
combined into a multi-resolution TIFF at build time by `tiffutil`. Window
geometry, icon size and icon positions live in the `create-dmg` invocation in
`scripts/build_macos.sh` — if you change the artwork, change the coordinates
with it.
