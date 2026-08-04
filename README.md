# Photonic for Mac

A lightweight, native macOS image viewer. There is no library, catalog, import, or cloud layer: open a file and view it immediately in a frameless desktop lightbox.

## Download

Download the latest macOS disk image from the [Photonic website](https://wenliangcan.github.io/Photonic/) or [GitHub Releases](https://github.com/wenLiangcan/Photonic/releases/latest).

## First launch

After dragging Photonic into the Applications folder, macOS quarantine must be removed before the app can start. If you downloaded Photonic from the official links above, open Terminal and run:

```bash
xattr -dr com.apple.quarantine /Applications/Photonic.app
```

Run this command only for the official Photonic download. It removes macOS's quarantine attribute from that copy of the app.

## Run

```bash
swift run Photonic
```

Or build a double-clickable macOS application:

```bash
chmod +x scripts/package-app.sh
scripts/package-app.sh release
open ".build/Photonic.app"
```

## Features

- File picker appears immediately at launch
- Open either an image or a folder of images
- Opens maximized to the screen's usable area
- Frameless, translucent desktop lightbox backed by a native AppKit `NSWindow`
- Real behind-window blur via a partially transparent `NSVisualEffectView`
- Smooth pinch zoom, double-click zoom, and momentum panning
- Accelerated mouse-wheel and trackpad scrolling to zoom
- Previous/next navigation through sibling images
- Arrow-key and Page Up/Page Down image switching
- Native fullscreen from the title control, `F`, or Control-Command-F
- Rotation and automatic slideshow
- Side-by-side comparison with another image
- Finder reveal and native image-file opening

Supported formats include JPEG, PNG, HEIC/HEIF/HIF, GIF, TIFF, BMP, and WebP when supported by the installed macOS version.

## Release

`VERSION` is the single source of truth for the marketing version. The packaging script writes it into the app bundle, and the release workflow refuses to publish a tag that does not match it.

To publish a release:

1. Update `VERSION` and commit the change.
2. Create a matching tag such as `v0.1.0`.
3. Push the commit and tag to GitHub.

The release workflow builds a universal Apple silicon/Intel app, packages `Photonic-<version>.dmg`, verifies its version and architectures, creates a checksum, and publishes both files to GitHub Releases. Run `scripts/create-dmg.sh` to test the same packaging flow locally.

### App icon

`Resources/Photonic.icon` is the source of truth for the adaptive light, dark, and Liquid Glass icon. Xcode 26 builds compile it into the app automatically. Run `scripts/generate-legacy-icon.sh` after editing the Icon Composer document to refresh the padded light/dark `.icns` fallbacks and the website preview. CLT-only packages select the fallback matching the current system appearance.

## Window architecture

The window is intentionally not a SwiftUI `WindowGroup`. AppKit creates a frameless, non-opaque normal-level `NSWindow`, places a dark-aqua `NSVisualEffectView` behind the content at partial alpha, and hosts the SwiftUI image canvas in a separate transparent `NSHostingView`. This keeps the photo fully opaque while the surrounding chrome reveals and blurs the live desktop beneath it without forcing the viewer above other apps.

## License

Copyright © 2026 wenLiangcan.

Photonic is free software licensed under the [GNU General Public License, version 3 or later](LICENSE).
