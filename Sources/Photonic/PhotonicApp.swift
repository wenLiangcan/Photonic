import AppKit
import MapKit
import SwiftUI

extension Notification.Name {
    static let photonicFilePickerWillOpen = Notification.Name("PhotonicFilePickerWillOpen")
    static let photonicFilePickerDidClose = Notification.Name("PhotonicFilePickerDidClose")
    static let photonicPointerActivity = Notification.Name("PhotonicPointerActivity")
    static let photonicPointerInteractionBegan = Notification.Name("PhotonicPointerInteractionBegan")
}

@MainActor
final class PhotonicAppDelegate: NSObject, NSApplicationDelegate {
    private let viewer = ViewerStore()
    private var viewerWindow: ViewerOverlayWindow?
    private var eventMonitor: Any?
    private var receivedExternalOpenRequest = false
    private var horizontalScrollAccumulator = 0.0
    private var horizontalScrollDidNavigate = false
    private var horizontalScrollResetTask: Task<Void, Never>?
    private var lastPhaseLessHorizontalNavigationTime = -Double.infinity

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        showViewerWindow()
        installInputMonitor()
        NSApp.activate(ignoringOtherApps: true)

        let commandLineURLs = commandLineOpenURLs()
        if !commandLineURLs.isEmpty {
            receivedExternalOpenRequest = true
            viewer.open(urls: commandLineURLs)
        }

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
        horizontalScrollResetTask?.cancel()
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

    @objc private func resetRotation() {
        viewer.resetRotation()
    }

    @objc private func toggleSlideshow() {
        viewer.toggleSlideshow()
    }

