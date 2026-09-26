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

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$REPO/desktop/build"
OUT="$BUILD/runtime-$TARGET"

case "$TARGET" in
    macos-arm64)    TRIPLE=aarch64-apple-darwin;      PLATFORMS=(macosx_11_0_arm64 macosx_14_0_arm64); DENO="" ;;
    macos-x86_64)   TRIPLE=x86_64-apple-darwin;       PLATFORMS=(macosx_10_12_x86_64 macosx_11_0_x86_64); DENO="" ;;
    windows-x86_64) TRIPLE=x86_64-pc-windows-msvc;    PLATFORMS=(win_amd64); DENO="deno" ;;
    linux-x86_64)   TRIPLE=x86_64-unknown-linux-gnu;  PLATFORMS=(manylinux2014_x86_64 manylinux_2_27_x86_64 manylinux_2_28_x86_64); DENO="deno" ;;
    *) echo "Unknown target $TARGET" >&2; exit 1 ;;
esac

REMUX="$BUILD/remux-$TARGET"
if [ ! -d "$REMUX" ]; then
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
    "${PLATFORM_ARGS[@]}" "yt-dlp==$YTDLP_VERSION" "yt-dlp-ejs==$EJS_VERSION" $DENO \
    certifi brotli requests urllib3 websockets pycryptodomex
# That's yt-dlp's "default" extra minus mutagen (GPL), which it only uses to embed thumbnails
rm -rf "$OUT"/lib/*.dist-info/RECORD "$OUT/lib/yt_dlp/__pyinstaller" "$OUT/lib/share"
# Console scripts point at the build machine's Python; only Deno's binary is used
find "$OUT/lib/bin" -type f ! -name deno ! -name deno.exe -delete 2>/dev/null || true

echo "==> Host"
mkdir -p "$OUT/app" "$OUT/remux"
cp "$REPO"/shared/pybridge/*.py "$OUT/app/"
cp "$REPO/desktop/host/squirrel_host.py" "$REPO/desktop/host/remux.py" "$OUT/app/"
case "$TARGET" in
    # JavaScriptCore comes with macOS, so the Mac app needs no Deno
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
