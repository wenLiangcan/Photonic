#!/bin/sh
set -eu

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
APP_DIR="$PROJECT_DIR/.build/Photonic.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/ModuleCache"
swift build --disable-sandbox -c "$CONFIGURATION"

# Recreate the bundle so case-only product renames cannot leave stale files on
# macOS's default case-insensitive filesystem.
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$PROJECT_DIR/.build/$CONFIGURATION/Photonic" "$CONTENTS_DIR/MacOS/Photonic"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/Photonic.icns" "$CONTENTS_DIR/Resources/Photonic.icns"

echo "$APP_DIR"
