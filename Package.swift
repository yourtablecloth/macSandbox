// swift-tools-version: 5.9

import PackageDescription

// FreeRDP(brew) 경로. 임베드 RDP 뷰(libfreerdp 직접 링크) PoC용.
let freerdpInclude = "/opt/homebrew/include/freerdp3"
let winprInclude = "/opt/homebrew/include/winpr3"
let brewLib = "/opt/homebrew/lib"

let package = Package(
    name: "MacSandbox",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // libfreerdp C 브리지 (임베드 RDP 뷰). brew freerdp 라이브러리에 직접 링크.
        .target(
            name: "CFreeRDP",
            path: "src/CFreeRDP",
            cSettings: [
                .unsafeFlags([
                    "-I\(freerdpInclude)",
                    "-I\(winprInclude)"
                ])
            ]
        ),
        .executableTarget(
            name: "MacSandbox",
            dependencies: ["CFreeRDP"],
            path: "src/MacSandbox",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(brewLib)",
                    "-lfreerdp-client3", "-lfreerdp3", "-lwinpr3"
                ])
            ]
        )
    ]
)
