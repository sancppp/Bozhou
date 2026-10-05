#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/prepare.sh"
swift build --disable-sandbox --cache-path .runtime/cache/spm --product Bozhou
BIN_PATH="$(swift build --show-bin-path)"
SOURCES=()
for FILE in Sources/Bozhou/*.swift; do
    [[ "$FILE" == "Sources/Bozhou/BozhouApp.swift" ]] || SOURCES+=("$FILE")
done
swiftc "${SOURCES[@]}" Tests/NativeRegressionTests.swift \
    "$BIN_PATH/SwiftTerm.build/"*.o "$BIN_PATH/BozhouCore.build/"*.o \
    -I "$BIN_PATH/Modules" -I Sources/CSQLite -lsqlite3 -o "$BIN_PATH/NativeRegressionTests"
TEST_DATA="$(mktemp -d "$PROJECT_DIR/.runtime/tmp/regressions.XXXXXXXX")"
trap 'rm -rf "$TEST_DATA"' EXIT
BOZHOU_DATA_DIR="$TEST_DATA" "$BIN_PATH/NativeRegressionTests"
