#!/bin/bash
# Build both apps and publish them as a GitHub release:
#   ./scripts/release.sh v1.1.0
# The README's download links point at releases/latest, so they follow automatically.
set -euo pipefail

TAG="${1:?usage: scripts/release.sh vX.Y.Z}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
cd "$ROOT"

# Stamp the version into both apps: 1.2.3 -> version "1.2.3", build number 10203
export APP_VERSION="${TAG#v}"
IFS=. read -r major minor patch <<<"$APP_VERSION"
export APP_BUILD=$(( ${major:-0} * 10000 + ${minor:-0} * 100 + ${patch:-0} ))

./ios/scripts/build_ipa.sh
./android/scripts/build_apk.sh

rm -rf "$OUT" && mkdir -p "$OUT"
cp ios/build/YTDL.ipa "$OUT/yt-dlp.ipa"
cp android/build/apk/yt-dlp-arm64.apk "$OUT/yt-dlp-arm64.apk"
cp android/build/apk/yt-dlp-x86_64.apk "$OUT/yt-dlp-x86_64.apk"

gh release create "$TAG" "$OUT"/* --title "$TAG" --generate-notes
