#!/bin/bash
# Shared, reproducible preparation. All caches and generated sources stay in this project.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
source "$PROJECT_DIR/Scripts/python.sh"
mkdir -p .runtime/cache/clang .runtime/cache/swift .runtime/cache/spm .runtime/tmp .runtime/logs dist
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.runtime/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.runtime/cache/swift"
export TMPDIR="$PROJECT_DIR/.runtime/tmp"
git submodule update --init Vendor/SwiftTerm Vendor/bash-preexec
mkdir -p Sources/BozhouCore/Resources
cp Vendor/bash-preexec/bash-preexec.sh Sources/BozhouCore/Resources/bash-preexec.sh
# Patch only generated build sources; keep upstream submodules clean and pinned.
mkdir -p .runtime/SwiftTerm
rsync -a --delete Vendor/SwiftTerm/Sources/ .runtime/SwiftTerm/Sources/
git apply --directory=.runtime/SwiftTerm Patches/swiftterm-app-resources.patch
git apply --directory=.runtime/SwiftTerm Patches/swiftterm-pty-drain.patch
