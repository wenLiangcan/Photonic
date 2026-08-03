import CoreGraphics
import Foundation
import ImageIO

struct PhotoMetadata: Sendable {
    struct Row: Identifiable, Sendable {
        let id = UUID()
        let label: String
        let value: String
    }

    struct Location: Identifiable, Sendable {
        let latitude: Double
        let longitude: Double
        let altitude: Double?

        var id: String { "\(latitude),\(longitude)" }
    }

    let rows: [Row]
    let location: Location?
}

actor ImageMetadataLoader {
    static let shared = ImageMetadataLoader()

    private final class CacheEntry: NSObject, @unchecked Sendable {
        let metadata: PhotoMetadata

        init(_ metadata: PhotoMetadata) {
            self.metadata = metadata
        }
    }

    private final class MetadataCache: @unchecked Sendable {
        private let storage = NSCache<NSString, CacheEntry>()

        func metadata(for key: NSString) -> PhotoMetadata? {
            storage.object(forKey: key)?.metadata
        }

        func insert(_ metadata: PhotoMetadata, for key: NSString) {
            storage.setObject(CacheEntry(metadata), forKey: key)
        }
    }

    nonisolated private let cache = MetadataCache()

    nonisolated func cachedMetadata(for url: URL) -> PhotoMetadata? {
        cache.metadata(for: cacheKey(for: url))
    }

    func metadata(for url: URL) -> PhotoMetadata {
        let key = cacheKey(for: url)
        if let cached = cache.metadata(for: key) { return cached }

        let metadata = Self.readMetadata(from: url)
        cache.insert(metadata, for: key)
        return metadata
    }

    nonisolated private func cacheKey(for url: URL) -> NSString {
        url.standardizedFileURL.path as NSString
    }

    nonisolated private static func readMetadata(from url: URL) -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return PhotoMetadata(rows: [], location: nil)
        }

        let exif = dictionary(properties[kCGImagePropertyExifDictionary])
        let tiff = dictionary(properties[kCGImagePropertyTIFFDictionary])
        let gps = dictionary(properties[kCGImagePropertyGPSDictionary])
        var rows: [PhotoMetadata.Row] = []

        if let width = number(properties[kCGImagePropertyPixelWidth]),
           let height = number(properties[kCGImagePropertyPixelHeight]) {
            rows.append(.init(label: "Dimensions", value: "\(width.intValue) × \(height.intValue) px"))
        }

        let make = string(tiff[kCGImagePropertyTIFFMake])
        let model = string(tiff[kCGImagePropertyTIFFModel])
        if let camera = [make, model]
            .compactMap({ $0 })
            .filter({ !$0.isEmpty })
            .joined(separator: " ")
            .nilIfEmpty {
            rows.append(.init(label: "Camera", value: camera))
        }

        if let lens = string(exif[kCGImagePropertyExifLensModel])?.nilIfEmpty {
            rows.append(.init(label: "Lens", value: lens))
        }

        if let date = string(exif[kCGImagePropertyExifDateTimeOriginal])
            ?? string(tiff[kCGImagePropertyTIFFDateTime]) {
            rows.append(.init(label: "Captured", value: formattedEXIFDate(date)))
        }

        if let exposure = number(exif[kCGImagePropertyExifExposureTime])?.doubleValue,
           exposure > 0 {
            rows.append(.init(label: "Exposure", value: formattedExposure(exposure)))
        }

        if let aperture = number(exif[kCGImagePropertyExifFNumber])?.doubleValue,
           aperture > 0 {
            rows.append(.init(label: "Aperture", value: String(format: "ƒ/%.1f", aperture)))
        }

        if let iso = firstNumber(exif[kCGImagePropertyExifISOSpeedRatings]) {
            rows.append(.init(label: "ISO", value: "\(iso.intValue)"))
        }

        if let focalLength = number(exif[kCGImagePropertyExifFocalLength])?.doubleValue,
           focalLength > 0 {
            rows.append(.init(label: "Focal Length", value: String(format: "%.0f mm", focalLength)))
        }

        if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            rows.append(.init(label: "File Size", value: formatter.string(fromByteCount: Int64(fileSize))))
        }

        return PhotoMetadata(rows: rows, location: location(from: gps))
    }

    nonisolated private static func location(from gps: [CFString: Any]) -> PhotoMetadata.Location? {
        guard var latitude = number(gps[kCGImagePropertyGPSLatitude])?.doubleValue,
              var longitude = number(gps[kCGImagePropertyGPSLongitude])?.doubleValue else { return nil }

        if string(gps[kCGImagePropertyGPSLatitudeRef])?.uppercased() == "S" { latitude.negate() }
        if string(gps[kCGImagePropertyGPSLongitudeRef])?.uppercased() == "W" { longitude.negate() }
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }

        var altitude = number(gps[kCGImagePropertyGPSAltitude])?.doubleValue
        if number(gps[kCGImagePropertyGPSAltitudeRef])?.intValue == 1 { altitude?.negate() }
        return PhotoMetadata.Location(latitude: latitude, longitude: longitude, altitude: altitude)
    }

    nonisolated private static func dictionary(_ value: Any?) -> [CFString: Any] {
        if let dictionary = value as? [CFString: Any] { return dictionary }
        if let dictionary = value as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: dictionary.map { ($0.key as CFString, $0.value) })
        }
        return [:]
    }

    nonisolated private static func number(_ value: Any?) -> NSNumber? {
        value as? NSNumber
    }

    nonisolated private static func firstNumber(_ value: Any?) -> NSNumber? {
        if let number = value as? NSNumber { return number }
        return (value as? [NSNumber])?.first
    }

    nonisolated private static func string(_ value: Any?) -> String? {
        value as? String
    }

    nonisolated private static func formattedExposure(_ exposure: Double) -> String {
        if exposure < 1 {
            let denominator = max(Int((1 / exposure).rounded()), 1)
            return "1/\(denominator) s"
        }
        return String(format: "%.1f s", exposure)
    }

    nonisolated private static func formattedEXIFDate(_ value: String) -> String {
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = input.date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
