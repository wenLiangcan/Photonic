import AppKit
import Foundation
import UniformTypeIdentifiers

struct ViewerItem: Identifiable, Hashable, Sendable {
    let url: URL

    var id: String { url.standardizedFileURL.path }
    var fileName: String { url.lastPathComponent }
}

enum ZoomAction: Sendable {
    case zoomIn
    case zoomOut
    case fit
    case continuous(delta: Double)
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

    func presentOpenPanel(selectingComparison: Bool = false) {
        if let openPanel {
            openPanel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSOpenPanel()
        panel.title = selectingComparison ? "Choose an image to compare" : "Open an image or folder"
        panel.prompt = selectingComparison ? "Compare" : "Open"
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

        openPanel = panel
        panel.begin { [weak self, weak panel] response in
            guard let self else { return }
            defer {
                if self.openPanel === panel { self.openPanel = nil }
            }
            guard response == .OK, let panel else { return }

            if selectingComparison, let url = panel.url {
                self.comparisonItem = ViewerItem(url: url.standardizedFileURL)
                self.isComparing = true
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
    }

    func next() {
        guard !items.isEmpty else { return }
        currentIndex = (currentIndex + 1) % items.count
        resetViewState()
    }

    func previous() {
        guard !items.isEmpty else { return }
        currentIndex = (currentIndex - 1 + items.count) % items.count
        resetViewState()
    }

    func rotateClockwise() {
        rotationQuarterTurns = (rotationQuarterTurns + 1) % 4
    }

    func toggleSlideshow() {
        isSlideshowRunning ? stopSlideshow() : startSlideshow()
    }

    func startSlideshow() {
        guard items.count > 1 else { return }
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
        zoomCommand = ZoomCommand(action: .fit)
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
