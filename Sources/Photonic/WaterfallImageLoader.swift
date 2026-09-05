import CoreGraphics
import Foundation
import ImageIO

actor WaterfallImageLoader {
    static let shared = WaterfallImageLoader()

    private let thumbnailCache = NSCache<NSString, CGImage>()
    private var aspectRatioCache: [String: CGFloat] = [:]
    private let deliveryClock = ContinuousClock()
    private var nextDeliveryTime: ContinuousClock.Instant?

    init() {
        thumbnailCache.countLimit = 240
        thumbnailCache.totalCostLimit = 160 * 1024 * 1024
    }

    func aspectRatios(for items: [ViewerItem]) async -> [String: CGFloat] {
        let itemIDs = Set(items.map(\.id))
        var result = aspectRatioCache.filter { key, _ in itemIDs.contains(key) }
        let missingItems = items.filter { result[$0.id] == nil }

        for item in missingItems {
            guard !Task.isCancelled else { return result }
            let id = item.id
            let ratio = Self.readAspectRatio(from: item.url)
            aspectRatioCache[id] = ratio
            result[id] = ratio
        }
        return result
    }

    func thumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        let bucketedSize = max(128, Int(ceil(Double(maxPixelSize) / 128)) * 128)
        let key = "\(url.standardizedFileURL.path)#\(bucketedSize)" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            await waitForDeliverySlot()
            return Task.isCancelled ? nil : cached
        }

        guard !Task.isCancelled,
              let image = Self.makeThumbnail(from: url, maxPixelSize: bucketedSize) else { return nil }
        thumbnailCache.setObject(
            image,
            forKey: key,
            cost: image.width * image.height * 4
        )
        await waitForDeliverySlot()
        guard !Task.isCancelled else { return nil }
        return image
    }

    private func waitForDeliverySlot() async {
        // Claim only the slot actually used. Canceled offscreen requests must
        // not reserve seconds of future delivery time ahead of visible photos.
        while !Task.isCancelled {
            let now = deliveryClock.now
            if let nextDeliveryTime, nextDeliveryTime > now {
                do { try await deliveryClock.sleep(until: nextDeliveryTime) }
                catch { return }
                continue
            }
            nextDeliveryTime = now.advanced(by: .milliseconds(16))
            return
        }
    }

    nonisolated private static func readAspectRatio(from url: URL) -> CGFloat {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { return 4 / 3 }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) {
            return CGFloat(height.doubleValue / width.doubleValue)
        }
        return CGFloat(width.doubleValue / height.doubleValue)
    }

    nonisolated private static func makeThumbnail(from url: URL, maxPixelSize: Int) -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard !Task.isCancelled else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
