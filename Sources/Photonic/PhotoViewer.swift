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
    private let environment: Environment
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
    @FocusState private var viewerHasFocus: Bool

    var body: some View {
        ZStack {
            viewerCanvas

            WindowDragHandle()
                .frame(height: 48)
                .frame(maxHeight: .infinity, alignment: .top)

            VStack(spacing: 0) {
                TopChrome()
                    .onHover(perform: updateControlHover)
                Spacer()
                FloatingDock(isWaterfallSizeAdjusting: $isWaterfallSizeAdjusting)
                    .padding(.bottom, 20)
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
                .padding(.top, 62)
                .padding(.trailing, 18)
                .padding(.bottom, 94)
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
        .animation(.easeOut(duration: 0.28), value: controlVisibility.isVisible)
        .animation(.easeOut(duration: 0.18), value: viewer.isShortcutReferenceVisible)
        .animation(.easeOut(duration: 0.18), value: viewer.navigationLoopFeedback?.id)
        .animation(.easeOut(duration: 0.18), value: viewer.slideshowFeedback?.id)
        .animation(.smooth(duration: 0.28), value: isInspectorVisible)
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
        .onReceive(NotificationCenter.default.publisher(for: .photonicFilePickerWillOpen)) { _ in
            controlVisibility.suspend()
        }
        .onReceive(NotificationCenter.default.publisher(for: .photonicFilePickerDidClose)) { _ in
            controlVisibility.resume()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            revealCursorIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .photonicPointerActivity)) { _ in
            controlVisibility.pointerActivity()
        }
        .onReceive(NotificationCenter.default.publisher(for: .photonicPointerInteractionBegan)) { _ in
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
                // Use ContentView's shared backdrop, including the side margins.
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 24)
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
                .foregroundStyle(.white.opacity(0.88))
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background {
            ZStack {
                DockBlurView()
                PhotonicTheme.chrome.opacity(0.62)
            }
            .clipShape(Capsule())
        }
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.13), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.38), radius: 14, y: 7)
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
                .foregroundStyle(.white.opacity(0.88))
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background {
            ZStack {
                DockBlurView()
                PhotonicTheme.chrome.opacity(0.62)
            }
            .clipShape(Capsule())
        }
        .overlay {
            Capsule().stroke(.white.opacity(0.13), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.38), radius: 14, y: 7)
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
                            .foregroundStyle(.white.opacity(0.52))
                    }
                    Spacer()
                    Button {
                        viewer.isShortcutReferenceVisible = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .background(.white.opacity(0.08), in: Circle())
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

                Divider().overlay(.white.opacity(0.08))

                HStack(spacing: 20) {
                    ShortcutInline(keys: "?", label: "Toggle shortcuts")
                    ShortcutInline(keys: "Esc", label: "Close")
                    ShortcutInline(keys: "F", label: "Full screen")
                }
            }
            .padding(26)
            .frame(width: 610)
            .background {
                ZStack {
                    DockBlurView()
                    PhotonicTheme.chrome.opacity(0.58)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.55), radius: 38, y: 18)
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
                        .foregroundStyle(.white.opacity(0.72))
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
                .foregroundStyle(.white.opacity(0.56))
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
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
    }
}

private struct TopChrome: View {
    @EnvironmentObject private var viewer: ViewerStore

    var body: some View {
        HStack(spacing: 12) {
            Button { performWidgetAction { NSApp.keyWindow?.close() } } label: { Image(systemName: "xmark") }
                .help("Close window")
            Button { performWidgetAction { viewer.presentOpenPanel() } } label: { Image(systemName: "folder") }
                .help("Open image")

            Spacer()

            VStack(spacing: 1) {
                Text(titleText)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(detailText)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.40))
            }
            .frame(minWidth: 180)

            Spacer()

