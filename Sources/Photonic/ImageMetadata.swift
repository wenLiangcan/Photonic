import CoreGraphics
import CoreServices
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
        let exifAux = dictionary(properties[kCGImagePropertyExifAuxDictionary])
        let tiff = dictionary(properties[kCGImagePropertyTIFFDictionary])
        let gps = dictionary(properties[kCGImagePropertyGPSDictionary])
        var rows: [PhotoMetadata.Row] = []

        if let width = number(properties[kCGImagePropertyPixelWidth]),
           let height = number(properties[kCGImagePropertyPixelHeight]) {
            rows.append(.init(label: "Dimensions", value: "\(width.intValue) × \(height.intValue) px"))
        }

        if let fileSize = fileSize(for: url) {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            rows.append(.init(label: "File Size", value: formatter.string(fromByteCount: fileSize)))
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

        if let lens = (
            string(exif[kCGImagePropertyExifLensModel])
                ?? string(exifAux[kCGImagePropertyExifAuxLensModel])
        )?.nilIfEmpty {
            rows.append(.init(label: "Lens", value: lens))
        }

        let focalLength = positiveDouble(exif[kCGImagePropertyExifFocalLength])
            ?? metadataNumber(from: source, paths: ["exif:FocalLength", "Exif:FocalLength"])
            ?? spotlightNumber(for: url, attribute: kMDItemFocalLength)
        let equivalentFocalLength = positiveDouble(exif[kCGImagePropertyExifFocalLenIn35mmFilm])
            ?? metadataNumber(from: source, paths: [
                "exif:FocalLengthIn35mmFilm",
                "exif:FocalLenIn35mmFilm",
                "Exif:FocalLengthIn35mmFilm"
            ])
            ?? spotlightNumber(for: url, attribute: kMDItemFocalLength35mm)

        if let focalLength {
            var value = formattedMillimeters(focalLength)
            if let equivalentFocalLength,
               abs(equivalentFocalLength - focalLength) >= 0.05 {
                value += " (\(formattedMillimeters(equivalentFocalLength)) equivalent)"
            }
            rows.append(.init(label: "Focal Length", value: value))
        } else if let equivalentFocalLength {
            rows.append(.init(
                label: "Focal Length",
                value: "\(formattedMillimeters(equivalentFocalLength)) (35 mm equivalent)"
            ))
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

    nonisolated private static func positiveDouble(_ value: Any?) -> Double? {
        if let value = number(value)?.doubleValue, value > 0 { return value }
        guard let text = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }

        let components = text.split(separator: "/", maxSplits: 1)
        if components.count == 2,
           let numerator = Double(components[0]),
           let denominator = Double(components[1]),
           denominator != 0 {
            let value = numerator / denominator
            return value > 0 ? value : nil
        }

        guard let value = Scanner(string: text).scanDouble() else { return nil }
        return value > 0 ? value : nil
    }

    nonisolated private static func metadataNumber(
        from source: CGImageSource,
        paths: [String]
    ) -> Double? {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        for path in paths {
            guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString) else { continue }
            if let value = positiveDouble(CGImageMetadataTagCopyValue(tag)) { return value }
        }
        return nil
    }

    nonisolated private static func spotlightNumber(for url: URL, attribute: CFString) -> Double? {
        guard let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString),
              let value = MDItemCopyAttribute(item, attribute) else { return nil }
        return positiveDouble(value)
    }

    nonisolated private static func fileSize(for url: URL) -> Int64? {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let value = values.fileSize,
           value >= 0 {
            return Int64(value)
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let value = attributes[.size] as? NSNumber {
            return value.int64Value
        }
        return nil
    }

    nonisolated private static func formattedMillimeters(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 { return String(format: "%.0f mm", rounded) }
        return String(format: "%.1f mm", value)
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
