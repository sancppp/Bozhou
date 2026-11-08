#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/prepare.sh"
swift build --disable-sandbox --cache-path .runtime/cache/spm --product Bozhou
source "$PROJECT_DIR/Scripts/native_test_support.sh"
swiftc "${SOURCES[@]}" Tests/NativeRegressionTests.swift \
    "${NATIVE_OBJECTS[@]}" \
    -I "$BIN_PATH/Modules" -I Sources/CSQLite -lsqlite3 -o "$BIN_PATH/NativeRegressionTests"
TEST_DATA="$(mktemp -d "$PROJECT_DIR/.runtime/tmp/regressions.XXXXXXXX")"
trap 'rm -rf "$TEST_DATA"' EXIT
BOZHOU_DATA_DIR="$TEST_DATA" "$BIN_PATH/NativeRegressionTests"