            Button { performWidgetAction { NSApp.keyWindow?.toggleFullScreen(nil) } } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Toggle full screen (F)")
            Button { performWidgetAction(viewer.revealInFinder) } label: { Image(systemName: "arrow.right.circle") }
                .help("Reveal in Finder")
        }
        .buttonStyle(ChromeButtonStyle())
        .foregroundStyle(.white.opacity(0.84))
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.42), .black.opacity(0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
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

private struct FloatingDock: View {
    @EnvironmentObject private var viewer: ViewerStore
    @Binding var isWaterfallSizeAdjusting: Bool

    var body: some View {
        HStack(spacing: 5) {
            DockButton(
                icon: "photo",
                help: "Single image view (S)",
                active: viewer.viewMode == .single
            ) { viewer.setViewMode(.single) }
            DockButton(
                icon: "square.grid.2x2",
                help: "Waterfall view (W)",
                active: viewer.viewMode == .waterfall
            ) { viewer.setViewMode(.waterfall) }
            DockDivider()

            if viewer.viewMode == .waterfall {
                WaterfallSizeControl(
                    size: $viewer.waterfallImageSize,
                    isAdjusting: $isWaterfallSizeAdjusting
                )
            } else {
                DockButton(icon: "minus.magnifyingglass", help: "Zoom out") { viewer.requestZoom(.zoomOut) }
                DockButton(icon: "arrow.down.right.and.arrow.up.left", help: "Fit to window") { viewer.requestZoom(.fit) }
                DockButton(icon: "plus.magnifyingglass", help: "Zoom in") { viewer.requestZoom(.zoomIn) }
                DockDivider()
                DockButton(icon: "rotate.right", help: "Rotate clockwise", action: viewer.rotateClockwise)
                if viewer.rotationQuarterTurns != 0 {
                    DockButton(
                        icon: "arrow.counterclockwise",
                        help: "Reset rotation (0)",
                        active: true,
                        action: viewer.resetRotation
                    )
                    .transition(.scale.combined(with: .opacity))
                }
                DockButton(
                    icon: viewer.isSlideshowRunning ? "pause.fill" : "play.fill",
                    help: viewer.isSlideshowRunning ? "Pause slideshow" : "Start slideshow",
                    active: viewer.isSlideshowRunning,
                    action: viewer.toggleSlideshow
                )
                DockDivider()
                DockButton(icon: "rectangle.split.2x1", help: "Compare side by side", active: viewer.isComparing) {
                    viewer.toggleComparison()
                }
                if viewer.isComparing {
                    DockButton(
                        icon: "arrow.left.arrow.right",
                        help: "Swap comparison positions",
                        action: viewer.swapComparisonSides
                    )
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background {
            ZStack {
                DockBlurView()
                PhotonicTheme.chrome.opacity(0.64)
            }
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.48), radius: 20, y: 8)
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct WaterfallSizeControl: View {
    @Binding var size: Double
    @Binding var isAdjusting: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "photo")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.50))
            Slider(value: $size, in: 120...420) { editing in
                isAdjusting = editing
            }
                .controlSize(.small)
                .tint(PhotonicTheme.accent)
                .frame(width: 150)
                .help("Image size")
            Image(systemName: "photo")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(.horizontal, 5)
    }
}

private struct DockBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = true
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
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
                } else {
                    ContentUnavailableView("Unable to display image", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.white.opacity(0.65))
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
                case .zoomOut:
                    withAnimation(.snappy(duration: 0.26)) {
                        zoom = max(zoom / 1.35, 0.35)
                        if zoom <= 1 { offset = .zero }
                    }
                case .fit:
                    withAnimation(.snappy(duration: 0.26)) {
                        zoom = fitZoom(in: proxy.size)
                        offset = .zero
                    }
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
                }
            }
            .onChange(of: item.id) { resetView() }
        }
        .clipped()
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.002)
            .onChanged { value in
                if magnifyBase == nil { magnifyBase = zoom }
                zoom = min(max((magnifyBase ?? zoom) * value.magnification, 0.35), 8)
            }
            .onEnded { _ in
                magnifyBase = nil
                if zoom < 1 {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        zoom = 1
                        offset = .zero
                    }
                }
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

    private func fitZoom(in canvasSize: CGSize) -> Double {
        guard let image = ImageCache.shared.image(for: item.url) else { return 1 }
        var displaySize = baseImageSize(for: image, in: canvasSize)
        if isQuarterTurnRotation {
            displaySize = CGSize(width: displaySize.height, height: displaySize.width)
        }
        guard displaySize.width > 0, displaySize.height > 0 else { return 1 }
        return min(max(min(
            canvasSize.width / displaySize.width,
            canvasSize.height / displaySize.height
        ), 0.35), 8)
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

private struct DockButton: View {
    let icon: String
    let help: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button {
            performWidgetAction(action)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 31, height: 31)
                .background(active ? .white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? PhotonicTheme.accent : .white.opacity(0.78))
        .help(help)
    }
}

private struct DockDivider: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 24).padding(.horizontal, 4)
    }
}

private struct NavigationButton: View {
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            performWidgetAction(action)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 42, height: 60)
                .background(.black.opacity(hovering ? 0.46 : 0.22), in: RoundedRectangle(cornerRadius: 11))
                .overlay { RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(hovering ? 0.16 : 0.06)) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(hovering ? 0.96 : 0.62))
        .onHover { hovering = $0 }
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
                    .foregroundStyle(.white.opacity(0.48))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.74))
            .padding(9)
            .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Choose a new image for side \(letter)")
        .padding(12)
    }
}

private struct ChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .frame(width: 28, height: 28)
            .background(.white.opacity(configuration.isPressed ? 0.14 : 0.06), in: Circle())
    }
}
