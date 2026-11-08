#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/prepare.sh"
BUILD_CONFIGURATION="${1:-release}"
swift build --disable-sandbox --cache-path .runtime/cache/spm -c "$BUILD_CONFIGURATION" --product Bozhou
swift build --disable-sandbox --cache-path .runtime/cache/spm -c "$BUILD_CONFIGURATION" --product BozhouAskPass
swift build --disable-sandbox --cache-path .runtime/cache/spm -c "$BUILD_CONFIGURATION" --product BozhouUpdater
"$PYTHON" Scripts/package_app.py "$BUILD_CONFIGURATION"
APP_PATH="${BOZHOU_APP_OUTPUT:-$PROJECT_DIR/dist/泊舟.app}"
codesign --force --sign - "$APP_PATH/Contents/MacOS/BozhouAskPass"
codesign --force --sign - "$APP_PATH/Contents/MacOS/BozhouUpdater"
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
printf '\n应用已生成：%s\n' "$APP_PATH"
