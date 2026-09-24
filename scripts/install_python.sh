#!/bin/bash
# Xcode build phase: copy the Python stdlib into the app and turn every
# binary extension module into an embedded framework (App Store rules forbid
# loose .so files, and iOS will only dlopen code from signed frameworks).
set -e

# Unsigned builds (for sideloading) have no identity; ad-hoc sign instead.
if [ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    export EXPANDED_CODE_SIGN_IDENTITY="-"
    export EXPANDED_CODE_SIGN_IDENTITY_NAME="ad-hoc"
fi

# Upstream utils.sh has one unquoted redirect that breaks on paths with spaces.
mkdir -p "$DERIVED_FILE_DIR"
sed 's|> ${FULL_EXT%.so}.fwork|> "${FULL_EXT%.so}.fwork"|' \
    "$PROJECT_DIR/Vendor/Python.xcframework/build/utils.sh" > "$DERIVED_FILE_DIR/python_utils.sh"
source "$DERIVED_FILE_DIR/python_utils.sh"
install_python Vendor/Python.xcframework app_packages

# Bytecode left over from running the bridge on a Mac during development
rm -rf "$CODESIGNING_FOLDER_PATH/PythonApp/__pycache__"
