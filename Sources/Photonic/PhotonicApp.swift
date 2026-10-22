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
    private var windows: [ViewerOverlayWindow] = []
    private var viewerWindow: ViewerOverlayWindow? {
        (NSApp.keyWindow as? ViewerOverlayWindow) ?? windows.last
    }
    private var viewer: ViewerStore { viewerWindow!.viewer }
    private var eventMonitor: Any?
    private var receivedExternalOpenRequest = false
    private var horizontalScrollAccumulator = 0.0
    private var horizontalScrollDidNavigate = false
    private var horizontalScrollResetTask: Task<Void, Never>?
    private var lastPhaseLessHorizontalNavigationTime = -Double.infinity
    private weak var horizontalScrollWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        if windows.isEmpty { showViewerWindow() }
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
        let window: ViewerOverlayWindow
        if !receivedExternalOpenRequestBeforeLaunch, let empty = windows.first(where: { $0.viewer.currentItem == nil }) {
            window = empty
        } else {
            window = showViewerWindow()
        }
        receivedExternalOpenRequestBeforeLaunch = true
        window.viewer.open(urls: urls)
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

    private var receivedExternalOpenRequestBeforeLaunch = false

    @discardableResult
    private func showViewerWindow() -> ViewerOverlayWindow {

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let frame = screenFrame

        let window = ViewerOverlayWindow(contentRect: frame)
        window.viewer.window = window
        let overlayRoot = OverlayRootView(frame: NSRect(origin: .zero, size: frame.size))
        let hostingView = TransparentHostingView(
            rootView: ContentView()
                .environmentObject(window.viewer)
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
        window.installBackdrop()
        window.makeKeyAndOrderFrontOptimized()
        windows.append(window)
        window.onClose = { [weak self, weak window] in
            self?.windows.removeAll { $0 === window }
        }
        return window
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
            guard let self, let window = event.window as? ViewerOverlayWindow,
                  self.windows.contains(where: { $0 === window }) else { return event }
            let viewer = window.viewer
            if self.horizontalScrollWindow !== window {
                self.resetHorizontalScrollState()
                self.lastPhaseLessHorizontalNavigationTime = -Double.infinity
                self.horizontalScrollWindow = window
            }

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
                guard viewer.viewMode == .single else { return event }

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
                viewer.requestZoom(.continuous(delta: delta, anchor: anchor))
                return nil
            }, keyDown: { event in
                let shortcutModifiers = event.modifierFlags.intersection([.command, .control, .option])
                let isQuestionMark = event.characters == "?" || (
                    event.charactersIgnoringModifiers == "/" && event.modifierFlags.contains(.shift)
                )
                if shortcutModifiers.isEmpty, isQuestionMark {
                    viewer.toggleShortcutReference()
                    return nil
                }

                if viewer.isShortcutReferenceVisible {
                    if event.keyCode == 53 { // Escape
                        viewer.isShortcutReferenceVisible = false
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
                   viewer.currentItem != nil {
                    let character = event.characters
                    let characterIgnoringModifiers = event.charactersIgnoringModifiers
                    let isPlusKey = event.keyCode == 24 || event.keyCode == 69
                        || character == "+" || characterIgnoringModifiers == "="
                    let isMinusKey = event.keyCode == 27 || event.keyCode == 78
                        || character == "_" || characterIgnoringModifiers == "-"
                    if isPlusKey {
                        viewer.increaseImageSize()
                        return nil
                    }
                    if isMinusKey {
                        viewer.decreaseImageSize()
                        return nil
                    }
                }
                if modifiers.isEmpty,
                   viewer.currentItem != nil,
                   event.charactersIgnoringModifiers == "0" {
                    viewer.resetRotation()
                    return nil
                }

                if modifiers == .shift, viewer.viewMode == .waterfall {
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
                    case "h" where viewer.viewMode == .waterfall:
                        viewer.navigateWaterfall(.left)
                        return nil
                    case "j":
                        if viewer.viewMode == .waterfall { viewer.navigateWaterfall(.down) }
                        else { viewer.previous() }
                        return nil
                    case "k":
                        if viewer.viewMode == .waterfall { viewer.navigateWaterfall(.up) }
                        else { viewer.next() }
                        return nil
                    case "l" where viewer.viewMode == .waterfall:
                        viewer.navigateWaterfall(.right)
                        return nil
                    case "f":
                        self.toggleFullScreen()
                        return nil
                    case "s" where viewer.currentItem != nil:
                        viewer.setViewMode(.single)
                        return nil
                    case "w" where viewer.currentItem != nil:
                        viewer.setViewMode(.waterfall)
                        return nil
                    default:
                        break
                    }

                    switch event.keyCode {
                    case 53 where viewer.currentItem == nil: // Escape
                        window.close()
                        return nil
                    case 123: // Left arrow
                        if viewer.viewMode == .waterfall { viewer.navigateWaterfall(.left) }
                        else { viewer.previous() }
                        return nil
                    case 124: // Right arrow
                        if viewer.viewMode == .waterfall { viewer.navigateWaterfall(.right) }
                        else { viewer.next() }
                        return nil
                    case 126 where viewer.viewMode == .waterfall: // Up arrow
                        viewer.navigateWaterfall(.up)
                        return nil
                    case 116 where viewer.viewMode == .waterfall: // Page Up
                        viewer.navigateWaterfall(.up)
                        return nil
                    case 125 where viewer.viewMode == .waterfall: // Down arrow
                        viewer.navigateWaterfall(.down)
                        return nil
                    case 121 where viewer.viewMode == .waterfall: // Page Down
                        viewer.navigateWaterfall(.down)
                        return nil
                    case 116: // Page Up
                        viewer.previous()
                        return nil
                    case 121: // Page Down
                        viewer.next()
                        return nil
                    case 36 where viewer.viewMode == .waterfall: // Return
                        viewer.openWaterfallSelection()
                        return nil
                    case 76 where viewer.viewMode == .waterfall: // Keypad Enter
                        viewer.openWaterfallSelection()
                        return nil
                    case 49: // Space
                        viewer.toggleSlideshow()
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

final class ViewerOverlayWindow: NSWindow, NSWindowDelegate {
    let viewer = ViewerStore()
    var onClose: (() -> Void)?
    private var resizeLayoutResumeTask: Task<Void, Never>?
    private var backdropWindow: ViewerBackdropWindow?
    private var backdropObservers: [NSObjectProtocol] = []
    private var isFullScreenTransitioning = false

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
        // A transparent foreground's shadow follows its photos and widgets.
        // macOS 15 can retain that silhouette after their alpha/size changes.
        // Only the stable backdrop window should cast a window shadow.
        hasShadow = false
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
        delegate = self
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func installBackdrop() {
        guard backdropWindow == nil else { return }
        let backdrop = ViewerBackdropWindow(contentRect: frame)
        backdropWindow = backdrop
        addChildWindow(backdrop, ordered: .below)
        synchronizeBackdropFrame()

        let center = NotificationCenter.default
        for name in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification
        ] {
            backdropObservers.append(center.addObserver(
                forName: name,
                object: self,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.synchronizeBackdropFrame()
                    if name == NSWindow.didResizeNotification,
                       !self.inLiveResize,
                       (self.contentView as? OverlayRootView)?.isResizeLayoutDeferred == true {
                        self.scheduleResizeLayoutRestore()
                    }
                }
            })
        }
    }

    func toggleDesktopZoom() {
        setResizePerformanceMode(true)
        performZoom(nil)
        scheduleResizeLayoutRestore()
    }

    func makeKeyAndOrderFrontOptimized() {
        // The backdrop is a separate compositor surface. Opening no longer
        // needs an opaque stand-in or a delayed material activation.
        makeKeyAndOrderFront(nil)
    }

    func setResizePerformanceMode(_ enabled: Bool) {
        resizeLayoutResumeTask?.cancel()
        resizeLayoutResumeTask = nil
        // Scale the existing content while the window animates. Neither window
        // changes opacity, material state, or background color during resize.
        let canDefer = !isFullScreenTransitioning && !styleMask.contains(.fullScreen)
        (contentView as? OverlayRootView)?.setResizeLayoutDeferred(enabled && canDefer)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        prepareFullScreenTransition()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        prepareFullScreenTransition()
    }

    private func prepareFullScreenTransition() {
        isFullScreenTransitioning = true
        setResizePerformanceMode(false)
        guard let backdropWindow else { return }
        // A separate auxiliary window can be promoted above its parent in a
        // fullscreen Space. There is no desktop to blur there: keep this
        // window detached and out of the entire native fullscreen transition.
        if backdropWindow.parent === self { removeChildWindow(backdropWindow) }
        backdropWindow.orderOut(nil)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        finishFullScreenTransition()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        finishFullScreenTransition()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        finishFullScreenTransition()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        finishFullScreenTransition()
    }

    private func finishFullScreenTransition() {
        isFullScreenTransitioning = false
        setResizePerformanceMode(false)
        guard !styleMask.contains(.fullScreen), let backdropWindow else { return }
        synchronizeBackdropFrame()
        if backdropWindow.parent !== self { addChildWindow(backdropWindow, ordered: .below) }
        if isVisible { backdropWindow.order(.below, relativeTo: windowNumber) }
    }

    override func close() {
        resizeLayoutResumeTask?.cancel()
        backdropObservers.forEach(NotificationCenter.default.removeObserver)
        backdropObservers.removeAll()
        if let backdropWindow {
            if backdropWindow.parent === self { removeChildWindow(backdropWindow) }
            backdropWindow.close()
        }
        backdropWindow = nil
        super.close()
        viewer.closeImage()
        onClose?()
    }

    private func synchronizeBackdropFrame() {
        backdropWindow?.setFrame(frame, display: false)
    }

    private func scheduleResizeLayoutRestore() {
        resizeLayoutResumeTask?.cancel()
        resizeLayoutResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            guard self?.inLiveResize == false else { return }
            self?.setResizePerformanceMode(false)
        }
    }
}

final class OverlayRootView: NSView {
    private var resizeLayout = ResizeLayoutState()
    var isResizeLayoutDeferred: Bool { resizeLayout.isDeferred }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A fixed bounds coordinate space lets AppKit/Core Animation scale
        // the existing layers without relaying every frame size to SwiftUI.
        super.setBoundsSize(resizeLayout.contentSize(for: newSize))
    }

    func setResizeLayoutDeferred(_ deferred: Bool) {
        if deferred {
            resizeLayout.begin(contentSize: bounds.size)
            super.setBoundsSize(resizeLayout.contentSize(for: frame.size))
        } else {
            guard resizeLayout.isDeferred else { return }
            resizeLayout.end()
            super.setBoundsSize(frame.size)
            needsLayout = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

final class ViewerBackdropWindow: NSWindow {
    private let effectView = NSVisualEffectView()

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenNone, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)

        effectView.frame = NSRect(origin: .zero, size: contentRect.size)
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .underWindowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isEmphasized = true
        effectView.appearance = NSAppearance(named: .darkAqua)
        effectView.alphaValue = 0.64
        contentView = effectView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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
