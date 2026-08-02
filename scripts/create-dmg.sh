#!/bin/sh
set -eu

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
OUTPUT_DIR="${1:-$PROJECT_DIR/dist}"
DMG_PATH="$OUTPUT_DIR/Photonic-$VERSION.dmg"
APP_PATH="$PROJECT_DIR/.build/Photonic.app"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/photonic-dmg.XXXXXX")"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT HUP INT TERM

"$PROJECT_DIR/scripts/package-app.sh" release

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --deep --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_PATH"
else
    codesign --force --deep --sign - "$APP_PATH"
fi

mkdir -p "$OUTPUT_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/Photonic.app"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH" "$DMG_PATH.sha256"
hdiutil create \
    -quiet \
    -volname "Photonic $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

(cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256")
echo "$DMG_PATH"
