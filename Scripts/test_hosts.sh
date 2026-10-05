#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/prepare.sh"
swift build --disable-sandbox --cache-path .runtime/cache/spm --product Bozhou
swift build --disable-sandbox --cache-path .runtime/cache/spm --product BozhouAskPass
BIN_PATH="$(swift build --show-bin-path)"
SOURCES=()
for FILE in Sources/Bozhou/*.swift; do
    [[ "$FILE" == "Sources/Bozhou/BozhouApp.swift" ]] || SOURCES+=("$FILE")
done
swiftc "${SOURCES[@]}" Tests/NativeHostsTests.swift Tests/NativeLiveTerminalProbe.swift Tests/NativeLayoutProbe.swift \
    "$BIN_PATH/SwiftTerm.build/"*.o "$BIN_PATH/BozhouCore.build/"*.o \
    -I "$BIN_PATH/Modules" -I Sources/CSQLite -lsqlite3 -o "$BIN_PATH/NativeHostsTests"
TEST_DATA="$(mktemp -d "$PROJECT_DIR/.runtime/tmp/hosts-ui.XXXXXXXX")"
trap 'rm -rf "$TEST_DATA"' EXIT
BOZHOU_DATA_DIR="$TEST_DATA" "$BIN_PATH/NativeHostsTests" "$@"
