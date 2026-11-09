import AppKit
import SwiftUI

private func performWidgetAction(_ action: () -> Void) {
    action()
    // Accessibility presses and some mouse-driver button mappings do not emit
    // a normal NSEvent sequence. Account for the activation at the source.
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .photonicPointerActivity,
            object: NSApp.keyWindow
        )
    }
}

@MainActor
final class ControlVisibilityController: ObservableObject {
    struct WindowState {
        var frame: CGRect
        var isActive = true
        var isKey = true
        var isVisible = true
        var hasSheet = false
        var hasModal = false
    }

    // All desktop effects are injectable: regression tests use a virtual clock,
    // pointer and window, and never hide the real cursor or create an NSWindow.
    @MainActor
    struct Environment {
        var now: @MainActor () -> TimeInterval
        var pointerLocation: @MainActor () -> CGPoint
        var pressedButtons: @MainActor () -> Int
        var window: @MainActor () -> WindowState?
        var hideCursor: @MainActor () -> Void
        var unhideCursor: @MainActor () -> Void
        var schedulesTimer: Bool

        static var live: Self {
            Self(
                now: { ProcessInfo.processInfo.systemUptime },
                pointerLocation: { NSEvent.mouseLocation },
                pressedButtons: { NSEvent.pressedMouseButtons },
                window: {
                    guard let window = NSApp.windows.first(where: { $0 is ViewerOverlayWindow }) else { return nil }
                    return WindowState(
                        frame: window.frame, isActive: NSApp.isActive,
                        isKey: window.isKeyWindow, isVisible: window.isVisible,
                        hasSheet: window.attachedSheet != nil, hasModal: NSApp.modalWindow != nil
                    )
                },
                hideCursor: { NSCursor.hide() }, unhideCursor: { NSCursor.unhide() },
                schedulesTimer: true
            )
        }
    }

    @Published private(set) var isVisible = true
    private var environment: Environment
    private var timer: Timer?
    private var lastActivity: TimeInterval
    private var lastPointerLocation: CGPoint
    private var isCursorHidden = false
    private var isSuspended = false
    private(set) var isPointerInsideWindow = false
    private var isPointerOverControls = false
    private var isWaterfallSizeAdjusting = false

    init(environment: Environment = .live) {
        self.environment = environment
        lastActivity = environment.now()
        lastPointerLocation = environment.pointerLocation()
    }

    func bind(to window: NSWindow?) {
        environment.window = { [weak window] in
            guard let window else { return nil }
            return WindowState(
                frame: window.frame, isActive: NSApp.isActive,
                isKey: window.isKeyWindow, isVisible: window.isVisible,
                hasSheet: window.attachedSheet != nil, hasModal: NSApp.modalWindow != nil
            )
        }
    }

    func pointerActivity() {
        isPointerInsideWindow = true
        revealAndSchedule()
    }

    func pointerExited() {
        isPointerInsideWindow = false
        scheduleHide()
    }

    func interactionBegan() {
        lastActivity = environment.now()
    }

    func setPointerOverControls(_ hovering: Bool) {
        isPointerOverControls = hovering
        if hovering {
            isPointerInsideWindow = true
            revealAndSchedule()
        } else {
            scheduleHide()
        }
    }

    func setWaterfallSizeAdjusting(_ adjusting: Bool) {
        isWaterfallSizeAdjusting = adjusting
        if adjusting {
            lastActivity = environment.now()
        } else {
            revealAndSchedule()
        }
    }

    func revealAndSchedule() {
        revealCursor()
        if !isVisible {
            isVisible = true
        }
        scheduleHide()
    }

    func scheduleHide() {
        lastActivity = environment.now()
        guard environment.schedulesTimer, timer == nil else { return }
        lastPointerLocation = environment.pointerLocation()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkInactivity() }
        }
        self.timer = timer
        // Continue observing during AppKit tracking loops (buttons and sliders).
        RunLoop.main.add(timer, forMode: .common)
    }

    func suspend() {
        isSuspended = true
        revealAndSchedule()
    }

    func resume() {
        isSuspended = false
        revealAndSchedule()
    }

    func revealCursor() {
        guard isCursorHidden else { return }
        environment.unhideCursor()
        isCursorHidden = false
    }

    func checkInactivity() {
        let location = environment.pointerLocation()
        let moved = location != lastPointerLocation
        lastPointerLocation = location
        guard let window = environment.window() else { return }
        isPointerInsideWindow = window.frame.contains(location)
        guard !isSuspended, window.isActive, window.isKey,
              window.isVisible, !window.hasSheet, !window.hasModal else {
            revealAndSchedule()
            return
        }
        if moved || environment.pressedButtons() != 0 || isPointerOverControls || isWaterfallSizeAdjusting {
            revealAndSchedule()
            return
        }
        if !isPointerInsideWindow { revealCursor() }
        guard environment.now() - lastActivity >= 1.8 else { return }
        if isVisible { isVisible = false }
        if isPointerInsideWindow && !isCursorHidden {
            environment.hideCursor()
            isCursorHidden = true
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        revealCursor()
    }
}

