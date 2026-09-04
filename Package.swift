// swift-tools-version: 5.9

import PackageDescription

// FreeRDP(brew) paths. Embedded RDP view (direct libfreerdp linking).
let freerdpInclude = "/opt/homebrew/include/freerdp3"
let winprInclude = "/opt/homebrew/include/winpr3"
let brewLib = "/opt/homebrew/lib"

let package = Package(
    name: "MacSandbox",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // libfreerdp C bridge (embedded RDP view). Links directly to the brew freerdp library.
        .target(
            name: "CFreeRDP",
            path: "src/CFreeRDP",
            cSettings: [
                .unsafeFlags([
                    "-I\(freerdpInclude)",
                    "-I\(winprInclude)",
                    // freerdp 3.x headers declare deprecated members in their structs, so even just including them produces warnings.
                    // Since this is a third-party bridge target, suppress all deprecation warnings.
                    "-Wno-deprecated-declarations"
                ])
            ]
        ),
        .executableTarget(
            name: "MacSandbox",
            dependencies: ["CFreeRDP"],
            path: "src/MacSandbox",
            resources: [
                .process("Resources"),    // .lproj localization (Localizable.strings)
                .copy("Terms")            // Per-language terms markdown (Terms/<lang>.md) — bundled at build time
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .unsafeFlags([
                    "-L\(brewLib)",
                    "-lfreerdp-client3", "-lfreerdp3", "-lwinpr3"
                ])
            ]
        ),
        .testTarget(
            name: "MacSandboxTests",
            dependencies: ["MacSandbox"],
            path: "Tests/MacSandboxTests"
        )
    ]
)
