import AppKit

@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 300
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    func image(for url: URL) -> NSImage? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key, cost: approximateCost(image))
        return image
    }

    private func approximateCost(_ image: NSImage) -> Int {
        Int(image.size.width * image.size.height * 4)
    }
}