struct PhotoViewer: View {
    @EnvironmentObject private var viewer: ViewerStore
    @StateObject private var controlVisibility = ControlVisibilityController()
    @State private var isWaterfallSizeAdjusting = false
    @State private var isInspectorVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var viewerHasFocus: Bool

    var body: some View {
        ZStack {
            viewerCanvas

            WindowDragHandle()
                .frame(height: 48)
                .frame(maxHeight: .infinity, alignment: .top)

            VStack(spacing: 0) {
                TopChrome(isInspectorVisible: $isInspectorVisible)
                    .onHover(perform: updateControlHover)
                Spacer()
                FloatingDock(isWaterfallSizeAdjusting: $isWaterfallSizeAdjusting)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
                    .onHover(perform: updateControlHover)
            }
            .opacity(controlVisibility.isVisible ? 1 : 0)
            .allowsHitTesting(controlVisibility.isVisible)

            if viewer.viewMode == .single && !viewer.isComparing {
                HStack {
                    NavigationButton(icon: "chevron.left", action: viewer.previous)
                        .onHover(perform: updateControlHover)
                    Spacer()
                    NavigationButton(icon: "chevron.right", action: viewer.next)
                        .onHover(perform: updateControlHover)
                }
                .padding(.horizontal, 18)
                .opacity(controlVisibility.isVisible ? 1 : 0)
                .allowsHitTesting(controlVisibility.isVisible)
            }

            // Floating widget stack, like iPadOS sidebar widgets, rather than
            // a full-height inspector column that would crop the photo.
            if viewer.viewMode == .single,
               !viewer.isComparing,
               isInspectorVisible,
               let item = viewer.currentItem {
                HStack {
                    Spacer()
                    PhotoInspectorSidebar(item: item) {
                        isInspectorVisible = false
                    }
                }
                .padding(.top, 60)
                .padding(.trailing, 14)
                .padding(.bottom, 88)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(8)
            }

            if viewer.viewMode == .single, let feedback = viewer.navigationLoopFeedback {
                NavigationLoopFeedbackView(feedback: feedback)
                    .padding(.bottom, 94)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
                    .task(id: feedback.id) {
                        try? await Task.sleep(for: .seconds(1.15))
                        guard !Task.isCancelled,
                              viewer.navigationLoopFeedback?.id == feedback.id else { return }
                        viewer.navigationLoopFeedback = nil
                    }
            }

            if viewer.viewMode == .single, let feedback = viewer.slideshowFeedback {
                SlideshowFeedbackView(feedback: feedback)
                    .padding(.bottom, 94)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(11)
                    .task(id: feedback.id) {
                        try? await Task.sleep(for: .seconds(1.35))
                        guard !Task.isCancelled,
                              viewer.slideshowFeedback?.id == feedback.id else { return }
                        viewer.slideshowFeedback = nil
                    }
            }

            if viewer.isShortcutReferenceVisible {
                ShortcutReferenceOverlay()
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: controlVisibility.isVisible)
        .animation(.easeOut(duration: 0.18), value: viewer.isShortcutReferenceVisible)
        .animation(.easeOut(duration: 0.18), value: viewer.navigationLoopFeedback?.id)
        .animation(.easeOut(duration: 0.18), value: viewer.slideshowFeedback?.id)
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: isInspectorVisible)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                controlVisibility.pointerActivity()
            case .ended:
                controlVisibility.pointerExited()
                revealCursorIfNeeded()
            }
        }
        .onAppear {
            controlVisibility.bind(to: viewer.window)
            controlVisibility.scheduleHide()
            requestViewerFocus()
        }
        .onChange(of: viewer.currentItem?.id) { _, _ in
            requestViewerFocus()
            // Image navigation (including keyboard and slideshow changes)
            // preserves visibility. Pointer activity and picker dismissal
            // independently reveal the controls when appropriate.
        }
        .onChange(of: viewer.viewMode) { _, mode in
            if mode != .single { isInspectorVisible = false }
        }
        .onChange(of: viewer.isComparing) { _, comparing in
            if comparing { isInspectorVisible = false }
        }
        .onChange(of: isWaterfallSizeAdjusting) { _, isAdjusting in
            controlVisibility.setWaterfallSizeAdjusting(isAdjusting)
        }
        .onReceive(NotificationCenter.default.publisher(for: .photonicFilePickerWillOpen)) { notification in
            guard notification.object as? NSWindow === viewer.window else { return }
            controlVisibility.suspend()
        }
        .onReceive(NotificationCenter.default.publisher(for: .photonicFilePickerDidClose)) { notification in
            guard notification.object as? NSWindow === viewer.window else { return }
            controlVisibility.resume()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            revealCursorIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .photonicPointerActivity)) { notification in
            guard notification.object as? NSWindow === viewer.window else { return }
            controlVisibility.pointerActivity()
        }
        .onReceive(NotificationCenter.default.publisher(for: .photonicPointerInteractionBegan)) { notification in
            guard notification.object as? NSWindow === viewer.window else { return }
            controlVisibility.interactionBegan()
        }
        .onDisappear {
            controlVisibility.cancel()
            revealCursorIfNeeded()
        }
        .focusable()
        .focused($viewerHasFocus)
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            if viewer.isShortcutReferenceVisible { viewer.isShortcutReferenceVisible = false }
            else if viewer.isComparing { viewer.isComparing = false }
            else { viewer.closeImage() }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            if viewer.viewMode == .waterfall { viewer.navigateWaterfall(.left) }
            else { viewer.previous() }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if viewer.viewMode == .waterfall { viewer.navigateWaterfall(.right) }
            else { viewer.next() }
            return .handled
        }
        .onKeyPress(.space) {
            viewer.toggleSlideshow()
            return .handled
        }
        .onKeyPress("h") {
            guard viewer.viewMode == .waterfall else { return .ignored }
            viewer.navigateWaterfall(.left)
            return .handled
        }
        .onKeyPress("j") {
            if viewer.viewMode == .waterfall { viewer.navigateWaterfall(.down) }
            else { viewer.previous() }
            return .handled
        }
        .onKeyPress("k") {
            if viewer.viewMode == .waterfall { viewer.navigateWaterfall(.up) }
            else { viewer.next() }
            return .handled
        }
        .onKeyPress("l") {
            guard viewer.viewMode == .waterfall else { return .ignored }
            viewer.navigateWaterfall(.right)
            return .handled
        }
        .onKeyPress("?") {
            viewer.toggleShortcutReference()
            return .handled
        }
    }

    private func updateControlHover(_ hovering: Bool) {
        controlVisibility.setPointerOverControls(hovering)
    }

    private func revealCursorIfNeeded() {
        controlVisibility.revealCursor()
    }

    private func requestViewerFocus() {
        Task { @MainActor in viewerHasFocus = true }
    }

    @ViewBuilder
    private var viewerCanvas: some View {
        if viewer.viewMode == .waterfall {
            WaterfallView(isSizeAdjustmentActive: isWaterfallSizeAdjusting)
        } else if let item = viewer.currentItem {
            if viewer.isComparing, let comparison = viewer.comparisonItem {
                HStack(spacing: 1) {
                    if viewer.isComparisonSwapped {
                        comparisonPane(item: comparison, side: .secondary, rotationDegrees: 0)
                        comparisonPane(
                            item: item,
                            side: .primary,
                            rotationDegrees: Double(viewer.rotationQuarterTurns * 90)
                        )
                    } else {
                        comparisonPane(
                            item: item,
                            side: .primary,
                            rotationDegrees: Double(viewer.rotationQuarterTurns * 90)
                        )
                        comparisonPane(item: comparison, side: .secondary, rotationDegrees: 0)
                    }
                }
                // Both images share the continuous media plane.
            } else {
                ImageCanvas(
                    item: item,
                    rotationDegrees: Double(viewer.rotationQuarterTurns * 90),
                    zoomCommand: viewer.zoomCommand,
                    onSingleClick: { isInspectorVisible.toggle() }
                )
            }
        }
    }

    private func comparisonPane(
        item: ViewerItem,
        side: ComparisonSide,
        rotationDegrees: Double
    ) -> some View {
        ImageCanvas(
            item: item,
            rotationDegrees: rotationDegrees,
            zoomCommand: viewer.zoomCommand,
            onSingleClick: {
                viewer.presentOpenPanel(selectingComparison: true, comparisonSide: side)
            }
        )
        .overlay(alignment: .topLeading) {
            ComparisonLabel(side.rawValue, name: item.fileName) {
                viewer.presentOpenPanel(selectingComparison: true, comparisonSide: side)
            }
        }
    }
}

