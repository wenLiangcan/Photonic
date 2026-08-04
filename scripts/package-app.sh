#!/bin/sh
set -eu

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
APP_DIR="$PROJECT_DIR/.build/Photonic.app"
CONTENTS_DIR="$APP_DIR/Contents"
VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

if ! ACTOOL="$(xcrun --find actool 2>/dev/null)"; then
    echo "Full Xcode 26 or newer is required to compile Resources/Photonic.icon." >&2
    exit 1
fi

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

# Compile the Icon Composer document with Apple's asset compiler. actool emits
# the adaptive Assets.car and its official Photonic.icns compatibility asset.
ICON_INFO_PLIST="$PROJECT_DIR/.build/Photonic-icon-info.plist"
rm -f "$ICON_INFO_PLIST"
"$ACTOOL" "$PROJECT_DIR/Resources/Photonic.icon" \
    --compile "$CONTENTS_DIR/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon Photonic \
    --output-partial-info-plist "$ICON_INFO_PLIST"
plutil -replace CFBundleIconFile \
    -string "$(plutil -extract CFBundleIconFile raw "$ICON_INFO_PLIST")" \
    "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleIconName \
    -string "$(plutil -extract CFBundleIconName raw "$ICON_INFO_PLIST")" \
    "$CONTENTS_DIR/Info.plist"
rm -f "$ICON_INFO_PLIST"

plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"

echo "$APP_DIR"
