#!/bin/bash
# Xcode build phase: copy the engine (desktop/scripts/build_runtime.sh) into
# Squirrel.app/Contents/Resources/runtime for the architecture being built.
set -euo pipefail

ARCH="${ARCHS:-$(uname -m)}"
case "$ARCH" in
    arm64) ;;
    x86_64) ;;
    *) echo "error: build one architecture at a time (ARCHS=$ARCH)" >&2; exit 1 ;;
esac
RUNTIME="$PROJECT_DIR/../build/runtime-macos-$ARCH"
if [ ! -x "$RUNTIME/squirrel-host" ]; then
    echo "error: $RUNTIME is missing. Run desktop/scripts/build_runtime.sh macos-$ARCH first." >&2
    exit 1
fi

DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/runtime"
rm -rf "$DEST"
# -a keeps symlinks and permissions (the Python install relies on both)
rsync -a --exclude '__pycache__/*.opt-*.pyc' "$RUNTIME/" "$DEST/"
