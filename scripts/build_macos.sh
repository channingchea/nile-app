#!/usr/bin/env bash
#
# Nile for macOS — one command from source to a notarized, stapled DMG.
#
#   scripts/build_macos.sh                 full run: build, sign, DMG, notarize, staple, verify
#   scripts/build_macos.sh --skip-build    reuse the existing Release build
#   scripts/build_macos.sh --skip-notarize sign + DMG only (fast local iteration)
#   scripts/build_macos.sh --upload        also publish the DMG to downloads.joinnile.com
#   scripts/build_macos.sh --bake-dsstore  refresh macos/dmg/DS_Store from the built DMG
#
# Prerequisites (all set up in Phase 0):
#   * "Developer ID Application: CYGNUS INNOVATIONS, LLC (9LTD86C5X7)" in a keychain
#   * notarytool keychain profile "nile"  (xcrun notarytool store-credentials)
#   * brew install create-dmg            (only for the Finder DMG path — see below)
#
# CI (Phase 4): every credential the script needs can come from the environment
# instead of a keychain profile or a file on the Desktop —
#   SIGN_IDENTITY, NOTARY_KEY / NOTARY_KEY_ID / NOTARY_ISSUER,
#   R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY
# and when $CI is set the DMG is assembled with hdiutil instead of create-dmg,
# because create-dmg drives Finder over AppleScript and a runner has nobody to
# grant it Automation access.
#
set -euo pipefail

APP_NAME="Nile"
TEAM_ID="9LTD86C5X7"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: CYGNUS INNOVATIONS, LLC (${TEAM_ID})}"
NOTARY_PROFILE="${NOTARY_PROFILE:-nile}"

R2_ACCOUNT_ID="${R2_ACCOUNT_ID:-9b1d86017f32cabde4f98a4799075994}"
R2_BUCKET="${R2_BUCKET:-nile-downloads}"
R2_CREDS="${R2_CREDS:-$HOME/Desktop/Developers Account info/macos-signing/r2-credentials.txt}"

SKIP_BUILD=0; SKIP_NOTARIZE=0; UPLOAD=0; BAKE_DSSTORE=0
DMG_MODE="auto"   # auto | finder | plain
for arg in "$@"; do case "$arg" in
  --skip-build)    SKIP_BUILD=1 ;;
  --skip-notarize) SKIP_NOTARIZE=1 ;;
  --upload)        UPLOAD=1 ;;
  --bake-dsstore)  BAKE_DSSTORE=1; DMG_MODE="finder" ;;
  --plain-dmg)     DMG_MODE="plain" ;;
  --finder-dmg)    DMG_MODE="finder" ;;
  *) echo "unknown flag: $arg" >&2; exit 2 ;;
esac; done

# Publishing an unnotarized build is silently broken for everyone who downloads
# it — Gatekeeper blocks it — so the two flags are mutually exclusive.
if [[ $UPLOAD -eq 1 && $SKIP_NOTARIZE -eq 1 ]]; then
  echo "refusing --upload with --skip-notarize: that would publish a DMG Gatekeeper blocks" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(sed -n 's/^version: *//p' pubspec.yaml | head -1 | tr -d '[:space:]')"
SHORT="${VERSION%%+*}"
APP="build/macos/Build/Products/Release/${APP_NAME}.app"
ENTITLEMENTS="macos/Runner/Release.entitlements"
DIST="build/macos/dist"
STAGE="$DIST/stage"
DMG="$DIST/${APP_NAME}-${SHORT}.dmg"
DSSTORE="macos/dmg/DS_Store"

step() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    warning: %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

# create-dmg's Finder scripting is the one step that can hang unattended, so CI
# takes the hdiutil path by default. Locally, fall back to it too if create-dmg
# was never installed.
if [[ "$DMG_MODE" == "auto" ]]; then
  if [[ -n "${CI:-}" ]] || ! command -v create-dmg >/dev/null 2>&1; then
    DMG_MODE="plain"
  else
    DMG_MODE="finder"
  fi
fi
[[ "$DMG_MODE" == "plain" && ! -f "$DSSTORE" ]] &&
  warn "no $DSSTORE — the DMG window will open unstyled. Run --bake-dsstore on a Mac with create-dmg."

