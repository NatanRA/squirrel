#!/bin/bash
# Build an IPA for sideloading (AltStore, SideStore, Sideloadly, TrollStore...).
# The app is ad-hoc signed; your sideloading tool re-signs it with your Apple ID.
#
#   ./scripts/build_ipa.sh             -> build/YTDL.ipa
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
cd "$ROOT"

[ -d Vendor/Python.xcframework ] && [ -d Vendor/app_packages ] || ./scripts/bootstrap.sh
xcodegen generate --quiet

rm -rf "$BUILD/dd" "$BUILD/Payload" "$BUILD/YTDL.ipa"
xcodebuild -project YTDL.xcodeproj -scheme YTDL -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$BUILD/dd" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build -quiet

APP="$BUILD/dd/Build/Products/Release-iphoneos/YTDL.app"

# Ad-hoc sign inside-out so tools that expect a signature (e.g. TrollStore) accept it.
find "$APP/Frameworks" -maxdepth 1 -name "*.framework" -print0 | xargs -0 -n1 codesign --force --sign - --timestamp=none
codesign --force --sign - --timestamp=none "$APP"

mkdir -p "$BUILD/Payload"
cp -R "$APP" "$BUILD/Payload/"
(cd "$BUILD" && zip -qry YTDL.ipa Payload && rm -rf Payload)

echo "Built $BUILD/YTDL.ipa ($(du -h "$BUILD/YTDL.ipa" | cut -f1))"
