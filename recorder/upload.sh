#!/usr/bin/env bash
# Publish the grid replay recorder page to https://downloads.joinnile.com/recorder/v1/
# (same R2 bucket and credentials as scripts/build_macos.sh). Bump VERSION when
# the page changes in a way running shows mustn't pick up halfway, then point
# the livekit function's REPLAY_RECORDER_URL secret at the new folder.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-v1}"
LIVEKIT_CLIENT="2.17.3"
R2_ACCOUNT_ID="${R2_ACCOUNT_ID:-9b1d86017f32cabde4f98a4799075994}"
R2_BUCKET="${R2_BUCKET:-nile-downloads}"
R2_CREDS="${R2_CREDS:-$HOME/Desktop/Developers Account info/macos-signing/r2-credentials.txt}"
if [[ -z "${R2_ACCESS_KEY_ID:-}" && -f "$R2_CREDS" ]]; then
  R2_ACCESS_KEY_ID="$(awk '/^S3 Access Key ID/{print $NF}' "$R2_CREDS")"
  R2_SECRET_ACCESS_KEY="$(awk '/^S3 Secret Access Key/{print $NF}' "$R2_CREDS")"
fi
[[ -n "${R2_ACCESS_KEY_ID:-}" && -n "${R2_SECRET_ACCESS_KEY:-}" ]] || { echo "no R2 credentials" >&2; exit 1; }

node recorder_test.js

# The LiveKit client is served next to the page — no third-party CDN in the
# middle of a recording.
tmp="$(mktemp -d)"
(cd "$tmp" && npm pack "livekit-client@${LIVEKIT_CLIENT}" --silent >/dev/null && tar xzf "livekit-client-${LIVEKIT_CLIENT}.tgz")
cp "$tmp/package/dist/livekit-client.umd.js" "$tmp/livekit-client.umd.js"

put() { # file content-type
  curl --fail-with-body -sS \
    --aws-sigv4 "aws:amz:auto:s3" \
    --user "${R2_ACCESS_KEY_ID}:${R2_SECRET_ACCESS_KEY}" \
    -H "Content-Type: $2" \
    -H "Cache-Control: public, max-age=300" \
    --upload-file "$1" \
    "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${R2_BUCKET}/recorder/${VERSION}/$(basename "$1")"
  echo "  https://downloads.joinnile.com/recorder/${VERSION}/$(basename "$1")"
}
put index.html "text/html; charset=utf-8"
put recorder.js "application/javascript; charset=utf-8"
put "$tmp/livekit-client.umd.js" "application/javascript; charset=utf-8"
rm -rf "$tmp"
