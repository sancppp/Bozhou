#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/prepare.sh"
swift build --disable-sandbox --cache-path .runtime/cache/spm --product Bozhou
BIN_PATH="$(swift build --show-bin-path)"
SOURCES=()
for FILE in Sources/Bozhou/*.swift; do
    [[ "$FILE" == "Sources/Bozhou/BozhouApp.swift" ]] || SOURCES+=("$FILE")
done
swiftc -target "$(uname -m)-apple-macosx14.0" "${SOURCES[@]}" Tests/NativeTitlebarProbe.swift \
    "$BIN_PATH/SwiftTerm.build/"*.o "$BIN_PATH/BozhouCore.build/"*.o \
    -I "$BIN_PATH/Modules" -I Sources/CSQLite -lsqlite3 -o "$BIN_PATH/NativeTitlebarProbe"
TEST_DATA="$(mktemp -d "$PROJECT_DIR/.runtime/tmp/titlebar-ui.XXXXXXXX")"
trap 'rm -rf "$TEST_DATA"' EXIT
# LaunchServices gives the probe a foreground application identity for real menu/focus tests.
PROBE_APP="$TEST_DATA/TitlebarProbe.app"
mkdir -p "$PROBE_APP/Contents/MacOS" "$PROBE_APP/Contents/Resources"
cp "$BIN_PATH/NativeTitlebarProbe" "$PROBE_APP/Contents/MacOS/NativeTitlebarProbe"
cp -R "$BIN_PATH/Bozhou_BozhouCore.bundle" "$PROBE_APP/Contents/Resources/"
"$PYTHON" - "$PROBE_APP" <<'PY'
import plistlib
import sys
from pathlib import Path
with (Path(sys.argv[1]) / "Contents" / "Info.plist").open("wb") as file:
    plistlib.dump({
        "CFBundleIdentifier": "dev.bozhou.titlebar-probe",
        "CFBundleName": "Bozhou UI Probe",
        "CFBundleExecutable": "NativeTitlebarProbe",
        "CFBundlePackageType": "APPL",
        "NSPrincipalClass": "NSApplication",
        "LSUIElement": False,
    }, file)
PY
codesign --force --deep --sign - "$PROBE_APP"
open -n -W --env "BOZHOU_DATA_DIR=$TEST_DATA/data" \
    --env "ZDOTDIR=$TEST_DATA" \
    --env "BOZHOU_VERIFY_UPDATE_UI=${BOZHOU_VERIFY_UPDATE_UI:-}" \
    --env "BOZHOU_PROBE_STATUS=$TEST_DATA/status" \
    --env "BOZHOU_PROBE_RENDERS=$PROJECT_DIR/.runtime/logs/ui-polish-renders" \
    --stdout "$TEST_DATA/stdout" --stderr "$TEST_DATA/stderr" "$PROBE_APP"
cat "$TEST_DATA/stdout" "$TEST_DATA/stderr"
[[ "$(cat "$TEST_DATA/status")" == "0" ]]
