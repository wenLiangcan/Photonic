import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: make-icns.swift <iconset-directory> <output.icns>\n", stderr)
    exit(2)
}

let inputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let chunks = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_16x16@2x.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_128x128@2x.png"),
    ("ic09", "icon_256x256@2x.png"),
    ("ic10", "icon_512x512@2x.png")
]

func bigEndianData(_ value: Int) -> Data {
    var encoded = UInt32(value).bigEndian
    return Data(bytes: &encoded, count: MemoryLayout<UInt32>.size)
}

var body = Data()
for (type, fileName) in chunks {
    let imageData = try Data(contentsOf: inputDirectory.appendingPathComponent(fileName))
    body.append(type.data(using: .ascii)!)
    body.append(bigEndianData(imageData.count + 8))
    body.append(imageData)
}

var icon = Data("icns".utf8)
icon.append(bigEndianData(body.count + 8))
icon.append(body)
try icon.write(to: outputURL, options: .atomic)
