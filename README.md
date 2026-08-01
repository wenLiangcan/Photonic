# Picasa Viewer for Mac

A lightweight, native macOS image viewer inspired by Picasa's dedicated Photo Viewer. There is no library, catalog, import, or cloud layer: open a file and view it immediately in a frameless desktop lightbox.

## Run

```bash
swift run Picasa
```

Or build a double-clickable macOS application:

```bash
chmod +x scripts/package-app.sh
scripts/package-app.sh release
open ".build/Picasa Viewer.app"
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

Supported formats include JPEG, PNG, HEIC/HEIF, GIF, TIFF, BMP, and WebP when supported by the installed macOS version.

## Window architecture

The window is intentionally not a SwiftUI `WindowGroup`. AppKit creates a frameless, non-opaque normal-level `NSWindow`, places a dark-aqua `NSVisualEffectView` behind the content at partial alpha, and hosts the SwiftUI image canvas in a separate transparent `NSHostingView`. This keeps the photo fully opaque while the surrounding chrome reveals and blurs the live desktop beneath it without forcing the viewer above other apps.
