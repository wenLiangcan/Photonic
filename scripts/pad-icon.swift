import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 4,
      let scale = Double(CommandLine.arguments[3]),
      scale > 0, scale <= 1 else {
    fputs("usage: pad-icon.swift <input-directory> <output-directory> <scale>\n", stderr)
    exit(2)
}

let fileManager = FileManager.default
let inputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for inputURL in try fileManager.contentsOfDirectory(
    at: inputDirectory,
    includingPropertiesForKeys: nil,
    options: [.skipsHiddenFiles]
).filter({ $0.pathExtension.lowercased() == "png" }) {
    guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: image.width,
              height: image.height,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        throw CocoaError(.fileReadCorruptFile)
    }

    let insetX = Double(image.width) * (1 - scale) / 2
    let insetY = Double(image.height) * (1 - scale) / 2
    context.interpolationQuality = .high
    context.draw(
        image,
        in: CGRect(
            x: insetX,
            y: insetY,
            width: Double(image.width) * scale,
            height: Double(image.height) * scale
        )
    )

    guard let paddedImage = context.makeImage() else {
        throw CocoaError(.fileWriteUnknown)
    }

    let outputURL = outputDirectory.appendingPathComponent(inputURL.lastPathComponent)
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, paddedImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}
