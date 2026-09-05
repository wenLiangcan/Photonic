# Photonic for Mac

A lightweight, native macOS image viewer. There is no library, catalog, import, or cloud layer: open a file and view it immediately in a frameless desktop lightbox.

## Download

Download the latest macOS disk image from the [Photonic website](https://wenliangcan.github.io/Photonic/) or [GitHub Releases](https://github.com/wenLiangcan/Photonic/releases/latest).

Photonic requires an Apple silicon Mac and macOS 14 or later.

### Install with Homebrew

```bash
brew tap wenliangcan/photonic
brew install --cask photonic
```

The Cask is maintained in the [Photonic Homebrew tap](https://github.com/wenLiangcan/homebrew-photonic) and follows the latest published release.

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

## Regression tests

Run the automated interaction suite with Xcode's Swift toolchain:

```bash
bash scripts/test.sh
```

The runner uses a fresh temporary directory for build outputs and SwiftPM caches,
configuration, and security files, then removes that directory on exit. It leaves
the project's `.build`, packaged apps, installed app, and preferences alone. Tests
do not launch Photonic, open windows or file pickers, post system input events,
move the pointer, or hide the desktop cursor. Time, pointer position, window state,
and cursor effects are simulated; AppKit events are constructed only in memory.

The suite exercises the production event router and visibility controller: mouse
down/up delivery, deferred activity updates, inactivity deadlines, continuous
movement, held buttons, widget hover, slider tracking, file-picker suspension,
window deactivation, cursor restoration, and hidden controls during keyboard
navigation. These are component regression tests; visual layout and real hardware
mouse-driver behavior still need manual checking.

GitHub Actions runs the suite on pushes to `main` and pull requests. Releases also
run it before packaging, so a failing test prevents publication.

## Release

`VERSION` is the single source of truth for the marketing version. The packaging script writes it into the app bundle, and the release workflow refuses to publish a tag that does not match it.

To publish a release:

1. Update `VERSION` and commit the change.
2. Create a matching tag such as `v0.1.0`.
3. Push the commit and tag to GitHub.

The release workflow builds an ARM64 Apple silicon app, packages `Photonic-<version>.dmg`, verifies its version and architecture, creates a checksum, publishes both files to GitHub Releases, and updates the cask in the separate Homebrew tap. Run `scripts/create-dmg.sh` to test the same packaging flow locally.

Homebrew publishing requires a repository Actions secret named `HOMEBREW_TAP_TOKEN`. Use a fine-grained personal access token belonging to the release owner, restricted to the `wenLiangcan/homebrew-photonic` repository with **Contents: Read and write** permission. This is necessary because the release repository's built-in `GITHUB_TOKEN` cannot write to a different repository.

If a tap update needs to be retried independently, run the **Update Homebrew Cask** workflow manually and supply the already-published release version.

### App icon

`Resources/Photonic.icon` is the sole source of truth for the adaptive light, dark, and Liquid Glass icon. Packaging requires full Xcode 26 or newer and invokes Apple's `actool` on every build to generate both `Assets.car` and the official compatibility `.icns`; no hand-generated icon fallback is used.

## Window architecture

The window is intentionally not a SwiftUI `WindowGroup`. A transparent normal-level `NSWindow` hosts the image canvas. An attached, mouse-transparent backdrop window behind it contains the dark-aqua `NSVisualEffectView` at partial alpha. Only the backdrop casts a window shadow, keeping changing image and widget silhouettes out of macOS's foreground shadow cache.

During resizing, the content retains its layout coordinate space and scales with the window; layout settles at the final size after resizing stops. Both windows remain transparent and the backdrop material stays active throughout opening and resizing. There is no opaque resize fallback or forced window redraw. This keeps photos opaque while the surrounding chrome reveals and blurs the live desktop beneath it.

Native fullscreen detaches and hides the desktop backdrop before entering its Space, then reattaches it below the viewer after exiting. Resize scaling resets at both boundaries so widgets retain their correct click coordinates. Failed fullscreen transitions also restore the appropriate windowed/fullscreen presentation.

## License

Copyright © 2026 wenLiangcan.

Photonic is free software licensed under the [GNU General Public License, version 3 or later](LICENSE).