    @objc private func toggleWaterfallView() {
        viewer.toggleViewMode()
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

    @objc private func toggleShortcutReference() {
        viewer.toggleShortcutReference()
    }

    private func showViewerWindow() {
        if let viewerWindow {
            if viewerWindow.isVisible {
                viewerWindow.makeKeyAndOrderFront(nil)
            } else {
                viewerWindow.makeKeyAndOrderFrontOptimized()
            }
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
        window.makeKeyAndOrderFrontOptimized()
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
        imageMenu.addItem(menuItem("Reset Rotation", action: #selector(resetRotation)))
        imageMenu.addItem(menuItem("Toggle Slideshow", action: #selector(toggleSlideshow)))
        imageMenu.addItem(menuItem("Toggle Waterfall View", action: #selector(toggleWaterfallView), key: "g"))
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
            "Keyboard Shortcuts",
            action: #selector(toggleShortcutReference)
        ))
        windowMenu.addItem(.separator())
        windowMenu.addItem(menuItem(
            "Toggle Full Screen",
            action: #selector(toggleFullScreen),
            key: "f",
            modifiers: [.command, .control]
        ))
        windowItem.submenu = windowMenu

        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(menuItem(
            "Keyboard Shortcuts",
            action: #selector(toggleShortcutReference)
        ))
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)

        NSApp.mainMenu = mainMenu
        NSApp.helpMenu = helpMenu
    }

    private func installInputMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown,
            .scrollWheel,
            .mouseMoved,
            .leftMouseDown,
            .leftMouseDragged,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseDragged,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseDragged,
            .otherMouseUp
        ]) { [weak self] event in
            guard let self, let window = self.viewerWindow, event.window === window else { return event }

            return ViewerInputRouter.route(event, interactionBegan: {
                NotificationCenter.default.post(
                    name: .photonicPointerInteractionBegan,
                    object: window
                )
            }, pointerActivity: {
                NotificationCenter.default.post(name: .photonicPointerActivity, object: window)
            }, leftMouseDown: { event in
                let contentHeight = window.contentView?.bounds.height ?? window.frame.height
                let isInHeader = event.locationInWindow.y >= contentHeight - 48
                if isInHeader, event.clickCount == 2 {
                    window.toggleDesktopZoom()
                    return nil
                }
                return event
            }, scrollWheel: { event in
                guard self.viewer.viewMode == .single else { return event }

                // The app-level image zoom monitor must not steal wheel events
                // from interactive sidebar content. Metadata pages consume the
                // event here; MapKit receives its events normally.
                if let pageWheelView = self.metadataPageWheelView(at: event, in: window) {
                    pageWheelView.handleWheelEvent(event)
                    return nil
                }
                if self.isMapEvent(event, in: window) { return event }
                if let scrollView = self.scrollView(at: event, in: window) {
                    scrollView.scrollWheel(with: event)
                    return nil
                }

                if self.handleHorizontalImageNavigation(event) { return nil }

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
            }, keyDown: { event in
                let shortcutModifiers = event.modifierFlags.intersection([.command, .control, .option])
                let isQuestionMark = event.characters == "?" || (
                    event.charactersIgnoringModifiers == "/" && event.modifierFlags.contains(.shift)
                )
                if shortcutModifiers.isEmpty, isQuestionMark {
                    self.viewer.toggleShortcutReference()
                    return nil
                }

                if self.viewer.isShortcutReferenceVisible {
                    if event.keyCode == 53 { // Escape
                        self.viewer.isShortcutReferenceVisible = false
                        return nil
                    }
                    let systemModifiers = event.modifierFlags.intersection([.command, .control, .option])
                    return systemModifiers.isEmpty ? nil : event
                }

                // Arrow keys are tagged by AppKit with .function/.numericPad even
                // when the user holds no modifiers. Only treat intentional shortcut
                // modifiers as modifiers here.
                let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                let systemModifiers = event.modifierFlags.intersection([.command, .control, .option])
                if systemModifiers.isEmpty,
                   event.modifierFlags.contains(.shift),
                   self.viewer.currentItem != nil {
                    let character = event.characters
                    let characterIgnoringModifiers = event.charactersIgnoringModifiers
                    let isPlusKey = event.keyCode == 24 || event.keyCode == 69
                        || character == "+" || characterIgnoringModifiers == "="
                    let isMinusKey = event.keyCode == 27 || event.keyCode == 78
                        || character == "_" || characterIgnoringModifiers == "-"
                    if isPlusKey {
                        self.viewer.increaseImageSize()
                        return nil
                    }
                    if isMinusKey {
                        self.viewer.decreaseImageSize()
                        return nil
                    }
                }
                if modifiers.isEmpty,
                   self.viewer.currentItem != nil,
                   event.charactersIgnoringModifiers == "0" {
                    self.viewer.resetRotation()
                    return nil
                }

                if modifiers == .shift, self.viewer.viewMode == .waterfall {
                    switch event.charactersIgnoringModifiers?.lowercased() {
                    case "j":
                        self.scrollWaterfall(in: window, direction: 1)
                        return nil
                    case "k":
                        self.scrollWaterfall(in: window, direction: -1)
                        return nil
                    default:
                        break
                    }
                }

                if modifiers.isEmpty {
                    switch event.charactersIgnoringModifiers?.lowercased() {
                    case "h" where self.viewer.viewMode == .waterfall:
                        self.viewer.navigateWaterfall(.left)
                        return nil
                    case "j":
                        if self.viewer.viewMode == .waterfall { self.viewer.navigateWaterfall(.down) }
                        else { self.viewer.previous() }
                        return nil
                    case "k":
                        if self.viewer.viewMode == .waterfall { self.viewer.navigateWaterfall(.up) }
                        else { self.viewer.next() }
                        return nil
                    case "l" where self.viewer.viewMode == .waterfall:
                        self.viewer.navigateWaterfall(.right)
                        return nil
                    case "f":
                        self.toggleFullScreen()
                        return nil
                    case "s" where self.viewer.currentItem != nil:
                        self.viewer.setViewMode(.single)
                        return nil
                    case "w" where self.viewer.currentItem != nil:
                        self.viewer.setViewMode(.waterfall)
                        return nil
                    default:
                        break
                    }

                    switch event.keyCode {
                    case 53 where self.viewer.currentItem == nil: // Escape
                        window.close()
                        return nil
                    case 123: // Left arrow
                        if self.viewer.viewMode == .waterfall { self.viewer.navigateWaterfall(.left) }
                        else { self.viewer.previous() }
                        return nil
                    case 124: // Right arrow
                        if self.viewer.viewMode == .waterfall { self.viewer.navigateWaterfall(.right) }
                        else { self.viewer.next() }
                        return nil
                    case 126 where self.viewer.viewMode == .waterfall: // Up arrow
                        self.viewer.navigateWaterfall(.up)
                        return nil
                    case 116 where self.viewer.viewMode == .waterfall: // Page Up
                        self.viewer.navigateWaterfall(.up)
                        return nil
                    case 125 where self.viewer.viewMode == .waterfall: // Down arrow
                        self.viewer.navigateWaterfall(.down)
                        return nil
                    case 121 where self.viewer.viewMode == .waterfall: // Page Down
                        self.viewer.navigateWaterfall(.down)
                        return nil
                    case 116: // Page Up
                        self.viewer.previous()
                        return nil
                    case 121: // Page Down
                        self.viewer.next()
                        return nil
                    case 36 where self.viewer.viewMode == .waterfall: // Return
                        self.viewer.openWaterfallSelection()
                        return nil
                    case 76 where self.viewer.viewMode == .waterfall: // Keypad Enter
                        self.viewer.openWaterfallSelection()
                        return nil
                    case 49: // Space
                        self.viewer.toggleSlideshow()
                        return nil
                    default:
                        break
                    }
                }
                return event
            })
        }
    }

    private func isMapEvent(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let contentView = window.contentView else { return false }
        let location = contentView.convert(event.locationInWindow, from: nil)
        var hitView = contentView.hitTest(location)

        while let view = hitView {
            if view is MKMapView { return true }
            hitView = view.superview
        }
        return false
    }

    private func scrollView(at event: NSEvent, in window: NSWindow) -> NSScrollView? {
        guard let contentView = window.contentView else { return nil }
        let location = contentView.convert(event.locationInWindow, from: nil)
        return scrollView(at: location, inside: contentView)
    }

    private func metadataPageWheelView(at event: NSEvent, in window: NSWindow) -> MetadataPageWheelView? {
        guard let contentView = window.contentView else { return nil }
        let location = contentView.convert(event.locationInWindow, from: nil)
        return metadataPageWheelView(at: location, inside: contentView)
    }

    private func metadataPageWheelView(at point: NSPoint, inside parent: NSView) -> MetadataPageWheelView? {
        for subview in parent.subviews.reversed() where !subview.isHidden && subview.alphaValue > 0 {
            let localPoint = subview.convert(point, from: parent)
            guard subview.bounds.contains(localPoint) else { continue }
            if let pageWheelView = subview as? MetadataPageWheelView { return pageWheelView }
            if let nested = metadataPageWheelView(at: localPoint, inside: subview) { return nested }
        }
        return nil
    }

    private func scrollView(at point: NSPoint, inside parent: NSView) -> NSScrollView? {
        for subview in parent.subviews.reversed() where !subview.isHidden && subview.alphaValue > 0 {
            let localPoint = subview.convert(point, from: parent)
            guard subview.bounds.contains(localPoint) else { continue }
            if let scrollView = subview as? NSScrollView { return scrollView }
            if let nested = scrollView(at: localPoint, inside: subview) { return nested }
        }
        return nil
    }

    private func handleHorizontalImageNavigation(_ event: NSEvent) -> Bool {
        let rawX = Double(event.scrollingDeltaX)
        let rawY = Double(event.scrollingDeltaY)
        let isHorizontal = abs(rawX) > max(abs(rawY) * 1.15, 0.01)

        if event.phase.contains(.began) {
            horizontalScrollAccumulator = 0
            horizontalScrollDidNavigate = false
        }

        guard isHorizontal else {
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                resetHorizontalScrollState()
            }
            return false
        }

        // Momentum belongs to the gesture that already changed the image. It
        // should never cascade through several photos after the fingers lift.
        if !event.momentumPhase.isEmpty {
            scheduleHorizontalScrollReset()
            return true
        }

        let directionAdjustedX = event.isDirectionInvertedFromDevice ? -rawX : rawX

        // Horizontal mouse wheels such as the Logitech MX Master thumb wheel
        // report precise deltas without trackpad gesture phases. Treat those as
        // repeatable wheel input with a deliberately slow cadence. Logitech's
        // driver can keep emitting phase-less events while the wheel is at rest,
        // so an idle/burst lock can permanently suppress later navigation.
        if event.phase.isEmpty {
            horizontalScrollAccumulator += directionAdjustedX
            let threshold = event.hasPreciseScrollingDeltas ? 1.0 : 0.01
            let cooldownHasElapsed = event.timestamp - lastPhaseLessHorizontalNavigationTime >= 0.45
            if abs(horizontalScrollAccumulator) >= threshold, cooldownHasElapsed {
                navigateFromHorizontalScroll(horizontalScrollAccumulator)
                horizontalScrollAccumulator = 0
                lastPhaseLessHorizontalNavigationTime = event.timestamp
            }
            return true
        }

        scheduleHorizontalScrollReset()

        if event.hasPreciseScrollingDeltas {
            horizontalScrollAccumulator += directionAdjustedX
            if !horizontalScrollDidNavigate, abs(horizontalScrollAccumulator) >= 48 {
                navigateFromHorizontalScroll(horizontalScrollAccumulator)
                horizontalScrollDidNavigate = true
            }
        } else if abs(directionAdjustedX) > 0.01 {
            navigateFromHorizontalScroll(directionAdjustedX)
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            resetHorizontalScrollState()
        }
        return true
    }

    private func scheduleHorizontalScrollReset(after delay: Duration = .milliseconds(180)) {
        horizontalScrollResetTask?.cancel()
        horizontalScrollResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.resetHorizontalScrollState()
        }
    }

