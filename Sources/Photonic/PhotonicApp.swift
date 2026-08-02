import AppKit
import SwiftUI

@MainActor
final class PhotonicAppDelegate: NSObject, NSApplicationDelegate {
    private let viewer = ViewerStore()
    private var viewerWindow: ViewerOverlayWindow?
    private var eventMonitor: Any?
    private var receivedExternalOpenRequest = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        showViewerWindow()
        installInputMonitor()
        NSApp.activate(ignoringOtherApps: true)

        // Defer the normal picker by one run-loop turn. The panel is nonmodal,
        // so a later LaunchServices document event can cancel it and open the
        // double-clicked image directly.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.receivedExternalOpenRequest,
                  self.viewer.currentItem == nil else { return }
            self.viewer.presentOpenPanel()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedExternalOpenRequest = true
        showViewerWindow()
        viewer.open(urls: urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    @objc private func openImage() {
        viewer.presentOpenPanel()
    }

    @objc private func closeImage() {
        viewer.closeImage()
    }

    @objc private func previousImage() {
        viewer.previous()
    }

    @objc private func nextImage() {
        viewer.next()
    }

    @objc private func rotateImage() {
        viewer.rotateClockwise()
    }

    @objc private func toggleSlideshow() {
        viewer.toggleSlideshow()
    }

    @objc private func compareImages() {
        viewer.toggleComparison()
    }

    @objc private func revealImage() {
        viewer.revealInFinder()
    }

    @objc private func toggleFullScreen() {
        viewerWindow?.toggleFullScreen(nil)
    }

    private func showViewerWindow() {
        if let viewerWindow {
            viewerWindow.makeKeyAndOrderFront(nil)
            return
        }

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let frame = screenFrame

        let window = ViewerOverlayWindow(contentRect: frame)
        let overlayRoot = OverlayRootView(frame: NSRect(origin: .zero, size: frame.size))
        let hostingView = TransparentHostingView(
            rootView: ContentView()
                .environmentObject(viewer)
                .frame(minWidth: 760, minHeight: 520)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        overlayRoot.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: overlayRoot.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: overlayRoot.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: overlayRoot.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: overlayRoot.bottomAnchor)
        ])

        window.contentView = overlayRoot
        window.makeKeyAndOrderFront(nil)
        viewerWindow = window
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem()
        mainMenu.addItem(applicationItem)
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "About Photonic", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit Photonic", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(menuItem("Open Image…", action: #selector(openImage), key: "o"))
        fileMenu.addItem(menuItem("Close Image", action: #selector(closeImage), key: "w"))
        fileItem.submenu = fileMenu

        let imageItem = NSMenuItem()
        mainMenu.addItem(imageItem)
        let imageMenu = NSMenu(title: "Image")
        imageMenu.addItem(menuItem("Previous Image", action: #selector(previousImage)))
        imageMenu.addItem(menuItem("Next Image", action: #selector(nextImage)))
        imageMenu.addItem(.separator())
        imageMenu.addItem(menuItem("Rotate Clockwise", action: #selector(rotateImage), key: "r"))
        imageMenu.addItem(menuItem("Toggle Slideshow", action: #selector(toggleSlideshow)))
        imageMenu.addItem(menuItem("Compare…", action: #selector(compareImages), key: "c", modifiers: [.command, .shift]))
        imageMenu.addItem(.separator())
        imageMenu.addItem(menuItem("Reveal in Finder", action: #selector(revealImage)))
        imageItem.submenu = imageMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(menuItem(
            "Toggle Full Screen",
            action: #selector(toggleFullScreen),
            key: "f",
            modifiers: [.command, .control]
        ))
        windowItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func installInputMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .leftMouseDown]) { [weak self] event in
            guard let self, let window = self.viewerWindow, event.window === window else { return event }

            if event.type == .leftMouseDown {
                let contentHeight = window.contentView?.bounds.height ?? window.frame.height
                let isInHeader = event.locationInWindow.y >= contentHeight - 48
                if isInHeader, event.clickCount == 2,
                   let screen = window.screen ?? NSScreen.main {
                    window.setFrame(screen.visibleFrame, display: true, animate: true)
                    return nil
                }
                return event
            }

            if event.type == .scrollWheel {
                let rawDelta = Double(event.scrollingDeltaY)
                guard abs(rawDelta) > 0.001 else { return event }

                // Keep high-resolution trackpad deltas fine-grained while using
                // larger steps for traditional wheel notches. macOS supplies
                // acceleration in rawDelta; exponential scaling preserves it.
                let sensitivity = event.hasPreciseScrollingDeltas ? 0.012 : 0.14
                // AppKit reports natural-scroll deltas opposite to the visual
                // zoom convention: upward motion should move into the image.
                let delta = min(max(-rawDelta * sensitivity, -0.34), 0.34)
                guard let contentView = window.contentView else { return event }
                let location = contentView.convert(event.locationInWindow, from: nil)
                let anchor = CGPoint(
                    x: location.x,
                    y: contentView.bounds.height - location.y
                )
                self.viewer.requestZoom(.continuous(delta: delta, anchor: anchor))
                return nil
            }

            // Arrow keys are tagged by AppKit with .function/.numericPad even
            // when the user holds no modifiers. Only treat intentional shortcut
            // modifiers as modifiers here.
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers.isEmpty {
                switch event.keyCode {
                case 53 where self.viewer.currentItem == nil: // Escape
                    window.close()
                    return nil
                case 123, 116: // Left arrow, Page Up
                    self.viewer.previous()
                    return nil
                case 124, 121: // Right arrow, Page Down
                    self.viewer.next()
                    return nil
                case 3: // F
                    self.toggleFullScreen()
                    return nil
                case 49: // Space
                    self.viewer.toggleSlideshow()
                    return nil
                default:
                    break
                }
            }
            return event
        }
    }

    private func menuItem(
        _ title: String,
        action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

final class ViewerOverlayWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Photonic"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        level = .normal
        minSize = NSSize(width: 760, height: 520)
        collectionBehavior = [.fullScreenPrimary, .managed]
        animationBehavior = .documentWindow
        acceptsMouseMovedEvents = true
        appearance = NSAppearance(named: .darkAqua)
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayRootView: NSView {
    private let desktopBlur = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        desktopBlur.frame = bounds
        desktopBlur.autoresizingMask = [.width, .height]
        desktopBlur.material = .underWindowBackground
        desktopBlur.blendingMode = .behindWindow
        desktopBlur.state = .active
        desktopBlur.isEmphasized = true
        desktopBlur.appearance = NSAppearance(named: .darkAqua)
        // Partial alpha intentionally preserves recognizable desktop color and
        // structure beneath the blur instead of producing an opaque material.
        desktopBlur.alphaValue = 0.64
        addSubview(desktopBlur)
    }

    override var isOpaque: Bool { false }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        enclosingScrollView?.drawsBackground = false
    }
}
