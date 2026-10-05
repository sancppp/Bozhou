#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/prepare.sh"
if [[ "${1:-}" == "--unit" ]]; then
    swift run --disable-sandbox --cache-path .runtime/cache/spm BozhouCoreTests
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
