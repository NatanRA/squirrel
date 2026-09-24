#!/bin/bash
# Build a minimal FFmpeg for iOS as Vendor/FFmpeg.xcframework.
#
# Only what remuxing needs: demuxers, muxers, parsers and bitstream filters.
# No encoders or decoders, no network, no GPL parts, so it stays small and
# LGPL-2.1. The app uses it to merge yt-dlp's separate video/audio streams and
# to rewrap single files into clean MP4/M4A (see App/Bridge/Remux.c).
set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-9.0.2}"
MIN_IOS="18.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/ffmpeg"
OUT="$ROOT/Vendor/FFmpeg.xcframework"
mkdir -p "$WORK"

SRC="$WORK/ffmpeg-$FFMPEG_VERSION"
if [ ! -d "$SRC" ]; then
    echo "==> Downloading FFmpeg $FFMPEG_VERSION"
    curl -fL --progress-bar "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" | tar -xJ -C "$WORK"
fi

DEMUXERS="mov,matroska,mpegts,aac,mp3,flac,ogg,wav,image2,jpeg_pipe,png_pipe,webp_pipe"
MUXERS="mp4,ipod,mov,matroska,webm,mp3,adts,flac,ogg,opus"
PARSERS="h264,hevc,av1,vp8,vp9,aac,aac_latm,mpegaudio,opus,vorbis,flac,mjpeg,png,webp"
BSFS="aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata,vp9_superframe,vp9_superframe_split,av1_frame_merge,av1_frame_split,dump_extradata,null"

build() {   # build <sdk> <target> <prefix>
    local sdk=$1 target=$2 prefix=$3
    local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    local cc; cc="$(xcrun --sdk "$sdk" -f clang)"
    local dir="$WORK/build-$sdk"
    rm -rf "$dir" "$prefix"; mkdir -p "$dir"
    echo "==> Configuring for $sdk"
    (cd "$dir" && "$SRC/configure" \
        --prefix="$prefix" \
        --enable-cross-compile --target-os=darwin --arch=aarch64 \
        --cc="$cc" --sysroot="$sysroot" \
        --extra-cflags="-target $target -fembed-bitcode-marker" \
        --extra-ldflags="-target $target" \
        --enable-static --disable-shared --enable-pic \
        --disable-programs --disable-doc --disable-debug \
        --disable-everything --disable-network --disable-autodetect \
        --disable-avdevice --disable-avfilter --disable-swscale --disable-swresample \
        --enable-protocol=file \
        --enable-demuxer="$DEMUXERS" --enable-muxer="$MUXERS" \
        --enable-parser="$PARSERS" --enable-bsf="$BSFS" \
        --enable-zlib >"$dir/configure.log" 2>&1) || { tail -30 "$dir/configure.log"; exit 1; }
    echo "==> Building for $sdk"
    make -C "$dir" -j"$(sysctl -n hw.ncpu)" install >"$dir/make.log" 2>&1 || { tail -30 "$dir/make.log"; exit 1; }
    # One static library per platform is easier to embed than three
    libtool -static -o "$prefix/libffmpeg.a" "$prefix"/lib/libavformat.a "$prefix"/lib/libavcodec.a "$prefix"/lib/libavutil.a
}

build iphoneos "arm64-apple-ios$MIN_IOS" "$WORK/out-iphoneos"
build iphonesimulator "arm64-apple-ios$MIN_IOS-simulator" "$WORK/out-iphonesimulator"

echo "==> Creating xcframework"
rm -rf "$OUT"
xcodebuild -create-xcframework \
    -library "$WORK/out-iphoneos/libffmpeg.a" -headers "$WORK/out-iphoneos/include" \
    -library "$WORK/out-iphonesimulator/libffmpeg.a" -headers "$WORK/out-iphonesimulator/include" \
    -output "$OUT" >/dev/null
cp "$SRC/COPYING.LGPLv2.1" "$OUT/LICENSE"

echo "==> Done: $(du -sh "$OUT" | cut -f1) FFmpeg $FFMPEG_VERSION (LGPL) in Vendor/FFmpeg.xcframework"
