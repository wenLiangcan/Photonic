#!/bin/sh
set -eu

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE_ICON="$PROJECT_DIR/Resources/Photonic.icon"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/photonic-icon.XXXXXX")"

export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

if ICTOOL="$(xcrun --find ictool 2>/dev/null)"; then
    :
elif [ -x "/Applications/Icon Composer.app/Contents/Executables/ictool" ]; then
    ICTOOL="/Applications/Icon Composer.app/Contents/Executables/ictool"
else
    echo "Icon Composer or Xcode 26 is required to render $SOURCE_ICON" >&2
    exit 1
fi

render_icon() {
    rendition="$1"
    stem="$2"
    output_icon="$3"
    source_png="$WORK_DIR/$stem.png"
    source_iconset="$WORK_DIR/$stem-source.iconset"
    padded_iconset="$WORK_DIR/$stem-padded.iconset"

    "$ICTOOL" "$SOURCE_ICON" \
        --export-image \
        --output-file "$source_png" \
        --platform macOS \
        --rendition "$rendition" \
        --width 1024 \
        --height 1024 \
        --scale 1 \
        --design-generation 26 >/dev/null

    mkdir -p "$source_iconset"
    for specification in \
        "icon_16x16.png:16" \
        "icon_16x16@2x.png:32" \
        "icon_32x32.png:32" \
        "icon_32x32@2x.png:64" \
        "icon_128x128.png:128" \
        "icon_128x128@2x.png:256" \
        "icon_256x256.png:256" \
        "icon_256x256@2x.png:512" \
        "icon_512x512.png:512" \
        "icon_512x512@2x.png:1024"
    do
        filename="${specification%%:*}"
        size="${specification##*:}"
        sips --resampleHeightWidth "$size" "$size" \
            "$source_png" \
            --out "$source_iconset/$filename" >/dev/null
    done

    swift "$PROJECT_DIR/scripts/pad-icon.swift" \
        "$source_iconset" \
        "$padded_iconset" \
        0.8046875
    sips --resampleHeightWidth 16 16 \
        "$padded_iconset/icon_16x16@2x.png" \
        --out "$padded_iconset/icon_16x16.png" >/dev/null
    sips --resampleHeightWidth 32 32 \
        "$padded_iconset/icon_32x32@2x.png" \
        --out "$padded_iconset/icon_32x32.png" >/dev/null
    swift "$PROJECT_DIR/scripts/make-icns.swift" "$padded_iconset" "$output_icon"
}

render_icon Default Light "$PROJECT_DIR/Resources/Photonic.icns"
render_icon Dark Dark "$PROJECT_DIR/Resources/Photonic-Dark.icns"
cp "$WORK_DIR/Light.png" "$PROJECT_DIR/docs/photonic.png"

echo "$PROJECT_DIR/Resources/Photonic.icns"
echo "$PROJECT_DIR/Resources/Photonic-Dark.icns"
