#!/bin/bash
# Assemble the desktop engine the Mac and Windows apps (and the browser extension) run:
#
#   desktop/build/runtime-<target>/
#     python/          standalone CPython 3.14 (python-build-standalone)
#     lib/             yt-dlp and its dependencies (+ Deno on Windows)
#     app/             the shared bridge (shared/pybridge) and the host (desktop/host)
#     remux/           Remux.c + minimal FFmpeg (build_remux.sh)
#     squirrel-host    launcher (squirrel-host.bat on Windows)
#
#   ./desktop/scripts/build_runtime.sh macos-arm64|macos-x86_64|windows-x86_64|linux-x86_64
#
# Needs curl and a host python3 with pip. Cross-building works (e.g. the Windows
# runtime on Linux or macOS): packages are fetched as wheels for the target.
set -euo pipefail

TARGET="${1:?usage: build_runtime.sh macos-arm64|macos-x86_64|windows-x86_64|linux-x86_64}"
PBS_RELEASE="${PBS_RELEASE:-20260924}"
PY_MINOR="${PY_MINOR:-3.14}"
# Keep in sync with android/app/build.gradle.kts and ios/scripts/bootstrap.sh
YTDLP_VERSION="${YTDLP_VERSION:-2026.8.19}"
EJS_VERSION="${EJS_VERSION:-0.8.0}"
# JavaScript for YouTube's challenges where the OS has no engine yt-dlp can use (macOS has JavaScriptCore)
QUICKJS_VERSION="${QUICKJS_VERSION:-v0.17.0}"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$REPO/desktop/build"
OUT="$BUILD/runtime-$TARGET"

case "$TARGET" in
    macos-arm64)    TRIPLE=aarch64-apple-darwin;      PLATFORMS=(macosx_11_0_arm64 macosx_14_0_arm64); QJS="" ;;
    macos-x86_64)   TRIPLE=x86_64-apple-darwin;       PLATFORMS=(macosx_10_12_x86_64 macosx_11_0_x86_64); QJS="" ;;
    windows-x86_64) TRIPLE=x86_64-pc-windows-msvc;    PLATFORMS=(win_amd64); QJS=qjs-windows-x86_64.exe ;;
    linux-x86_64)   TRIPLE=x86_64-unknown-linux-gnu;  PLATFORMS=(manylinux2014_x86_64 manylinux_2_27_x86_64 manylinux_2_28_x86_64); QJS=qjs-linux-x86_64 ;;
    *) echo "Unknown target $TARGET" >&2; exit 1 ;;
esac

REMUX="$BUILD/remux-$TARGET"
# One from before MP3 support has no LAME licence and lacks the functions the host calls
if [ ! -f "$REMUX/LICENSE-LAME" ]; then
    "$REPO/desktop/scripts/build_remux.sh" "$TARGET"
fi

rm -rf "$OUT"; mkdir -p "$OUT"

CACHE="$BUILD/downloads"; mkdir -p "$CACHE"
if [ -n "${LOCAL_PYTHON:-}" ]; then
    # Development: link an existing install (a prefix with bin/python3) instead of downloading
    echo "==> Using $LOCAL_PYTHON"
    ln -s "$LOCAL_PYTHON" "$OUT/python"
else
    echo "==> Python $PY_MINOR for $TARGET (python-build-standalone $PBS_RELEASE)"
    ASSET="$(curl -fsSL "https://api.github.com/repos/astral-sh/python-build-standalone/releases/tags/$PBS_RELEASE" \
        | grep -o "\"name\": *\"cpython-$PY_MINOR\.[0-9]*+$PBS_RELEASE-$TRIPLE-install_only_stripped\.tar\.gz\"" \
        | head -1 | sed 's/.*"\(cpython[^"]*\)"/\1/')"
    [ -n "$ASSET" ] || { echo "No Python $PY_MINOR build for $TRIPLE in release $PBS_RELEASE" >&2; exit 1; }
    [ -f "$CACHE/$ASSET" ] || curl -fL --progress-bar -o "$CACHE/$ASSET" \
        "https://github.com/astral-sh/python-build-standalone/releases/download/$PBS_RELEASE/${ASSET//+/%2B}"
    tar -xzf "$CACHE/$ASSET" -C "$OUT"   # -> python/
fi