private struct NavigationLoopFeedbackView: View {
    let feedback: NavigationLoopFeedback

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: feedback.destination == .first ? "arrow.right.to.line" : "arrow.left.to.line")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PhotonicTheme.accent)
            Text(feedback.destination == .first ? "First Image" : "Last Image")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .photonicGlass(in: Capsule())
        .allowsHitTesting(false)
        .accessibilityLabel(
            feedback.destination == .first ? "First Image" : "Last Image"
        )
    }
}

private struct SlideshowFeedbackView: View {
    let feedback: SlideshowFeedback

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: feedback.state == .started ? "pause.fill" : "stop.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PhotonicTheme.accent)
            Text(feedback.state == .started ? "Slideshow Started" : "Slideshow Stopped")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .photonicGlass(in: Capsule())
        .allowsHitTesting(false)
    }
}

private struct ShortcutReferenceOverlay: View {
    @EnvironmentObject private var viewer: ViewerStore

    var body: some View {
        ZStack {
            Button {
                viewer.isShortcutReferenceVisible = false
            } label: {
                Color.black.opacity(0.18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keyboard Shortcuts")
                            .font(.system(size: 21, weight: .semibold))
                        Text("Navigate Photonic without leaving the image")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        viewer.isShortcutReferenceVisible = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .photonicGlassButton()
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Close keyboard shortcuts")
                }

                HStack(alignment: .top, spacing: 34) {
                    ShortcutSection(title: "Single image", rows: [
                        ("J", "Previous image"),
                        ("K", "Next image"),
                        ("←  →", "Previous / next"),
                        ("↔ Scroll", "Previous / next"),
                        ("⇧+  ⇧-", "Zoom in / out"),
                        ("0", "Reset rotation"),
                        ("Space", "Play / pause slideshow"),
                        ("Scroll", "Zoom at cursor")
                    ])

                    ShortcutSection(title: "Waterfall", rows: [
                        ("H  J  K  L", "Move left / down / up / right"),
                        ("⇧J  ⇧K", "Scroll down / up"),
                        ("Arrow keys", "Move through the grid"),
                        ("Return", "Open selected image"),
                        ("⇧+  ⇧-", "Increase / decrease image size"),
                        ("S", "Switch to single image"),
                        ("W", "Switch to Waterfall")
                    ])
                }

                Divider()

                HStack(spacing: 20) {
                    ShortcutInline(keys: "?", label: "Toggle shortcuts")
                    ShortcutInline(keys: "Esc", label: "Close")
                    ShortcutInline(keys: "F", label: "Full screen")
                }
            }
            .padding(26)
            .frame(width: 610)
            .photonicGlass(in: RoundedRectangle(cornerRadius: 20))
        }
        .ignoresSafeArea()
    }
}

