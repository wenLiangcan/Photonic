import AppKit
import Foundation
import UniformTypeIdentifiers

struct ViewerItem: Identifiable, Hashable, Sendable {
    let url: URL

    var id: String { url.standardizedFileURL.path }
    var fileName: String { url.lastPathComponent }
}

enum ComparisonSide: String, Sendable {
    case primary = "A"
    case secondary = "B"
}

enum ViewerMode: String, Sendable {
    case single
    case waterfall
}

enum WaterfallNavigationDirection: Equatable, Sendable {
    case left
    case down
    case up
    case right
}

struct WaterfallNavigationCommand: Equatable, Sendable {
    let id = UUID()
    let direction: WaterfallNavigationDirection

    static func == (lhs: WaterfallNavigationCommand, rhs: WaterfallNavigationCommand) -> Bool {
        lhs.id == rhs.id
    }
}

struct NavigationLoopFeedback: Equatable, Identifiable, Sendable {
    enum Destination: Equatable, Sendable {
        case first
        case last
    }

    let id = UUID()
    let destination: Destination
}

struct SlideshowFeedback: Equatable, Identifiable, Sendable {
    enum State: Equatable, Sendable {
        case started
        case stopped
    }

    let id = UUID()
    let state: State
}

enum ZoomAction: Sendable {
    case zoomIn
    case zoomOut
    case fit
    case reset
    case continuous(delta: Double, anchor: CGPoint)
}

struct ZoomCommand: Equatable, Sendable {
    let id = UUID()
    let action: ZoomAction

    static func == (lhs: ZoomCommand, rhs: ZoomCommand) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class ViewerStore: ObservableObject {
    @Published private(set) var items: [ViewerItem] = []
    @Published var currentIndex = 0
    @Published var comparisonItem: ViewerItem?
    @Published var isComparing = false
    @Published var isSlideshowRunning = false
    @Published var rotationQuarterTurns = 0
    @Published var zoomCommand: ZoomCommand?
    @Published var viewMode: ViewerMode = .single
    @Published var waterfallImageSize = 220.0
    @Published var waterfallNavigationCommand: WaterfallNavigationCommand?
    @Published var isShortcutReferenceVisible = false
    @Published var navigationLoopFeedback: NavigationLoopFeedback?
    @Published var slideshowFeedback: SlideshowFeedback?

    private var slideshowTask: Task<Void, Never>?
    private var openPanel: NSOpenPanel?
    private let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "hif", "gif", "tif", "tiff", "bmp", "webp"
    ]

    deinit {
        slideshowTask?.cancel()
    }

    var currentItem: ViewerItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    var positionText: String {
        guard !items.isEmpty else { return "" }
        return "\(currentIndex + 1) of \(items.count)"
    }

