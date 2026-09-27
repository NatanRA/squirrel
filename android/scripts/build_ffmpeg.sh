#!/bin/bash
# Build the minimal FFmpeg (same configuration as ios/scripts/build_ffmpeg.sh), with LAME
# for MP3s, as static libraries for Android, into app/src/main/cpp/ffmpeg/<abi>/.
# The app's JNI library links them with shared/native/Remux.c.
set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-9.0.2}"
API=29
ABIS="${ABIS:-arm64-v8a x86_64}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
NDK="${ANDROID_NDK_HOME:-$(ls -d "$SDK"/ndk/* | sort -V | tail -1)}"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
WORK="$ROOT/build/ffmpeg"
OUT="$ROOT/app/src/main/cpp/ffmpeg"
mkdir -p "$WORK"

SRC="$WORK/ffmpeg-$FFMPEG_VERSION"
if [ ! -d "$SRC" ]; then
    echo "==> Downloading FFmpeg $FFMPEG_VERSION"
    curl -fL --progress-bar "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" | tar -xJ -C "$WORK"
fi

# Keep in sync with desktop/scripts/build_remux.sh and ios/scripts/build_ffmpeg.sh
DEMUXERS="mov,matroska,mpegts,aac,mp3,flac,ogg,wav,image2,jpeg_pipe,png_pipe,webp_pipe,webvtt,srt"
MUXERS="mp4,ipod,mov,matroska,webm,mp3,adts,flac,ogg,opus"
PARSERS="h264,hevc,av1,vp8,vp9,aac,aac_latm,mpegaudio,opus,vorbis,flac,mjpeg,png,webp"
BSFS="aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata,vp9_superframe,vp9_superframe_split,av1_frame_merge,av1_frame_split,dump_extradata,null"
DECODERS="aac,opus,vorbis,mp3float,flac,webvtt,subrip"   # audio to convert to MP3; subtitles for MP4
ENCODERS="libmp3lame,movtext"  # movtext is mov_text, MP4's subtitle format

for abi in $ABIS; do
    case $abi in
        arm64-v8a) arch=aarch64; triple=aarch64-linux-android ;;
        x86_64)    arch=x86_64;  triple=x86_64-linux-android ;;
        *) echo "unsupported ABI $abi"; exit 1 ;;
    esac
    dir="$WORK/build-$abi"; prefix="$OUT/$abi"
    rm -rf "$dir" "$prefix"; mkdir -p "$dir"
    # The NDK has only LLVM's archiver, which LAME's configure wouldn't find by itself
    AR="$TOOLCHAIN/bin/llvm-ar" RANLIB="$TOOLCHAIN/bin/llvm-ranlib" \
        "$ROOT/../shared/native/build_lame.sh" "$WORK" "$prefix" "$triple" "$TOOLCHAIN/bin/$triple$API-clang"
    echo "==> Configuring for $abi"
    (cd "$dir" && "$SRC/configure" \
        --prefix="$prefix" \
        --enable-cross-compile --target-os=android --arch="$arch" \
        --cc="$TOOLCHAIN/bin/$triple$API-clang" --cxx="$TOOLCHAIN/bin/$triple$API-clang++" \
        --ar="$TOOLCHAIN/bin/llvm-ar" --nm="$TOOLCHAIN/bin/llvm-nm" \
        --ranlib="$TOOLCHAIN/bin/llvm-ranlib" --strip="$TOOLCHAIN/bin/llvm-strip" \
        --sysroot="$TOOLCHAIN/sysroot" \
        --extra-cflags="-I$prefix/include" --extra-ldflags="-L$prefix/lib" \
        --enable-static --disable-shared --enable-pic --disable-asm \
        --disable-programs --disable-doc --disable-debug \
        --disable-everything --disable-network --disable-autodetect \
        --disable-avdevice --disable-avfilter --disable-swscale \
        --enable-protocol=file \
        --enable-demuxer="$DEMUXERS" --enable-muxer="$MUXERS" \
        --enable-parser="$PARSERS" --enable-bsf="$BSFS" \
        --enable-decoder="$DECODERS" --enable-encoder="$ENCODERS" --enable-libmp3lame \
        --enable-zlib >"$dir/configure.log" 2>&1) || { tail -30 "$dir/configure.log"; exit 1; }
    echo "==> Building for $abi"
    make -C "$dir" -j"$(sysctl -n hw.ncpu)" install >"$dir/make.log" 2>&1 || { tail -30 "$dir/make.log"; exit 1; }
    rm -rf "$prefix/lib/pkgconfig" "$prefix/share"
done
cp "$SRC/COPYING.LGPLv2.1" "$OUT/LICENSE"
cp "$WORK"/lame-[0-9]*/COPYING "$OUT/LICENSE-LAME"
echo "==> Done: FFmpeg $FFMPEG_VERSION (LGPL) for $ABIS in app/src/main/cpp/ffmpeg ($(du -sh "$OUT" | cut -f1))"
