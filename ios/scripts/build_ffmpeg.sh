#!/bin/bash
# Build a minimal FFmpeg for iOS as Vendor/FFmpeg.xcframework.
#
# What remuxing needs (demuxers, muxers, parsers and bitstream filters), plus
# the audio decoders, resampler and LAME encoder for MP3 conversion and the
# text subtitle codecs for embedding subtitles. No network and no GPL parts, so
# it stays small and LGPL. The app uses it to merge yt-dlp's separate
# video/audio streams, rewrap single files into clean MP4/M4A and make MP3s
# (see shared/native/Remux.c).
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

# Keep in sync with desktop/scripts/build_remux.sh and android/scripts/build_ffmpeg.sh
DEMUXERS="mov,matroska,mpegts,aac,mp3,flac,ogg,wav,image2,jpeg_pipe,png_pipe,webp_pipe,webvtt,srt"
MUXERS="mp4,ipod,mov,matroska,webm,mp3,adts,flac,ogg,opus"
PARSERS="h264,hevc,av1,vp8,vp9,aac,aac_latm,mpegaudio,opus,vorbis,flac,mjpeg,png,webp"
BSFS="aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata,vp9_superframe,vp9_superframe_split,av1_frame_merge,av1_frame_split,dump_extradata,null"
DECODERS="aac,opus,vorbis,mp3float,flac,webvtt,subrip"   # audio to convert to MP3; subtitles for MP4
ENCODERS="libmp3lame,movtext"  # movtext is mov_text, MP4's subtitle format

build() {   # build <sdk> <target> <prefix>
    local sdk=$1 target=$2 prefix=$3
    local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    local cc; cc="$(xcrun --sdk "$sdk" -f clang)"
    local dir="$WORK/build-$sdk"
    rm -rf "$dir" "$prefix"; mkdir -p "$dir"
    # A host other than this Mac's own, so LAME's configure knows it's cross-compiling
    "$ROOT/../shared/native/build_lame.sh" "$WORK" "$prefix" arm-apple-darwin \
        "$cc -target $target -isysroot $sysroot"
    echo "==> Configuring for $sdk"
    (cd "$dir" && "$SRC/configure" \
        --prefix="$prefix" \
        --enable-cross-compile --target-os=darwin --arch=aarch64 \
        --cc="$cc" --sysroot="$sysroot" \
        --extra-cflags="-target $target -fembed-bitcode-marker -I$prefix/include" \
        --extra-ldflags="-target $target -L$prefix/lib" \
        --enable-static --disable-shared --enable-pic \
        --disable-programs --disable-doc --disable-debug \
        --disable-everything --disable-network --disable-autodetect \
        --disable-avdevice --disable-avfilter --disable-swscale \
        --enable-protocol=file \
        --enable-demuxer="$DEMUXERS" --enable-muxer="$MUXERS" \
        --enable-parser="$PARSERS" --enable-bsf="$BSFS" \
        --enable-decoder="$DECODERS" --enable-encoder="$ENCODERS" --enable-libmp3lame \
        --enable-zlib >"$dir/configure.log" 2>&1) || { tail -30 "$dir/configure.log"; exit 1; }
    echo "==> Building for $sdk"
    make -C "$dir" -j"$(sysctl -n hw.ncpu)" install >"$dir/make.log" 2>&1 || { tail -30 "$dir/make.log"; exit 1; }
    # One static library per platform is easier to embed than three
    libtool -static -o "$prefix/libffmpeg.a" "$prefix"/lib/libavformat.a "$prefix"/lib/libavcodec.a \
        "$prefix"/lib/libswresample.a "$prefix"/lib/libavutil.a "$prefix"/lib/libmp3lame.a
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
cp "$WORK"/lame-[0-9]*/COPYING "$OUT/LICENSE-LAME"

echo "==> Done: $(du -sh "$OUT" | cut -f1) FFmpeg $FFMPEG_VERSION (LGPL) in Vendor/FFmpeg.xcframework"
