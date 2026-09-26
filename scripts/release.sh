#!/bin/bash
# Build the apps and publish them as a GitHub release (run on a Mac):
#   ./scripts/release.sh v1.1.0
# The Windows installer can only be packaged on Windows: publishing the release starts
# .github/workflows/windows.yml, which builds Squirrel-Setup.exe and adds it a few minutes later.
# To attach one built yourself instead: WINDOWS_INSTALLER=path/to/Squirrel-Setup.exe ./scripts/release.sh v1.1.0
# The README's download links point at releases/latest, so they follow automatically.
set -euo pipefail

TAG="${1:?usage: scripts/release.sh vX.Y.Z}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
cd "$ROOT"

# Stamp the version into every app: 1.2.3 -> version "1.2.3", build number 10203
export APP_VERSION="${TAG#v}"
IFS=. read -r major minor patch <<<"$APP_VERSION"
export APP_BUILD=$(( ${major:-0} * 10000 + ${minor:-0} * 100 + ${patch:-0} ))

./ios/scripts/build_ipa.sh
./android/scripts/build_apk.sh
./desktop/macos/scripts/build_dmg.sh

rm -rf "$OUT" && mkdir -p "$OUT"
cp ios/build/Squirrel.ipa "$OUT/Squirrel.ipa"
cp android/build/apk/Squirrel-arm64.apk "$OUT/Squirrel-arm64.apk"
cp android/build/apk/Squirrel-x86_64.apk "$OUT/Squirrel-x86_64.apk"
cp "desktop/build/Squirrel-macos-$(uname -m).dmg" "$OUT/"
if [ -n "${WINDOWS_INSTALLER:-}" ]; then
    cp "$WINDOWS_INSTALLER" "$OUT/Squirrel-Setup.exe"
else
    echo "The Windows installer is added by GitHub Actions (.github/workflows/windows.yml)"
fi

# The extension ships as source; stamp the version into its manifest
STAGE="$(mktemp -d)"
cp -R extension "$STAGE/Squirrel-extension"
sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$APP_VERSION\"/" "$STAGE/Squirrel-extension/manifest.json"
(cd "$STAGE" && zip -qr "$OUT/Squirrel-extension.zip" Squirrel-extension -x '*/README.md')
rm -rf "$STAGE"

gh release create "$TAG" "$OUT"/* --title "$TAG" --generate-notes
