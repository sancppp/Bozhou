#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/prepare.sh"
swift build --disable-sandbox --cache-path .runtime/cache/spm --product Bozhou
swift build --disable-sandbox --cache-path .runtime/cache/spm --product BozhouUpdater
source "$PROJECT_DIR/Scripts/native_test_support.sh"
swiftc -target "$(uname -m)-apple-macosx14.0" "${SOURCES[@]}" Tests/NativeUpdateInstallProbe.swift \
    "${NATIVE_OBJECTS[@]}" \
    -I "$BIN_PATH/Modules" -I Sources/CSQLite -lsqlite3 -o "$BIN_PATH/NativeUpdateInstallProbe"
"$PYTHON" Scripts/test_update_install.py "$BIN_PATH"
