// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Picasa",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Picasa", targets: ["Picasa"])
    ],
    targets: [
        .executableTarget(
            name: "Picasa",
            path: "Sources/Picasa"
        )
    ]
)
