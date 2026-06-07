// swift-tools-version: 5.9

import PackageDescription

// FreeRDP(brew) 경로. 임베드 RDP 뷰(libfreerdp 직접 링크).
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
                    "-I\(winprInclude)",
                    // freerdp 3.x 헤더는 구조체에 deprecated 멤버를 선언해 include만 해도 경고가 난다.
                    // 서드파티 브리지 타깃이므로 deprecation 경고를 일괄 억제한다.
                    "-Wno-deprecated-declarations"
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
