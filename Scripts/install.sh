#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
if [[ "${1:-}" == "--no-build" ]]; then
    shift
else
    bash Scripts/build.sh release
fi
INSTALL_DIR="${1:-$HOME/Applications}"
APP_SOURCE="$PROJECT_DIR/dist/泊舟.app"
APP_TARGET="$INSTALL_DIR/泊舟.app"
codesign --verify --deep --strict "$APP_SOURCE"
if pgrep -x Bozhou >/dev/null; then
    printf '请先退出泊舟再安装更新。\n' >&2
    exit 1
fi
mkdir -p "$INSTALL_DIR"
if [[ -e "$APP_TARGET" ]]; then
    APP_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_TARGET/Contents/Info.plist")
    [[ "$APP_ID" == "dev.bozhou.ssh" ]] || { printf '目标位置不是泊舟应用：%s\n' "$APP_TARGET" >&2; exit 1; }
fi
STAGING=$(mktemp -d "$INSTALL_DIR/.bozhou-install.XXXXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP_SOURCE" "$STAGING/泊舟.app"
codesign --verify --deep --strict "$STAGING/泊舟.app"
source "$PROJECT_DIR/Scripts/python.sh"
"$PYTHON" Scripts/migrate_workspace.py \
    "$PROJECT_DIR/.runtime/app" "$HOME/Library/Application Support/Bozhou"
if [[ -e "$APP_TARGET" ]]; then
    BACKUP="$INSTALL_DIR/泊舟.app.backup-$(date +%Y%m%d%H%M%S)"
    mv "$APP_TARGET" "$BACKUP"
    printf '旧版本备份：%s\n' "$BACKUP"
fi
mv "$STAGING/泊舟.app" "$APP_TARGET"
printf '已安装：%s\n使用 open "%s" 启动。\n' "$APP_TARGET" "$APP_TARGET"
