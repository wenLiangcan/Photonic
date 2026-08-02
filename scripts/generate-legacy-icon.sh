#!/bin/sh
set -eu

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE_ICON="$PROJECT_DIR/Resources/PhotonicSource.icns"
OUTPUT_ICON="$PROJECT_DIR/Resources/Photonic.icns"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/photonic-icon.XXXXXX")"

export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

iconutil --convert iconset --output "$WORK_DIR/source.iconset" "$SOURCE_ICON"
swift "$PROJECT_DIR/scripts/pad-icon.swift" \
    "$WORK_DIR/source.iconset" \
    "$WORK_DIR/Photonic.iconset" \
    0.8046875
sips --resampleHeightWidth 16 16 \
    "$WORK_DIR/Photonic.iconset/icon_16x16@2x.png" \
    --out "$WORK_DIR/Photonic.iconset/icon_16x16.png" >/dev/null
sips --resampleHeightWidth 32 32 \
    "$WORK_DIR/Photonic.iconset/icon_32x32@2x.png" \
    --out "$WORK_DIR/Photonic.iconset/icon_32x32.png" >/dev/null
swift "$PROJECT_DIR/scripts/make-icns.swift" \
    "$WORK_DIR/Photonic.iconset" \
    "$OUTPUT_ICON"

echo "$OUTPUT_ICON"
