#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/prepare.sh"
swift build --disable-sandbox --cache-path .runtime/cache/spm --product Bozhou
swift build --disable-sandbox --cache-path .runtime/cache/spm --product BozhouAskPass
source "$PROJECT_DIR/Scripts/native_test_support.sh"
swiftc "${SOURCES[@]}" Tests/NativeHostsTests.swift Tests/NativeLiveTerminalProbe.swift Tests/NativeLayoutProbe.swift \
    "${NATIVE_OBJECTS[@]}" \
    -I "$BIN_PATH/Modules" -I Sources/CSQLite -lsqlite3 -o "$BIN_PATH/NativeHostsTests"
TEST_DATA="$(mktemp -d "$PROJECT_DIR/.runtime/tmp/hosts-ui.XXXXXXXX")"
trap 'rm -rf "$TEST_DATA"' EXIT
BOZHOU_DATA_DIR="$TEST_DATA" "$BIN_PATH/NativeHostsTests" "$@"
