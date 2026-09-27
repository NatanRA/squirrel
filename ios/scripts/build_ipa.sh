#!/bin/bash
# Build an IPA for sideloading (AltStore, SideStore, Sideloadly, TrollStore...).
# The app is ad-hoc signed; your sideloading tool re-signs it with your Apple ID.
#
#   ./scripts/build_ipa.sh             -> build/Squirrel.ipa
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
cd "$ROOT"

[ -d Vendor/Python.xcframework ] && [ -d Vendor/app_packages ] || ./scripts/bootstrap.sh
# (One from before MP3 support has no LAME licence and lacks what Remux.c now calls, and one from
# before converting for Photos lacks the HEVC encoder Convert.c uses)
[ -f Vendor/FFmpeg.xcframework/LICENSE-LAME ] \
    && grep -aq ff_hevc_videotoolbox_encoder Vendor/FFmpeg.xcframework/ios-arm64/libffmpeg.a \
    || ./scripts/build_ffmpeg.sh
xcodegen generate --quiet

rm -rf "$BUILD/dd.noindex" "$BUILD/Payload" "$BUILD/Squirrel.ipa"
xcodebuild -project Squirrel.xcodeproj -scheme Squirrel -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$BUILD/dd.noindex" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    ${APP_VERSION:+MARKETING_VERSION=$APP_VERSION} ${APP_BUILD:+CURRENT_PROJECT_VERSION=$APP_BUILD} \
    build -quiet

APP="$BUILD/dd.noindex/Build/Products/Release-iphoneos/Squirrel.app"

# Ad-hoc sign inside-out so tools that expect a signature (e.g. TrollStore) accept it.
find "$APP/Frameworks" -maxdepth 1 -name "*.framework" -print0 | xargs -0 -n1 codesign --force --sign - --timestamp=none
find "$APP/PlugIns" -maxdepth 1 -name "*.appex" -print0 | xargs -0 -n1 codesign --force --sign - --timestamp=none
codesign --force --sign - --timestamp=none "$APP"

mkdir -p "$BUILD/Payload"
cp -R "$APP" "$BUILD/Payload/"
(cd "$BUILD" && zip -qry Squirrel.ipa Payload && rm -rf Payload)

echo "Built $BUILD/Squirrel.ipa ($(du -h "$BUILD/Squirrel.ipa" | cut -f1))"
