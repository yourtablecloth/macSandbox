// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacSandbox",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MacSandbox",
            path: "src/MacSandbox"
        )
    ]
)
