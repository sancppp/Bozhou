#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/prepare.sh"
if [[ "${1:-}" == "--unit" ]]; then
    swift run --disable-sandbox --cache-path .runtime/cache/spm BozhouCoreTests
    exit
fi
if [[ "${1:-}" == "--shell-stability" ]]; then
    swift build --disable-sandbox --cache-path .runtime/cache/spm --product BozhouCoreTests
    BIN_PATH="$(swift build --show-bin-path)"
    MATRIX_DIR="$PROJECT_DIR/.runtime/shell-stability"
    mkdir -p "$MATRIX_DIR"
    "$BIN_PATH/BozhouCoreTests" --export-shells "$MATRIX_DIR/shells.json"
    MATRIX_ARGS=(--shells "$MATRIX_DIR/shells.json" --output "$MATRIX_DIR")
    if [[ -n "${BOZHOU_TEST_OMZ:-}" ]]; then
        MATRIX_ARGS+=(--omz "$BOZHOU_TEST_OMZ")
    fi
    "$PYTHON" Scripts/test_shell_stability.py "${MATRIX_ARGS[@]}"
    exit
fi
if [[ ! -x .runtime/venv/bin/python ]]; then
    "$PYTHON" -m venv .runtime/venv
fi
if ! .runtime/venv/bin/python -c 'import asyncssh; assert asyncssh.__version__ == "2.21.1"' 2>/dev/null; then
    .runtime/venv/bin/python -m pip install --cache-dir .runtime/cache/pip 'asyncssh==2.21.1'
fi
swift build --disable-sandbox --cache-path .runtime/cache/spm --product BozhouCoreTests
swift build --disable-sandbox --cache-path .runtime/cache/spm --product BozhouAskPass
.runtime/venv/bin/python Scripts/run_integration.py
