#!/bin/sh
set -eu

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
APP_DIR="$PROJECT_DIR/.build/Photonic.app"
CONTENTS_DIR="$APP_DIR/Contents"
VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

if ! printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "VERSION must contain a semantic version such as 0.1.0" >&2
    exit 1
fi

if ! printf '%s\n' "$BUILD_NUMBER" | grep -Eq '^[1-9][0-9]*$'; then
    echo "BUILD_NUMBER must be a positive integer" >&2
    exit 1
fi

cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/ModuleCache"
swift build --disable-sandbox -c "$CONFIGURATION" ${SWIFT_BUILD_FLAGS:-}
BIN_DIR="$(swift build --disable-sandbox -c "$CONFIGURATION" ${SWIFT_BUILD_FLAGS:-} --show-bin-path)"

# Recreate the bundle so case-only product renames cannot leave stale files on
# macOS's default case-insensitive filesystem.
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/Photonic" "$CONTENTS_DIR/MacOS/Photonic"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/Photonic.icns" "$CONTENTS_DIR/Resources/Photonic.icns"
cp "$PROJECT_DIR/Resources/PhotonicSource.icns" "$CONTENTS_DIR/Resources/Photonic26.icns"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"

echo "$APP_DIR"
