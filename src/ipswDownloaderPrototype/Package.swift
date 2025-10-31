// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "macosdownloader",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // CLI 실행 파일 (기존)
        .executable(name: "macosdownloader", targets: ["macosdownloader"]),
        // C 호환 동적 라이브러리 (신규)
        .library(name: "MacOSDownloaderLib", type: .dynamic, targets: ["MacOSDownloaderLib"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        // CLI 타겟 (기존)
        .executableTarget(
            name: "macosdownloader",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "SharedCore"
            ],
            path: "Sources/CLI",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        // 공유 코어 라이브러리
        .target(
            name: "SharedCore",
            dependencies: [],
            path: "Sources/Core"
        ),
        // C 호환 라이브러리 타겟 (신규)
        .target(
            name: "MacOSDownloaderLib",
            dependencies: ["SharedCore"],
            path: "Sources/CLib",
            publicHeadersPath: "include"
        )
    ]
)
