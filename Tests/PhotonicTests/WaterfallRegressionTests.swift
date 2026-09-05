import Foundation
import Testing
@testable import Photonic

@Suite("Waterfall end-to-start layout")
@MainActor
struct WaterfallRegressionTests {
    @Test func scrollingFromTheLastImageDoesNotChangeExtentOrInstantiateAllImages() throws {
        let items = (1...1200).map { ViewerItem(url: URL(fileURLWithPath: "/virtual/image-\($0).jpg")) }
        let ratios = Dictionary(uniqueKeysWithValues: items.enumerated().map { index, item in
            (item.id, CGFloat([1.0, 0.66, 1.5, 1.78, 0.56, 3.0][index % 6]))
        })
        let layout = WaterfallLayoutResult(items: items, availableWidth: 1500, preferredWidth: 220,
                                          aspectRatios: ratios, spacing: 12)
        let last = try #require(layout.tiles.first { $0.item == items.last })
        let initialHeight = layout.contentSize.height
        #expect(last.frame.maxY <= initialHeight)
        var visited = Set<String>()
        for offset in stride(from: max(0, initialHeight - 900), through: 0, by: -300) {
            let visible = layout.tiles.filter { layout.isVisible($0, canvasMinY: -offset, viewportHeight: 900) }
            #expect(visible.count < 100)
            visited.formUnion(visible.map(\.id))
            #expect(layout.contentSize.height == initialHeight)
        }
        let top = layout.tiles.filter { layout.isVisible($0, canvasMinY: 64, viewportHeight: 900) }
        visited.formUnion(top.map(\.id))
        #expect(top.contains { $0.item == items.first })
        #expect(visited.count == items.count)
    }

    @Test(arguments: [120.0, 220.0, 420.0])
    func allAnchorsExistBeforeTheirImagesLoad(width: Double) {
        let items = (1...120).map { ViewerItem(url: URL(fileURLWithPath: "/virtual/\($0).jpg")) }
        let layout = WaterfallLayoutResult(items: items, availableWidth: 1000, preferredWidth: width,
                                          aspectRatios: [:], spacing: 12)
        #expect(Set(layout.tiles.map(\.id)) == Set(items.map(\.id)))
        for column in layout.columns {
            for (previous, next) in zip(column, column.dropFirst()) {
                #expect(next.frame.minY >= previous.frame.maxY + 11.99)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTONIC_TEST_IMAGES"] != nil),
          .timeLimit(.minutes(1)))
    func suppliedImageSetLoadsFromEndToStartAndCanceledRequestsDoNotDelayNewImages() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["PHOTONIC_TEST_IMAGES"])
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
                                                               includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        #expect(urls.count >= 120)
        let loader = WaterfallImageLoader()
        let items = urls.map { ViewerItem(url: $0) }
        let ratios = await loader.aspectRatios(for: items)
        #expect(ratios.count == items.count)
        for url in urls.reversed() {
            let image = await loader.thumbnail(for: url, maxPixelSize: 128)
            #expect(image != nil, "Unable to decode \(url.lastPathComponent)")
        }
        let first = try #require(urls.first)
        let requests = (0..<200).map { _ in Task { await loader.thumbnail(for: first, maxPixelSize: 128) } }
        try await Task.sleep(for: .milliseconds(100))
        requests.forEach { $0.cancel() }
        for request in requests { _ = await request.value }
        let clock = ContinuousClock()
        let start = clock.now
        let fresh = await loader.thumbnail(for: first, maxPixelSize: 128)
        #expect(fresh != nil)
        #expect(start.duration(to: clock.now) < .seconds(1), "Canceled requests left a delivery backlog")
    }
}