private struct ShortcutSection: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(PhotonicTheme.accent.opacity(0.92))

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ShortcutKey(row.0)
                        .frame(width: 86, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShortcutInline: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 7) {
            ShortcutKey(keys)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }
}

private struct ShortcutKey: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(.separator, lineWidth: 1)
            }
    }
}

private struct TopChrome: View {
    @EnvironmentObject private var viewer: ViewerStore
    @Binding var isInspectorVisible: Bool

    var body: some View {
        // Books-style chrome: compact circles hugging the window corners and a
        // small centered title pill, all sitting in the former title bar band.
        PhotonicGlassGroup(spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                chromeButton("Close window", icon: "xmark") { viewer.window?.close() }
                chromeButton("Open image or folder", icon: "folder") { viewer.presentOpenPanel() }

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    Text(titleText)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !detailText.isEmpty {
                        Text(detailText)
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 26)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
                .photonicGlass(in: Capsule())
                .accessibilityElement(children: .combine)

                Spacer(minLength: 12)

                if viewer.viewMode == .single && !viewer.isComparing {
                    chromeButton("Photo info", icon: "info", active: isInspectorVisible) {
                        isInspectorVisible.toggle()
                    }
                }
                chromeButton("Toggle full screen (F)", icon: "arrow.up.left.and.arrow.down.right") {
                    viewer.window?.toggleFullScreen(nil)
                }
                chromeButton("Reveal in Finder", icon: "arrow.right.circle", action: viewer.revealInFinder)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func chromeButton(_ title: String, icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button { performWidgetAction(action) } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .photonicGlassButton(prominent: active)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .accessibilityLabel(title)
        .help(title)
    }

    private var titleText: String {
        if viewer.viewMode == .waterfall {
            return viewer.currentItem?.url.deletingLastPathComponent().lastPathComponent ?? "Waterfall"
        }
        return viewer.currentItem?.fileName ?? ""
    }

    private var detailText: String {
        viewer.viewMode == .waterfall ? "\(viewer.items.count) images" : viewer.positionText
    }
}

/// A floating media navigation bar: one native glass surface, standard controls inside.
private struct FloatingDock: View {
    @EnvironmentObject private var viewer: ViewerStore
    @Binding var isWaterfallSizeAdjusting: Bool

    var body: some View {
        PhotonicGlassGroup {
            ViewThatFits(in: .horizontal) {
                bar(compact: false)
                bar(compact: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo navigation")
    }

    private func bar(compact: Bool) -> some View {
        HStack(spacing: 2) {
            DockButton(icon: "photo", help: "Single image view (S)", active: viewer.viewMode == .single) {
                viewer.setViewMode(.single)
            }
            DockButton(icon: "square.grid.2x2", help: "Waterfall view (W)", active: viewer.viewMode == .waterfall) {
                viewer.setViewMode(.waterfall)
            }

            DockDivider()

            if viewer.viewMode == .waterfall {
                WaterfallSizeControl(
                    size: $viewer.waterfallImageSize,
                    isAdjusting: $isWaterfallSizeAdjusting,
                    compact: compact
                )
                .padding(.horizontal, 8)
            } else if compact {
                DockButton(icon: "chevron.left", help: "Previous image", action: viewer.previous)
                DockButton(icon: "chevron.right", help: "Next image", action: viewer.next)
                Menu {
                    photoActions
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Photo actions")
                .help("Photo actions")
            } else {
                DockButton(icon: "minus.magnifyingglass", help: "Zoom out") { viewer.requestZoom(.zoomOut) }
                DockButton(icon: "arrow.down.right.and.arrow.up.left", help: "Fit to window") { viewer.requestZoom(.fit) }
                DockButton(icon: "plus.magnifyingglass", help: "Zoom in") { viewer.requestZoom(.zoomIn) }
                DockDivider()
                // Reserve the reset slot so Rotate never jumps as the image rotates.
                DockButton(icon: "arrow.counterclockwise", help: "Reset rotation (0)", action: viewer.resetRotation)
                    .disabled(viewer.rotationQuarterTurns == 0)
                DockButton(icon: "rotate.right", help: "Rotate clockwise", action: viewer.rotateClockwise)
                DockButton(
                    icon: viewer.isSlideshowRunning ? "pause.fill" : "play.fill",
                    help: viewer.isSlideshowRunning ? "Pause slideshow" : "Start slideshow",
                    active: viewer.isSlideshowRunning,
                    action: viewer.toggleSlideshow
                )
                .disabled(viewer.items.count < 2)
                DockDivider()
                DockButton(icon: "rectangle.split.2x1", help: "Compare side by side", active: viewer.isComparing) {
                    viewer.toggleComparison()
                }
                if viewer.isComparing {
                    DockButton(icon: "arrow.left.arrow.right", help: "Swap comparison positions", action: viewer.swapComparisonSides)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .photonicGlass(in: Capsule(), interactive: true)
        .fixedSize()
    }

    @ViewBuilder private var photoActions: some View {
        Button("Zoom in", systemImage: "plus.magnifyingglass") { performWidgetAction { viewer.requestZoom(.zoomIn) } }
        Button("Zoom out", systemImage: "minus.magnifyingglass") { performWidgetAction { viewer.requestZoom(.zoomOut) } }
        Button("Fit to window", systemImage: "arrow.down.right.and.arrow.up.left") { performWidgetAction { viewer.requestZoom(.fit) } }
        Divider()
        Button("Rotate clockwise", systemImage: "rotate.right") { performWidgetAction(viewer.rotateClockwise) }
        Button("Reset rotation", systemImage: "arrow.counterclockwise") { performWidgetAction(viewer.resetRotation) }
            .disabled(viewer.rotationQuarterTurns == 0)
        Button(viewer.isSlideshowRunning ? "Pause slideshow" : "Start slideshow", systemImage: viewer.isSlideshowRunning ? "pause.fill" : "play.fill") {
            performWidgetAction(viewer.toggleSlideshow)
        }
        .disabled(viewer.items.count < 2)
        Divider()
        Toggle("Compare side by side", systemImage: "rectangle.split.2x1", isOn: Binding(
            get: { viewer.isComparing },
            set: { _ in performWidgetAction(viewer.toggleComparison) }
        ))
        if viewer.isComparing {
            Button("Swap comparison positions", systemImage: "arrow.left.arrow.right") { performWidgetAction(viewer.swapComparisonSides) }
        }
    }
}

private struct WaterfallSizeControl: View {
    @Binding var size: Double
    @Binding var isAdjusting: Bool
    var compact = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "photo")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: $size, in: 120...420) { editing in
                isAdjusting = editing
            }
            .controlSize(.regular)
            .frame(width: compact ? 90 : 150)
            .accessibilityLabel("Image size")
            .help("Image size")
            Image(systemName: "photo")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

private struct ImageCanvas: View {
    let item: ViewerItem
    let rotationDegrees: Double
    let zoomCommand: ZoomCommand?
    var onSingleClick: () -> Void = {}

    @Environment(\.displayScale) private var displayScale
    @State private var zoom = 1.0
    @State private var offset = CGSize.zero
    @State private var magnifyBase: Double?
    @State private var dragBase: CGSize?
    @State private var isZoomIndicatorVisible = false
    @State private var zoomIndicatorToken = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.clear.contentShape(Rectangle())
                if let image = ImageCache.shared.image(for: item.url) {
                    let displaySize = baseImageSize(for: image, in: proxy.size)
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: displaySize.width, height: displaySize.height)
                        .rotationEffect(.degrees(rotationDegrees))
                        .scaleEffect(zoom)
                        .offset(offset)
                        .shadow(color: .black.opacity(0.52), radius: 24, y: 10)
                        .animation(.smooth(duration: 0.28), value: rotationDegrees)
                        // A quarter-turn can make the image's unrotated frame taller
                        // than the viewport. Keep that frame from expanding the ZStack
                        // so rotation always uses the actual canvas center.
                        .frame(
                            width: proxy.size.width,
                            height: proxy.size.height,
                            alignment: .center
                        )
                } else {
                    ContentUnavailableView("Unable to display image", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }

                if isZoomIndicatorVisible,
                   let percent = zoomPercentage(in: proxy.size) {
                    ZoomPercentageIndicator(percent: percent)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .contentShape(Rectangle())
            .gesture(panGesture(in: proxy.size))
            .simultaneousGesture(magnifyGesture)
            .simultaneousGesture(
                SpatialTapGesture(count: 2)
                    .exclusively(before: SpatialTapGesture(count: 1))
                    .onEnded { value in
                        switch value {
                        case .first(let doubleTap):
                            toggleZoom(at: doubleTap.location, in: proxy.size)
                        case .second(let singleTap):
                            if isPointOverImage(singleTap.location, in: proxy.size) {
                                onSingleClick()
                            }
                        }
                    }
            )
            .onChange(of: zoomCommand) { _, command in
                guard let command else { return }
                switch command.action {
                case .zoomIn:
                    withAnimation(.snappy(duration: 0.26)) { zoom = min(zoom * 1.35, 8) }
                    showZoomIndicator()
                case .zoomOut:
                    withAnimation(.snappy(duration: 0.26)) {
                        zoom = max(zoom / 1.35, 0.35)
                        if zoom <= 1 { offset = .zero }
                    }
                    showZoomIndicator()
                case .fit:
                    withAnimation(.snappy(duration: 0.26)) {
                        // The base image size is already the opening size: fit large
                        // images to the canvas, but keep smaller images at 1:1 pixels.
                        // Returning to a zoom of 1 therefore restores that exact view.
                        zoom = 1
                        offset = .zero
                    }
                    showZoomIndicator()
                case .reset:
                    zoom = 1
                    offset = .zero
                case .continuous(let delta, let anchor):
                    let frame = proxy.frame(in: .global)
                    guard frame.contains(anchor) else { return }
                    let location = CGPoint(x: anchor.x - frame.minX, y: anchor.y - frame.minY)
                    let target = min(max(zoom * exp(delta), 0.35), 8)
                    withAnimation(.interactiveSpring(response: 0.16, dampingFraction: 0.86, blendDuration: 0.08)) {
                        applyZoom(target, anchoredAt: location, in: proxy.size)
                    }
                    showZoomIndicator()
                }
            }
            .task(id: zoomIndicatorToken) {
                guard isZoomIndicatorVisible else { return }
                try? await Task.sleep(for: .seconds(1.1))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) { isZoomIndicatorVisible = false }
            }
            .onChange(of: item.id) { resetView() }
            .onChange(of: rotationDegrees) {
                recenterAfterRotation()
            }
        }
        .clipped()
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.002)
            .onChanged { value in
                if magnifyBase == nil { magnifyBase = zoom }
                zoom = min(max((magnifyBase ?? zoom) * value.magnification, 0.35), 8)
                showZoomIndicator()
            }
            .onEnded { _ in
                magnifyBase = nil
                if zoom < 1 {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        zoom = 1
                        offset = .zero
                    }
                }
                showZoomIndicator()
            }
    }

    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let limits = panLimits(at: zoom, in: size)
                guard limits.width > 0.5 || limits.height > 0.5 else { return }
                if dragBase == nil { dragBase = offset }
                let base = dragBase ?? offset
                offset = CGSize(
                    width: rubberBanded(base.width + value.translation.width, limit: limits.width),
                    height: rubberBanded(base.height + value.translation.height, limit: limits.height)
                )
            }
            .onEnded { value in
                let limits = panLimits(at: zoom, in: size)
                guard limits.width > 0.5 || limits.height > 0.5 else {
                    dragBase = nil
                    offset = .zero
                    return
                }
                let momentum = CGSize(
                    width: (value.predictedEndTranslation.width - value.translation.width) * 0.42,
                    height: (value.predictedEndTranslation.height - value.translation.height) * 0.42
                )
                let target = CGSize(
                    width: min(max(offset.width + momentum.width, -limits.width), limits.width),
                    height: min(max(offset.height + momentum.height, -limits.height), limits.height)
                )
                dragBase = nil
                withAnimation(.interpolatingSpring(stiffness: 145, damping: 19)) { offset = target }
            }
    }

    private func toggleZoom(at location: CGPoint, in size: CGSize) {
        defer { showZoomIndicator() }
        withAnimation(.snappy(duration: 0.32)) {
            if zoom > 1.01 {
                zoom = 1
                offset = .zero
                return
            }

            applyZoom(2.2, anchoredAt: location, in: size)
        }
    }

    private func applyZoom(_ targetZoom: Double, anchoredAt location: CGPoint, in size: CGSize) {
        guard targetZoom > 1 else {
            zoom = targetZoom
            offset = .zero
            return
        }

        let scaleRatio = targetZoom / zoom
        let cursorFromCenter = CGPoint(
            x: location.x - size.width / 2,
            y: location.y - size.height / 2
        )
        let proposedOffset = CGSize(
            width: cursorFromCenter.x * (1 - scaleRatio) + offset.width * scaleRatio,
            height: cursorFromCenter.y * (1 - scaleRatio) + offset.height * scaleRatio
        )
        let limits = panLimits(at: targetZoom, in: size)

        offset = CGSize(
            width: min(max(proposedOffset.width, -limits.width), limits.width),
            height: min(max(proposedOffset.height, -limits.height), limits.height)
        )
        zoom = targetZoom
    }

    private func panLimits(at zoom: Double, in canvasSize: CGSize) -> CGSize {
        guard let image = ImageCache.shared.image(for: item.url),
              canvasSize.width > 0, canvasSize.height > 0 else { return .zero }

        var displaySize = baseImageSize(for: image, in: canvasSize)
        if isQuarterTurnRotation {
            displaySize = CGSize(width: displaySize.height, height: displaySize.width)
        }

        return CGSize(
            width: max(0, (displaySize.width * zoom - canvasSize.width) / 2),
            height: max(0, (displaySize.height * zoom - canvasSize.height) / 2)
        )
    }

    private func isPointOverImage(_ location: CGPoint, in canvasSize: CGSize) -> Bool {
        guard let image = ImageCache.shared.image(for: item.url) else { return false }
        var displaySize = baseImageSize(for: image, in: canvasSize)
        if isQuarterTurnRotation {
            displaySize = CGSize(width: displaySize.height, height: displaySize.width)
        }
        displaySize.width *= zoom
        displaySize.height *= zoom
        let center = CGPoint(
            x: canvasSize.width / 2 + offset.width,
            y: canvasSize.height / 2 + offset.height
        )
        return CGRect(
            x: center.x - displaySize.width / 2,
            y: center.y - displaySize.height / 2,
            width: displaySize.width,
            height: displaySize.height
        ).contains(location)
    }

    private func baseImageSize(for image: NSImage, in canvasSize: CGSize) -> CGSize {
        let pixelSize = imagePixelSize(image)
        guard pixelSize.width > 0, pixelSize.height > 0, displayScale > 0 else { return .zero }

        let nativeSize = CGSize(
            width: pixelSize.width / displayScale,
            height: pixelSize.height / displayScale
        )
        let orientedSize = isQuarterTurnRotation
            ? CGSize(width: nativeSize.height, height: nativeSize.width)
            : nativeSize
        let fitScale = min(
            canvasSize.width / orientedSize.width,
            canvasSize.height / orientedSize.height
        )
        let openingScale = min(1, fitScale)
        return CGSize(
            width: nativeSize.width * openingScale,
            height: nativeSize.height * openingScale
        )
    }

    private func imagePixelSize(_ image: NSImage) -> CGSize {
        guard let representation = image.representations.max(by: {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }), representation.pixelsWide > 0, representation.pixelsHigh > 0 else {
            return image.size
        }
        return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    }

    private var isQuarterTurnRotation: Bool {
        abs(Int((rotationDegrees / 90).rounded())) % 2 == 1
    }

    private func rubberBanded(_ value: CGFloat, limit: CGFloat) -> CGFloat {
        let overflow = abs(value) - limit
        guard overflow > 0 else { return value }
        let resistance: CGFloat = 60
        let resistedOverflow = resistance * (1 - 1 / (overflow / resistance + 1))
        return value.sign == .minus ? -(limit + resistedOverflow) : limit + resistedOverflow
    }

    private func resetView() {
        zoom = 1
        offset = .zero
        magnifyBase = nil
        dragBase = nil
        isZoomIndicatorVisible = false
    }

    /// Shows the transient zoom percentage and restarts its auto-hide timer.
    private func showZoomIndicator() {
        if !isZoomIndicatorVisible {
            withAnimation(.easeOut(duration: 0.15)) { isZoomIndicatorVisible = true }
        }
        zoomIndicatorToken &+= 1
    }

    /// Zoom relative to the image's native pixels, so 100% means one image
    /// pixel per screen pixel (matching the 1:1 opening size of small images).
    private func zoomPercentage(in canvasSize: CGSize) -> Int? {
        guard let image = ImageCache.shared.image(for: item.url), displayScale > 0 else { return nil }
        let pixelWidth = imagePixelSize(image).width
        guard pixelWidth > 0 else { return nil }
        let baseWidth = baseImageSize(for: image, in: canvasSize).width
        let scale = baseWidth / (pixelWidth / displayScale) * zoom
        return Int((scale * 100).rounded())
    }

    private func recenterAfterRotation() {
        offset = .zero
        magnifyBase = nil
        dragBase = nil
    }
}

private struct ZoomPercentageIndicator: View {
    let percent: Int

    var body: some View {
        Text("\(percent)%")
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(.primary)
            .contentTransition(.numericText(value: Double(percent)))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .photonicGlass(in: Capsule())
            .allowsHitTesting(false)
            .accessibilityLabel("Zoom \(percent) percent")
    }
}

private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ nsView: WindowDragView, context: Context) {}
}