    private func resetHorizontalScrollState() {
        horizontalScrollResetTask?.cancel()
        horizontalScrollResetTask = nil
        horizontalScrollAccumulator = 0
        horizontalScrollDidNavigate = false
    }

    private func navigateFromHorizontalScroll(_ delta: Double) {
        if delta > 0 {
            viewer.next()
        } else {
            viewer.previous()
        }
    }

    private func scrollWaterfall(in window: NSWindow, direction: CGFloat) {
        guard let contentView = window.contentView,
              let scrollView = firstScrollView(in: contentView),
              let documentView = scrollView.documentView else { return }

        let clipView = scrollView.contentView
        let pageDistance = max(clipView.bounds.height * 0.82, 120)
        let maximumY = max(documentView.bounds.height - clipView.bounds.height, 0)
        let targetY = min(max(clipView.bounds.origin.y + pageDistance * direction, 0), maximumY)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) { return scrollView }
        }
        return nil
    }

    private func commandLineOpenURLs() -> [URL] {
        var parsesOptions = true
        var urls: [URL] = []

        for argument in CommandLine.arguments.dropFirst() {
            if parsesOptions, argument == "--" {
                parsesOptions = false
                continue
            }
            if parsesOptions, argument.hasPrefix("-") { continue }

            let url: URL
            if let fileURL = URL(string: argument), fileURL.isFileURL {
                url = fileURL
            } else {
                let path = (argument as NSString).expandingTildeInPath
                if path.hasPrefix("/") {
                    url = URL(fileURLWithPath: path)
                } else {
                    url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .appendingPathComponent(path)
                }
            }

            let standardizedURL = url.standardizedFileURL
            if FileManager.default.fileExists(atPath: standardizedURL.path) {
                urls.append(standardizedURL)
            }
        }
        return urls
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
    private var backgroundEffectResumeTask: Task<Void, Never>?
    private static let resizeFallbackColor = NSColor(
        calibratedRed: 0.105,
        green: 0.11,
        blue: 0.125,
        alpha: 1
    )

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

    func toggleDesktopZoom() {
        setResizePerformanceMode(true)
        displayIfNeeded()

        // Give WindowServer one turn to replace the behind-window material
        // before native zoom starts. On macOS 15, changing the effect and
        // resizing in the same transaction can keep the expensive blur path
        // alive for every animation frame.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.performZoom(nil)
            self.scheduleBackgroundEffectRestore()
        }
    }

    func makeKeyAndOrderFrontOptimized() {
        setResizePerformanceMode(true)
        displayIfNeeded()
        makeKeyAndOrderFront(nil)
        scheduleBackgroundEffectRestore()
    }

    func setResizePerformanceMode(_ enabled: Bool) {
        if enabled {
            backgroundEffectResumeTask?.cancel()
            backgroundEffectResumeTask = nil
        }
        (contentView as? OverlayRootView)?.setBackgroundEffectActive(!enabled)
        isOpaque = enabled
        backgroundColor = enabled ? Self.resizeFallbackColor : .clear
    }

    private func scheduleBackgroundEffectRestore() {
        backgroundEffectResumeTask?.cancel()
        backgroundEffectResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            self?.setResizePerformanceMode(false)
        }
    }
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

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        (window as? ViewerOverlayWindow)?.setResizePerformanceMode(true)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        (window as? ViewerOverlayWindow)?.setResizePerformanceMode(false)
    }

    func setBackgroundEffectActive(_ active: Bool) {
        if active {
            desktopBlur.isHidden = false
            desktopBlur.state = .active
            layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            desktopBlur.state = .inactive
            desktopBlur.isHidden = true
            layer?.backgroundColor = NSColor(
                calibratedRed: 0.105,
                green: 0.11,
                blue: 0.125,
                alpha: 1
            ).cgColor
        }
    }

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
