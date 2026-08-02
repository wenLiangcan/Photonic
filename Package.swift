// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Photonic",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Photonic", targets: ["Photonic"])
    ],
    targets: [
        .executableTarget(
            name: "Photonic",
            path: "Sources/Photonic"
        )
    ]
)