    func presentOpenPanel(
        selectingComparison: Bool = false,
        comparisonSide: ComparisonSide = .secondary
    ) {
        if let openPanel {
            openPanel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSOpenPanel()
        panel.title = selectingComparison
            ? "Choose an image for side \(comparisonSide.rawValue)"
            : "Open an image or folder"
        panel.prompt = selectingComparison ? "Choose" : "Open"
        var allowedContentTypes: [UTType] = [.image]
        if let hifType = UTType(filenameExtension: "hif") {
            allowedContentTypes.append(hifType)
        }
        if !selectingComparison {
            allowedContentTypes.append(.folder)
        }
        panel.allowedContentTypes = allowedContentTypes
        panel.canChooseFiles = true
        panel.canChooseDirectories = !selectingComparison
        panel.allowsMultipleSelection = !selectingComparison
        panel.resolvesAliases = true
        if selectingComparison {
            let referenceItem = comparisonSide == .primary ? currentItem : comparisonItem ?? currentItem
            panel.directoryURL = referenceItem?.url.deletingLastPathComponent()
        }

        openPanel = panel
        panel.begin { [weak self, weak panel] response in
            guard let self else { return }
            defer {
                if self.openPanel === panel { self.openPanel = nil }
            }
            guard response == .OK, let panel else { return }

            if selectingComparison, let url = panel.url {
                let selected = url.standardizedFileURL
                if comparisonSide == .primary {
                    self.replacePrimaryComparisonItem(with: selected)
                } else {
                    self.comparisonItem = ViewerItem(url: selected)
                }
                self.isComparing = true
                self.stopSlideshow()
                self.focusViewerWindow()
            } else {
                self.open(urls: panel.urls)
            }
        }
    }

    func open(urls: [URL]) {
        dismissOpenPanel()
        let inputs = urls.map(\.standardizedFileURL)
        let selectedFile = inputs.first { !isDirectory($0) && isSupportedImage($0) }
        let containsFolder = inputs.contains(where: isDirectory)
        let expanded = inputs.flatMap { url -> [URL] in
            if isDirectory(url) { return images(in: url) }
            return isSupportedImage(url) ? [url] : []
        }
        let valid = uniqueSorted(expanded)
        guard let selected = selectedFile ?? valid.first else { return }

        if containsFolder || valid.count > 1 {
            items = uniqueSorted(valid).map(ViewerItem.init)
        } else {
            items = siblingImages(around: selected).map(ViewerItem.init)
        }
        currentIndex = items.firstIndex { $0.url == selected } ?? 0
        comparisonItem = nil
        isComparing = false
        isShortcutReferenceVisible = false
        navigationLoopFeedback = nil
        slideshowFeedback = nil
        resetViewState()
        focusViewerWindow()
    }

    func open(url: URL) {
        open(urls: [url])
    }

    func closeImage() {
        stopSlideshow()
        items = []
        currentIndex = 0
        comparisonItem = nil
        isComparing = false
        viewMode = .single
        isShortcutReferenceVisible = false
        navigationLoopFeedback = nil
        slideshowFeedback = nil
    }

    func next() {
        guard !items.isEmpty else { return }
        let wrapsToFirst = viewMode == .single && items.count > 1 && currentIndex == items.count - 1
        currentIndex = (currentIndex + 1) % items.count
        navigationLoopFeedback = wrapsToFirst
            ? NavigationLoopFeedback(destination: .first)
            : nil
        resetViewState()
    }

    func previous() {
        guard !items.isEmpty else { return }
        let wrapsToLast = viewMode == .single && items.count > 1 && currentIndex == 0
        currentIndex = (currentIndex - 1 + items.count) % items.count
        navigationLoopFeedback = wrapsToLast
            ? NavigationLoopFeedback(destination: .last)
            : nil
        resetViewState()
    }

    func rotateClockwise() {
        rotationQuarterTurns = (rotationQuarterTurns + 1) % 4
    }

    func resetRotation() {
        rotationQuarterTurns = 0
    }

    func increaseImageSize() {
        if viewMode == .waterfall {
            waterfallImageSize = min(waterfallImageSize + 24, 420)
        } else {
            requestZoom(.zoomIn)
        }
    }

    func decreaseImageSize() {
        if viewMode == .waterfall {
            waterfallImageSize = max(waterfallImageSize - 24, 120)
        } else {
            requestZoom(.zoomOut)
        }
    }

    func setViewMode(_ mode: ViewerMode) {
        guard viewMode != mode else { return }
        viewMode = mode
        navigationLoopFeedback = nil
        slideshowFeedback = nil
        if mode == .waterfall {
            stopSlideshow()
            isComparing = false
        } else {
            resetViewState()
        }
    }

    func toggleViewMode() {
        setViewMode(viewMode == .single ? .waterfall : .single)
    }

    func showInSingleView(_ item: ViewerItem) {
        guard let index = items.firstIndex(of: item) else { return }
        currentIndex = index
        viewMode = .single
        resetViewState()
    }

    func selectInWaterfall(_ item: ViewerItem) {
        guard viewMode == .waterfall, let index = items.firstIndex(of: item) else { return }
        currentIndex = index
    }

    func navigateWaterfall(_ direction: WaterfallNavigationDirection) {
        guard viewMode == .waterfall, currentItem != nil else { return }
        waterfallNavigationCommand = WaterfallNavigationCommand(direction: direction)
    }

    func openWaterfallSelection() {
        guard let currentItem else { return }
        showInSingleView(currentItem)
    }

    func toggleShortcutReference() {
        guard currentItem != nil else { return }
        isShortcutReferenceVisible.toggle()
    }

    func toggleSlideshow() {
        if isSlideshowRunning {
            stopSlideshow()
            slideshowFeedback = SlideshowFeedback(state: .stopped)
        } else {
            startSlideshow()
            if isSlideshowRunning {
                slideshowFeedback = SlideshowFeedback(state: .started)
            }
        }
    }

    func startSlideshow() {
        guard viewMode == .single, items.count > 1 else { return }
        isSlideshowRunning = true
        isComparing = false
        slideshowTask?.cancel()
        slideshowTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3.5))
                guard !Task.isCancelled, let self, self.isSlideshowRunning else { return }
                self.next()
            }
        }
    }

    func stopSlideshow() {
        isSlideshowRunning = false
        slideshowTask?.cancel()
        slideshowTask = nil
    }

    func toggleComparison() {
        if viewMode == .waterfall {
            setViewMode(.single)
        }
        if isComparing {
            isComparing = false
        } else if comparisonItem != nil {
            isComparing = true
            stopSlideshow()
        } else {
            presentOpenPanel(selectingComparison: true)
        }
    }

    func requestZoom(_ action: ZoomAction) {
        zoomCommand = ZoomCommand(action: action)
    }

    func revealInFinder() {
        guard let currentItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([currentItem.url])
    }

    private func resetViewState() {
        rotationQuarterTurns = 0
        zoomCommand = ZoomCommand(action: .reset)
    }

    private func replacePrimaryComparisonItem(with selected: URL) {
        let availableItems = siblingImages(around: selected).map(ViewerItem.init)
        items = availableItems
        currentIndex = availableItems.firstIndex { $0.url == selected } ?? 0
        resetViewState()
    }

    private func dismissOpenPanel() {
        openPanel?.cancel(nil)
        openPanel = nil
    }

    private func focusViewerWindow() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows
                .first { $0 is ViewerOverlayWindow }?
                .makeKeyAndOrderFront(nil)
        }
    }

    private func siblingImages(around selected: URL) -> [URL] {
        let directory = selected.deletingLastPathComponent()
        let siblings = images(in: directory)
        return siblings.isEmpty ? [selected] : siblings
    }

    private func images(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return uniqueSorted(contents.filter(isSupportedImage))
    }

    private func isSupportedImage(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func uniqueSorted(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
