#!/bin/bash
# Build LAME (LGPL), the MP3 encoder behind Remux.c's ytdl_convert_to_mp3, as a static
# library for FFmpeg to link. Called by the FFmpeg builds for desktop, iOS and Android:
#
#   shared/native/build_lame.sh <work dir> <prefix> <configure --host> <cc> [cflags]
#
# AR and RANLIB in the environment override the ones configure finds for the host.
# Installs <prefix>/lib/libmp3lame.a and <prefix>/include/lame/lame.h.
set -euo pipefail

WORK="$1"; PREFIX="$2"; HOST="$3"; CC="$4"; EXTRA_CFLAGS="${5:-}"
LAME_VERSION="${LAME_VERSION:-3.100}"
LAME_URL="${LAME_URL:-https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz}"

SRC="$WORK/lame-$LAME_VERSION"
if [ ! -d "$SRC" ]; then
    echo "==> Downloading LAME $LAME_VERSION"
    mkdir -p "$SRC"
    curl -fL --progress-bar "$LAME_URL" | tar -xz -C "$SRC" --strip-components=1
fi

# LAME builds in its source tree, so each target gets its own copy
BUILD="$WORK/lame-build-$(basename "$PREFIX")"
rm -rf "$BUILD"; cp -R "$SRC" "$BUILD"
# LAME's 2017 config.guess doesn't know Apple silicon; the build machine only matters for tools
BUILD_ARGS=()
[ "$(uname)" = Darwin ] && BUILD_ARGS=(--build="$(uname -m | sed 's/arm64/aarch64/')-apple-darwin")

echo "==> Building LAME for $HOST"
(cd "$BUILD" && CC="$CC" CFLAGS="-O2 -fPIC $EXTRA_CFLAGS" ./configure \
    --host="$HOST" "${BUILD_ARGS[@]}" --prefix="$PREFIX" \
    --enable-static --disable-shared --disable-frontend --disable-decoder \
    --disable-gtktest --disable-dependency-tracking >"$BUILD/configure.log" 2>&1) \
    || { tail -30 "$BUILD/configure.log"; exit 1; }
make -C "$BUILD" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)" install >"$BUILD/make.log" 2>&1 \
    || { tail -30 "$BUILD/make.log"; exit 1; }
# An archiver that can't read the target's objects leaves an empty library, which only shows later
[ "$(wc -c < "$PREFIX/lib/libmp3lame.a")" -gt 10000 ] || { echo "LAME built an empty library (wrong AR?)" >&2; exit 1; }
rm -rf "$BUILD"
