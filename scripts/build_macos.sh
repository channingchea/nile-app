#!/usr/bin/env bash
#
# Nile for macOS — one command from source to a notarized, stapled DMG.
#
#   scripts/build_macos.sh                 full run: build, sign, DMG, notarize, staple, verify
#   scripts/build_macos.sh --skip-build    reuse the existing Release build
#   scripts/build_macos.sh --skip-notarize sign + DMG only (fast local iteration)
#   scripts/build_macos.sh --upload        also publish the DMG to downloads.joinnile.com
#
# Prerequisites (all set up in Phase 0):
#   * "Developer ID Application: CYGNUS INNOVATIONS, LLC (9LTD86C5X7)" in the login keychain
#   * notarytool keychain profile "nile"  (xcrun notarytool store-credentials)
#   * brew install create-dmg
#
set -euo pipefail

APP_NAME="Nile"
TEAM_ID="9LTD86C5X7"
IDENTITY="Developer ID Application: CYGNUS INNOVATIONS, LLC (${TEAM_ID})"
NOTARY_PROFILE="${NOTARY_PROFILE:-nile}"

R2_ACCOUNT_ID="${R2_ACCOUNT_ID:-9b1d86017f32cabde4f98a4799075994}"
R2_BUCKET="${R2_BUCKET:-nile-downloads}"
R2_CREDS="${R2_CREDS:-$HOME/Desktop/Developers Account info/macos-signing/r2-credentials.txt}"

SKIP_BUILD=0; SKIP_NOTARIZE=0; UPLOAD=0
for arg in "$@"; do case "$arg" in
  --skip-build)    SKIP_BUILD=1 ;;
  --skip-notarize) SKIP_NOTARIZE=1 ;;
  --upload)        UPLOAD=1 ;;
  *) echo "unknown flag: $arg" >&2; exit 2 ;;
esac; done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(sed -n 's/^version: *//p' pubspec.yaml | head -1 | tr -d '[:space:]')"
SHORT="${VERSION%%+*}"
APP="build/macos/Build/Products/Release/${APP_NAME}.app"
ENTITLEMENTS="macos/Runner/Release.entitlements"
DIST="build/macos/dist"
STAGE="$DIST/stage"
DMG="$DIST/${APP_NAME}-${SHORT}.dmg"

step() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- build
if [[ $SKIP_BUILD -eq 0 ]]; then
  step "flutter build macos --release  (v${SHORT}, build ${VERSION##*+})"
  flutter build macos --release
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

# ------------------------------------------------------- notarize the app
notarize() { # $1 = file to submit
  local out parsed id status
  out="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" \
        --wait --output-format json)"
  parsed="$(/usr/bin/python3 -c \
    'import json,sys; d=json.load(sys.stdin); print(d.get("id",""), d.get("status",""))' \
    <<<"$out")"
  id="${parsed%% *}"; status="${parsed#* }"
  echo "  submission $id → $status"
  if [[ "$status" != "Accepted" ]]; then
    echo "  --- notarization log ---"
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" 2>&1 | sed 's/^/  /'
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
step "Building ${APP_NAME}-${SHORT}.dmg"
rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
/usr/bin/ditto "$APP" "$STAGE/${APP_NAME}.app"

# Multi-resolution background so the window is crisp on Retina.
/usr/bin/tiffutil -cathidpicheck macos/dmg/background.png macos/dmg/background@2x.png \
  -out "$DIST/background.tiff" >/dev/null

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
rm -rf "$STAGE"

# ------------------------------------------------------ notarize the DMG
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  step "Notarizing the DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi

# --------------------------------------------------------------- verify
step "Verifying"
codesign --verify --deep --strict --verbose=4 "$APP" 2>&1 | sed 's/^/  app  /'
spctl -a -t exec -vvv "$APP"                            2>&1 | sed 's/^/  app  /'
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  xcrun stapler validate "$APP"                         2>&1 | sed 's/^/  app  /'
  xcrun stapler validate "$DMG"                         2>&1 | sed 's/^/  dmg  /'
  spctl -a -t open --context context:primary-signature -vvv "$DMG" 2>&1 | sed 's/^/  dmg  /'
fi

# --------------------------------------------------------------- upload
if [[ $UPLOAD -eq 1 ]]; then
  step "Uploading to downloads.joinnile.com"
  R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-$(awk '/^S3 Access Key ID/{print $NF}' "$R2_CREDS")}"
  R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-$(awk '/^S3 Secret Access Key/{print $NF}' "$R2_CREDS")}"
  [[ -n "$R2_ACCESS_KEY_ID" && -n "$R2_SECRET_ACCESS_KEY" ]] || fail "no R2 credentials"
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
