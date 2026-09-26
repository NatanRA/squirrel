#!/bin/bash
# Build Squirrel for Mac as a disk image -> desktop/build/Squirrel-macos-<arch>.dmg
#
#   ./desktop/macos/scripts/build_dmg.sh            # this Mac's architecture
#   ARCH=x86_64 ./desktop/macos/scripts/build_dmg.sh  # Intel build on Apple silicon
#
# Needs Xcode 16+ and XcodeGen. The app is ad-hoc signed, not notarized: on first
# launch, right-click it and choose Open (or run xattr -dr com.apple.quarantine).
set -euo pipefail

ARCH="${ARCH:-$(uname -m)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP="$(cd "$ROOT/.." && pwd)"
BUILD="$DESKTOP/build"
cd "$ROOT"

[ -x "$BUILD/runtime-macos-$ARCH/squirrel-host" ] || "$DESKTOP/scripts/build_runtime.sh" "macos-$ARCH"
xcodegen generate --quiet

rm -rf "$BUILD/macos-dd.noindex"
xcodebuild -project Squirrel.xcodeproj -scheme Squirrel -configuration Release \
    -derivedDataPath "$BUILD/macos-dd.noindex" ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO \
    ${APP_VERSION:+MARKETING_VERSION=$APP_VERSION} ${APP_BUILD:+CURRENT_PROJECT_VERSION=$APP_BUILD} \
    build -quiet
APP="$BUILD/macos-dd.noindex/Build/Products/Release/Squirrel.app"

# Sign inside-out: every Mach-O file in the engine, then the app
echo "==> Signing"
find "$APP/Contents/Resources/runtime" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) -print0 |
    while IFS= read -r -d '' file; do
        if file -b "$file" | grep -q Mach-O; then codesign --force --sign - --timestamp=none "$file"; fi
    done
codesign --force --sign - --timestamp=none "$APP"

echo "==> Creating disk image"
STAGE="$BUILD/macos-dmg"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$BUILD/Squirrel-macos-$ARCH.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname Squirrel -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