# ---------------------------------------------------------------- build
if [[ $SKIP_BUILD -eq 0 ]]; then
  # P4 #39: this used to be a bare `flutter build macos --release`, with no
  # --dart-define at all — which is why no Mac build has EVER carried the
  # Sentry DSN. Every Mac crash since the desktop app shipped went unreported,
  # and nobody noticed precisely because the reports that would have told us
  # were the missing thing.
  #
  # Both values are read from the environment and are optional: absent, the
  # app skips Sentry / PostHog exactly as it does today, so a local build with
  # no secrets set behaves the same as before.
  DEFINES=()
  [[ -n "${SENTRY_DSN:-}" ]]      && DEFINES+=(--dart-define=SENTRY_DSN="$SENTRY_DSN")
  [[ -n "${POSTHOG_API_KEY:-}" ]] && DEFINES+=(--dart-define=POSTHOG_API_KEY="$POSTHOG_API_KEY")
  [[ -n "${POSTHOG_HOST:-}" ]]    && DEFINES+=(--dart-define=POSTHOG_HOST="$POSTHOG_HOST")

  if [[ ${#DEFINES[@]} -eq 0 ]]; then
    warn "no SENTRY_DSN or POSTHOG_API_KEY in the environment — this build will report nothing"
  fi

  step "flutter build macos --release  (v${SHORT}, build ${VERSION##*+}, ${#DEFINES[@]} define(s))"
  # The +"..." guard is not decoration: macOS ships bash 3.2, where expanding
  # an EMPTY array as "${DEFINES[@]}" under `set -u` dies with "unbound
  # variable". A build with no secrets configured is the common local case, so
  # the plain form would break exactly the path most people take.
  flutter build macos --release "${DEFINES[@]+"${DEFINES[@]}"}"
else
  step "Reusing existing Release build"
fi
[[ -d "$APP" ]] || fail "no app at $APP"

# ------------------------------------------------------- sign, inside out
# Xcode's embed step signs nested frameworks WITHOUT the hardened-runtime flag,
# which notarization rejects. Re-sign every nested Mach-O deepest-first, then
# re-seal the outer bundle. Frameworks get no entitlements — only the app does.
step "Re-signing nested code with hardened runtime + secure timestamp"
count=0
while IFS= read -r -d '' item; do
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$item"
  count=$((count + 1))
done < <(find "$APP" -depth \
  \( -name '*.framework' -o -name '*.bundle' -o -name '*.dylib' \
     -o -name '*.xpc' -o -name '*.appex' \) -print0)
echo "  re-signed $count nested items"

step "Sealing ${APP_NAME}.app"
codesign --force --sign "$IDENTITY" --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

# get-task-allow in a Release build is an automatic notarization rejection.
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q 'get-task-allow'; then
  fail "get-task-allow is present — check CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO"
fi

# ------------------------------------------------------------- notarize
# Credentials: an App Store Connect API key from the environment (CI), or the
# stored keychain profile (local). Same submission either way.
if [[ -n "${NOTARY_KEY:-}" ]]; then
  NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?NOTARY_KEY_ID required}" \
               --issuer "${NOTARY_ISSUER:?NOTARY_ISSUER required}")
else
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
fi

# `notarytool --wait` prints nothing until it returns, and a first submission on
# a fresh Developer ID can sit In Progress for an hour. Tick so a CI log and a
# watching human can both tell the difference between slow and hung.
heartbeat() {
  local mins=0
  while sleep 60; do
    mins=$((mins + 1))
    printf '  … still waiting on Apple (%d min)\n' "$mins"
  done
}

notarize() { # $1 = file to submit
  local out parsed id status hb
  heartbeat & hb=$!
  out="$(xcrun notarytool submit "$1" "${NOTARY_ARGS[@]}" \
        --wait --output-format json)" || { kill "$hb" 2>/dev/null; fail "notarytool submit failed"; }
  kill "$hb" 2>/dev/null || true
  parsed="$(/usr/bin/python3 -c \
    'import json,sys; d=json.load(sys.stdin); print(d.get("id",""), d.get("status",""))' \
    <<<"$out")"
  id="${parsed%% *}"; status="${parsed#* }"
  echo "  submission $id → $status"
  if [[ "$status" != "Accepted" ]]; then
    echo "  --- notarization log ---"
    xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" 2>&1 | sed 's/^/  /'
    fail "notarization returned $status (submission $id)"
  fi
}

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  mkdir -p "$DIST"
  step "Notarizing ${APP_NAME}.app"
  /usr/bin/ditto -c -k --keepParent "$APP" "$DIST/${APP_NAME}.zip"
  notarize "$DIST/${APP_NAME}.zip"
  xcrun stapler staple "$APP"
  rm -f "$DIST/${APP_NAME}.zip"
fi

# ------------------------------------------------------------------ DMG
step "Building ${APP_NAME}-${SHORT}.dmg  (${DMG_MODE} layout)"
mkdir -p "$DIST"
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
/usr/bin/ditto "$APP" "$STAGE/${APP_NAME}.app"

# Multi-resolution background so the window is crisp on Retina.
/usr/bin/tiffutil -cathidpicheck macos/dmg/background.png macos/dmg/background@2x.png \
  -out "$DIST/background.tiff" >/dev/null

if [[ "$DMG_MODE" == "finder" ]]; then
  create-dmg \
    --volname "$APP_NAME" \
    --volicon "$APP/Contents/Resources/AppIcon.icns" \
    --background "$DIST/background.tiff" \
    --window-pos 200 120 --window-size 660 400 \
    --icon-size 100 \
    --icon "${APP_NAME}.app" 165 200 \
    --app-drop-link 495 200 \
    --hide-extension "${APP_NAME}.app" \
    --no-internet-enable \
    --codesign "$IDENTITY" \
    "$DMG" "$STAGE"
else
  # Same window, no Finder. create-dmg's only irreplaceable trick is writing the
  # icon layout into .DS_Store via AppleScript; we ship that file pre-baked
  # instead (macos/dmg/DS_Store, refreshed with --bake-dsstore) and assemble the
  # image with hdiutil. Volume name must stay "Nile" — the layout is keyed to it.
  RW="$DIST/rw.dmg"; MNT="$DIST/mnt"
  rm -rf "$RW" "$MNT"; mkdir -p "$STAGE/.background" "$MNT"
  ln -s /Applications "$STAGE/Applications"
  cp "$DIST/background.tiff" "$STAGE/.background/background.tiff"
  cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
  [[ -f "$DSSTORE" ]] && cp "$DSSTORE" "$STAGE/.DS_Store"

  hdiutil create -srcfolder "$STAGE" -volname "$APP_NAME" -fs HFS+ \
    -format UDRW -ov "$RW" >/dev/null
  hdiutil attach -nobrowse -noautoopen -mountpoint "$MNT" "$RW" >/dev/null
  # The custom-icon bit is a filesystem attribute, so it has to be set on the
  # mounted volume rather than in the staging folder.
  [[ -x /usr/bin/SetFile ]] && /usr/bin/SetFile -a C "$MNT" || warn "SetFile missing — no volume icon"
  hdiutil detach "$MNT" >/dev/null
  hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
  rm -rf "$RW" "$MNT"
  # create-dmg --codesign does this for us on the other path. Without it,
  # spctl -a -t open rejects the download even when the app inside is fine.
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi
rm -rf "$STAGE"

# Capture the Finder-authored layout so the hdiutil path can reproduce it.
if [[ $BAKE_DSSTORE -eq 1 ]]; then
  step "Baking $DSSTORE from the DMG"
  BAKE_MNT="$DIST/bake"; rm -rf "$BAKE_MNT"; mkdir -p "$BAKE_MNT"
  hdiutil attach -nobrowse -noautoopen -readonly -mountpoint "$BAKE_MNT" "$DMG" >/dev/null
  cp "$BAKE_MNT/.DS_Store" "$DSSTORE"
  hdiutil detach "$BAKE_MNT" >/dev/null; rm -rf "$BAKE_MNT"
  echo "  wrote $DSSTORE ($(du -h "$DSSTORE" | cut -f1)) — commit it"
fi

# ------------------------------------------------------ notarize the DMG
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  step "Notarizing the DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi

# --------------------------------------------------------------- verify
step "Verifying"
codesign --verify --deep --strict --verbose=4 "$APP" 2>&1 | sed 's/^/  app  /'
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  spctl -a -t exec -vvv "$APP"                          2>&1 | sed 's/^/  app  /'
  xcrun stapler validate "$APP"                         2>&1 | sed 's/^/  app  /'
  xcrun stapler validate "$DMG"                         2>&1 | sed 's/^/  dmg  /'
  spctl -a -t open --context context:primary-signature -vvv "$DMG" 2>&1 | sed 's/^/  dmg  /'
else
  # Gatekeeper rejects an unnotarized build by design, so report the assessment
  # without treating it as a build failure — signatures are what matter here.
  spctl -a -t exec -vvv "$APP" 2>&1 | sed 's/^/  app  /' || true
  codesign --verify --strict --verbose=2 "$DMG" 2>&1 | sed 's/^/  dmg  /'
fi

# --------------------------------------------------------------- upload
if [[ $UPLOAD -eq 1 ]]; then
  step "Uploading to downloads.joinnile.com"
  if [[ -z "${R2_ACCESS_KEY_ID:-}" && -f "$R2_CREDS" ]]; then
    R2_ACCESS_KEY_ID="$(awk '/^S3 Access Key ID/{print $NF}' "$R2_CREDS")"
    R2_SECRET_ACCESS_KEY="$(awk '/^S3 Secret Access Key/{print $NF}' "$R2_CREDS")"
  fi
  [[ -n "${R2_ACCESS_KEY_ID:-}" && -n "${R2_SECRET_ACCESS_KEY:-}" ]] || fail "no R2 credentials"
  for key in "mac/${APP_NAME}-${SHORT}.dmg" "mac/${APP_NAME}.dmg"; do
    curl --fail-with-body -sS \
      --aws-sigv4 "aws:amz:auto:s3" \
      --user "${R2_ACCESS_KEY_ID}:${R2_SECRET_ACCESS_KEY}" \
      -H "Content-Type: application/x-apple-diskimage" \
      --upload-file "$DMG" \
      "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${R2_BUCKET}/${key}"
    echo "  https://downloads.joinnile.com/${key}"
  done
fi

step "Done — $DMG ($(du -h "$DMG" | cut -f1))"
