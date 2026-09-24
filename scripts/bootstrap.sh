#!/bin/bash
# Fetch the embedded Python runtime and the yt-dlp Python packages into Vendor/.
# Re-run with a new YTDLP_VERSION to update yt-dlp.
set -euo pipefail

PY_VERSION="${PY_VERSION:-3.14}"
PY_BUILD="${PY_BUILD:-b11}"
YTDLP_VERSION="${YTDLP_VERSION:-2026.8.19}"
EJS_VERSION="${EJS_VERSION:-0.8.0}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
mkdir -p "$VENDOR"

HOST_PY="$(command -v "python$PY_VERSION" || command -v python3)"
if [ "$("$HOST_PY" -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')" != "$PY_VERSION" ]; then
    echo "error: need a host Python $PY_VERSION to precompile bytecode (found $("$HOST_PY" --version))" >&2
    exit 1
fi

if [ ! -d "$VENDOR/Python.xcframework" ]; then
    echo "==> Downloading Python $PY_VERSION ($PY_BUILD) for iOS"
    TMP="$(mktemp -d)"
    curl -fL --progress-bar \
        "https://github.com/beeware/Python-Apple-support/releases/download/$PY_VERSION-$PY_BUILD/Python-$PY_VERSION-iOS-support.$PY_BUILD.tar.gz" \
        | tar -xz -C "$TMP"
    mv "$TMP/Python.xcframework" "$VENDOR/"
    rm -rf "$TMP"

    echo "==> Trimming unused parts of the standard library"
    STDLIB="$VENDOR/Python.xcframework/lib/python$PY_VERSION"
    for m in test idlelib tkinter turtledemo ensurepip lib2to3 pydoc_data venv _pyrepl \
             turtle.py pydoc.py antigravity.py this.py doctest.py; do
        rm -rf "${STDLIB:?}/$m"
    done
    find "$STDLIB" -type d -name tests -prune -exec rm -rf {} +

    echo "==> Precompiling the standard library"
    "$HOST_PY" -m compileall -q -j0 --invalidation-mode unchecked-hash "$STDLIB" || true
fi

echo "==> Installing yt-dlp $YTDLP_VERSION"
rm -rf "$VENDOR/app_packages"
"$HOST_PY" -m pip install --quiet --no-deps --no-compile --target "$VENDOR/app_packages" \
    "yt-dlp==$YTDLP_VERSION" "yt-dlp-ejs==$EJS_VERSION" certifi
rm -rf "$VENDOR/app_packages/bin" "$VENDOR/app_packages"/yt_dlp-*.data
"$HOST_PY" -m compileall -q -j0 --invalidation-mode unchecked-hash "$VENDOR/app_packages"

echo "==> Done. yt-dlp $YTDLP_VERSION + Python $PY_VERSION ready in Vendor/"
