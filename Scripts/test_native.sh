#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/prepare.sh"
swift build --disable-sandbox --cache-path .runtime/cache/spm --product Bozhou
BIN_PATH="$(swift build --show-bin-path)"
swiftc Sources/Bozhou/NativeInputTerminalView.swift Tests/NativeInputTests.swift \
    "$BIN_PATH/SwiftTerm.build/"*.o -I "$BIN_PATH/Modules" -o .runtime/NativeInputTests
.runtime/NativeInputTests
