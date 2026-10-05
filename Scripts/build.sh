#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/prepare.sh"
BUILD_CONFIGURATION="${1:-release}"
swift build --disable-sandbox --cache-path .runtime/cache/spm -c "$BUILD_CONFIGURATION" --product Bozhou
swift build --disable-sandbox --cache-path .runtime/cache/spm -c "$BUILD_CONFIGURATION" --product BozhouAskPass
"$PYTHON" Scripts/package_app.py "$BUILD_CONFIGURATION"
codesign --force --sign - "dist/泊舟.app/Contents/MacOS/BozhouAskPass"
codesign --force --deep --sign - "dist/泊舟.app"
codesign --verify --deep --strict "dist/泊舟.app"
printf '\n应用已生成：%s/dist/泊舟.app\n' "$PROJECT_DIR"
