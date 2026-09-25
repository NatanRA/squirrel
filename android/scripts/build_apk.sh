#!/bin/bash
# Build release APKs for sideloading -> build/apk/yt-dlp-arm64.apk (phones)
# and build/apk/yt-dlp-x86_64.apk (Intel emulators).
# Signed with the Android debug key; configure your own signingConfig to change that.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[ -f local.properties ] || echo "sdk.dir=${ANDROID_HOME:-$HOME/Library/Android/sdk}" > local.properties
[ -f app/src/main/cpp/ffmpeg/arm64-v8a/lib/libavformat.a ] || ./scripts/build_ffmpeg.sh

./gradlew assembleRelease --console=plain -q \
    ${APP_VERSION:+-PappVersion=$APP_VERSION} ${APP_BUILD:+-PappBuild=$APP_BUILD}

mkdir -p build/apk
cp app/build/outputs/apk/arm64/release/app-arm64-release.apk build/apk/yt-dlp-arm64.apk
cp app/build/outputs/apk/x86/release/app-x86-release.apk build/apk/yt-dlp-x86_64.apk
ls -la build/apk | awk 'NR>1 && $9 ~ /apk$/ {printf "Built build/apk/%s (%.1f MB)\n", $9, $5/1048576}'