echo "==> yt-dlp $YTDLP_VERSION"
PLATFORM_ARGS=(); for p in "${PLATFORMS[@]}"; do PLATFORM_ARGS+=(--platform "$p"); done
python3 -m pip install --quiet --disable-pip-version-check --no-compile \
    --target "$OUT/lib" --implementation cp --python-version "$PY_MINOR" --only-binary=:all: \
    "${PLATFORM_ARGS[@]}" "yt-dlp==$YTDLP_VERSION" "yt-dlp-ejs==$EJS_VERSION" \
    certifi brotli requests urllib3 websockets pycryptodomex
# That's yt-dlp's "default" extra minus mutagen (GPL), which it only uses to embed thumbnails
rm -rf "$OUT"/lib/*.dist-info/RECORD "$OUT/lib/yt_dlp/__pyinstaller" "$OUT/lib/share" "$OUT/lib/bin"

if [ -n "$QJS" ]; then
    # QuickJS-ng: a 2 MB engine yt-dlp supports (Deno, the other choice, is ~100 MB)
    echo "==> QuickJS-ng $QUICKJS_VERSION"
    QJS_FILE="$CACHE/quickjs-$QUICKJS_VERSION-$QJS"
    [ -f "$QJS_FILE" ] || curl -fL --progress-bar -o "$QJS_FILE" \
        "https://github.com/quickjs-ng/quickjs/releases/download/$QUICKJS_VERSION/$QJS"
    mkdir -p "$OUT/lib/bin"
    QJS_NAME=qjs; [[ "$QJS" == *.exe ]] && QJS_NAME=qjs.exe
    cp "$QJS_FILE" "$OUT/lib/bin/$QJS_NAME" && chmod +x "$OUT/lib/bin/$QJS_NAME"
fi

# Parts of Python the engine never uses: the Tk GUI toolkit, IDLE, pip's installer, headers
# (By target, not by testing for Lib/: Macs don't tell lib and Lib apart)
case "$TARGET" in
    windows-*) PYLIB="$OUT/python/Lib" ;;
    *) PYLIB="$OUT/python/lib/python$PY_MINOR" ;;
esac
rm -rf "$PYLIB"/{tkinter,idlelib,turtledemo,ensurepip,pydoc_data,lib2to3,test,turtle.py} \
    "$OUT"/python/{tcl,include,libs} "$OUT"/python/lib/{tcl*,tk*,itcl*,thread*} "$OUT"/python/lib/libtcl* "$OUT"/python/lib/libtk* \
    "$OUT"/python/DLLs/{_tkinter.pyd,tcl*.dll,tk*.dll,zlib*.dll.bak} "$PYLIB"/lib-dynload/_tkinter* 2>/dev/null || true

echo "==> Host"
mkdir -p "$OUT/app" "$OUT/remux"
cp "$REPO"/shared/pybridge/*.py "$OUT/app/"
cp "$REPO/desktop/host/squirrel_host.py" "$REPO/desktop/host/remux.py" "$OUT/app/"
case "$TARGET" in
    # JavaScriptCore comes with macOS, so the Mac app needs no QuickJS
    macos-*) cp "$REPO/desktop/host/_host.py" "$OUT/app/" ;;
esac
cp "$REMUX"/* "$OUT/remux/"

# Compiled bytecode goes to the user's cache folder (pycache_prefix), never into the app:
# writing inside the Mac app breaks its signature, and macOS and Safari then distrust it.
if [ "$TARGET" = windows-x86_64 ]; then
    printf '@echo off\r\n"%%~dp0python\\python.exe" -I -X utf8 -X "pycache_prefix=%%LOCALAPPDATA%%\\Squirrel\\pycache" "%%~dp0app\\squirrel_host.py" %%*\r\n' > "$OUT/squirrel-host.bat"
else
    cat > "$OUT/squirrel-host" <<'EOF'
#!/bin/sh
DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
[ "$(uname)" = Darwin ] && CACHE="$HOME/Library/Caches"
exec "$DIR/python/bin/python3" -I -X utf8 -X "pycache_prefix=$CACHE/Squirrel/pycache" "$DIR/app/squirrel_host.py" "$@"
EOF
    chmod +x "$OUT/squirrel-host"
fi

echo "==> Done: $OUT ($(du -sh "$OUT" | cut -f1))"
