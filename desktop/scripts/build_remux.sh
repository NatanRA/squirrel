#!/bin/bash
# Build the desktop remux library: shared/native/Remux.c linked with a minimal FFmpeg.
#
#   ./desktop/scripts/build_remux.sh macos-arm64      # on a Mac (Xcode command line tools)
#   ./desktop/scripts/build_remux.sh macos-x86_64     # on a Mac
#   ./desktop/scripts/build_remux.sh windows-x86_64   # on Linux/macOS/WSL with mingw-w64
#   ./desktop/scripts/build_remux.sh linux-x86_64     # for running the host during development
#
# Same FFmpeg configuration as the mobile apps: demuxers, muxers, parsers and
# bitstream filters for remuxing, plus the audio decoders, resampler and LAME
# encoder that MP3 conversion needs and the text subtitle codecs for embedding
# subtitles. No GPL parts, so it stays small and LGPL (and needs no nasm).
# Output: desktop/build/remux-<target>/{lib file, LICENSE}
set -euo pipefail

TARGET="${1:?usage: build_remux.sh macos-arm64|macos-x86_64|windows-x86_64|linux-x86_64}"
FFMPEG_VERSION="${FFMPEG_VERSION:-9.0.2}"
FFMPEG_URL="${FFMPEG_URL:-https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz}"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$REPO/desktop/build/ffmpeg"
OUT="$REPO/desktop/build/remux-$TARGET"
mkdir -p "$WORK"

SRC="$WORK/ffmpeg-$FFMPEG_VERSION"
if [ ! -d "$SRC" ]; then
    echo "==> Downloading FFmpeg $FFMPEG_VERSION"
    mkdir -p "$SRC"
    curl -fL --progress-bar "$FFMPEG_URL" | tar -xJ -C "$SRC" --strip-components=1
fi

# Keep in sync with ios/scripts/build_ffmpeg.sh and android/scripts/build_ffmpeg.sh
DEMUXERS="mov,matroska,mpegts,aac,mp3,flac,ogg,wav,image2,jpeg_pipe,png_pipe,webp_pipe,webvtt,srt"
MUXERS="mp4,ipod,mov,matroska,webm,mp3,adts,flac,ogg,opus"
PARSERS="h264,hevc,av1,vp8,vp9,aac,aac_latm,mpegaudio,opus,vorbis,flac,mjpeg,png,webp"
BSFS="aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata,vp9_superframe,vp9_superframe_split,av1_frame_merge,av1_frame_split,dump_extradata,null"
DECODERS="aac,opus,vorbis,mp3float,flac,webvtt,subrip"   # audio to convert to MP3; subtitles for MP4
ENCODERS="libmp3lame,movtext"  # movtext is mov_text, MP4's subtitle format

JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)"
CROSS=()
ZLIB=(--enable-zlib)
case "$TARGET" in
    macos-arm64|macos-x86_64)
        ARCH="${TARGET#macos-}"
        CC="clang -arch $ARCH -mmacosx-version-min=11.0"
        CROSS=(--enable-cross-compile --target-os=darwin --arch="${ARCH/arm64/aarch64}")
        LAME_HOST="${ARCH/arm64/aarch64}-apple-darwin"
        LIB=libsquirrelremux.dylib
        LINK=(-dynamiclib -install_name @rpath/$LIB -lz -Wl,-dead_strip)
        ;;
    windows-x86_64)
        PREFIX=x86_64-w64-mingw32-
        CC="${PREFIX}gcc"
        CROSS=(--enable-cross-compile --target-os=mingw32 --arch=x86_64 --cross-prefix="$PREFIX")
        ZLIB=(--disable-zlib)  # mingw has no zlib by default; only rare legacy files need it
        LAME_HOST=x86_64-w64-mingw32
        LIB=squirrelremux.dll
        LINK=(-shared -static-libgcc -Wl,--exclude-libs,ALL -lbcrypt)
        ;;
    linux-x86_64)
        CC=gcc
        LAME_HOST=x86_64-linux-gnu
        LIB=libsquirrelremux.so
        LINK=(-shared -Wl,-Bsymbolic -Wl,--exclude-libs,ALL -lz -lm)
        ;;
    *) echo "Unknown target $TARGET" >&2; exit 1 ;;
esac

BUILD="$WORK/build-$TARGET"
PREFIX_DIR="$WORK/out-$TARGET"
# (Builds from before MP3 support have no libmp3lame.a, so they're rebuilt too)
if [ ! -f "$PREFIX_DIR/lib/libavformat.a" ] || [ ! -f "$PREFIX_DIR/lib/libmp3lame.a" ] || [ -n "${REBUILD_FFMPEG:-}" ]; then
    rm -rf "$BUILD" "$PREFIX_DIR"; mkdir -p "$BUILD"
    "$REPO/shared/native/build_lame.sh" "$WORK" "$PREFIX_DIR" "$LAME_HOST" "$CC"
    echo "==> Configuring FFmpeg for $TARGET"
    (cd "$BUILD" && "$SRC/configure" \
        --prefix="$PREFIX_DIR" "${CROSS[@]}" --cc="$CC" \
        --enable-static --disable-shared --enable-pic \
        --disable-programs --disable-doc --disable-debug --disable-x86asm \
        --disable-everything --disable-network --disable-autodetect \
        --disable-avdevice --disable-avfilter --disable-swscale \
        --enable-protocol=file \
        --enable-demuxer="$DEMUXERS" --enable-muxer="$MUXERS" \
        --enable-parser="$PARSERS" --enable-bsf="$BSFS" \
        --enable-decoder="$DECODERS" --enable-encoder="$ENCODERS" \
        --enable-libmp3lame --extra-cflags="-I$PREFIX_DIR/include" --extra-ldflags="-L$PREFIX_DIR/lib" \
        "${ZLIB[@]}" >"$BUILD/configure.log" 2>&1) || { tail -30 "$BUILD/configure.log"; exit 1; }
    echo "==> Building FFmpeg"
    make -C "$BUILD" -j"$JOBS" install >"$BUILD/make.log" 2>&1 || { tail -30 "$BUILD/make.log"; exit 1; }
fi

echo "==> Linking $LIB"
rm -rf "$OUT"; mkdir -p "$OUT"
# shellcheck disable=SC2086  # CC may carry flags
$CC -O2 -fPIC -I"$PREFIX_DIR/include" -o "$OUT/$LIB" "$REPO/shared/native/Remux.c" \
    "$PREFIX_DIR/lib/libavformat.a" "$PREFIX_DIR/lib/libavcodec.a" "$PREFIX_DIR/lib/libswresample.a" \
    "$PREFIX_DIR/lib/libavutil.a" "$PREFIX_DIR/lib/libmp3lame.a" \
    "${LINK[@]}"
cp "$SRC/COPYING.LGPLv2.1" "$OUT/LICENSE"
cp "$WORK"/lame-[0-9]*/COPYING "$OUT/LICENSE-LAME"
echo "==> Done: $OUT/$LIB ($(du -h "$OUT/$LIB" | cut -f1), FFmpeg $FFMPEG_VERSION with LAME, LGPL)"
