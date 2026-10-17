#!/bin/bash
# RealSync 7a/7f: prove the jitter-buffer hook against the WebRTC build in
# macos/Pods, outside the app. Run before ANY flutter_webrtc / WebRTC-SDK
# upgrade, from nile_app/:  packages/nile_realsync/tool/run_probe.sh
set -euo pipefail
cd "$(dirname "$0")"
FW="$(cd ../../../macos/Pods/WebRTC-SDK/WebRTC.xcframework/macos-arm64_x86_64 && pwd)"
clang++ -std=c++17 -fobjc-arc -F"$FW" -framework WebRTC -framework Foundation -framework CoreVideo -framework QuartzCore \
  -I../src -Wl,-rpath,"$FW" rs_probe.mm ../src/realsync_stamp.cc -o /tmp/nile_rs_probe
/tmp/nile_rs_probe