private final class WindowDragView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            (window as? ViewerOverlayWindow)?.toggleDesktopZoom()
            return
        }
        window?.performDrag(with: event)
    }
}

/// A plain glyph inside the dock's single glass capsule. Only a soft hover
/// highlight and an accent tint for "on" states — no per-button chrome.
private struct DockButton: View {
    let icon: String
    let help: String
    var active = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button { performWidgetAction(action) } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(active ? AnyShapeStyle(PhotonicTheme.accent) : AnyShapeStyle(.primary))
                .frame(width: 40, height: 40)
                .background {
                    Circle()
                        .fill(.primary.opacity(active ? 0.12 : (hovering && isEnabled ? 0.08 : 0)))
                }
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.3)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(help)
        .accessibilityAddTraits(active ? .isSelected : [])
        .help(help)
    }
}

private struct DockDivider: View {
    var body: some View {
        Capsule()
            .fill(.primary.opacity(0.18))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 6)
    }
}

private struct NavigationButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button { performWidgetAction(action) } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 28, height: 36)
        }
        .photonicGlassButton()
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .accessibilityLabel(icon == "chevron.left" ? "Previous image" : "Next image")
        .help(icon == "chevron.left" ? "Previous image" : "Next image")
    }
}

private struct ComparisonLabel: View {
    let letter: String
    let name: String
    let action: () -> Void

    init(_ letter: String, name: String, action: @escaping () -> Void) {
        self.letter = letter
        self.name = name
        self.action = action
    }

    var body: some View {
        Button {
            performWidgetAction(action)
        } label: {
            HStack(spacing: 7) {
                Text(letter)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .frame(width: 20, height: 20)
                    .background(.white.opacity(0.16), in: Circle())
                Text(name).lineLimit(1)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(9)
        }
        .photonicGlassButton()
        .buttonBorderShape(.capsule)
        .photonicTooltip("Choose a new image for side \(letter)", placement: .below)
        .padding(.horizontal, 12)
        .padding(.top, 54)
    }
}
