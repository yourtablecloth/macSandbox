// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (C) 2026 Nam Jung Hyun (rkttu) <rkttu.official@gmail.com>
//
// This file is part of MacSandbox, which is dual-licensed:
//   (1) under the GNU General Public License v3.0 or later (see LICENSE), or
//   (2) under a commercial license (see COMMERCIAL-LICENSE.md).
// You may use this file under the terms of either license.
//
// MacSandbox is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

import SwiftUI
import CFreeRDP

/// libfreerdp 임베드 RDP 뷰를 SwiftUI에 올리는 래퍼.
/// 별도 FreeRDP 창 없이 인앱에서 RDP 화면을 렌더한다(렌더+입력+클립보드/파일).
struct RDPHostView: NSViewRepresentable {
    let host: String
    let port: Int
    var username: String = SandboxCreds.username
    var password: String = SandboxCreds.password
    /// 리다이렉션 기능(.wsb 반영). 스피커 재생은 항상 켜짐(.wsb 토글 없음).
    var clipboardEnabled: Bool = true
    var micEnabled: Bool = true
    var printerEnabled: Bool = false
    /// 공유 폴더(.wsb MappedFolders). 게스트에 리다이렉트 드라이브로 노출.
    var mappedFolders: [MappedFolder] = []
    /// 첫 RDP 프레임이 렌더되면 true (부팅 오버레이 → RDP 화면 전환용).
    @Binding var rendered: Bool

    func makeCoordinator() -> Coordinator { Coordinator(rendered: $rendered) }

    func makeNSView(context: Context) -> RDPView {
        let v = RDPView(frame: .zero)
        let coord = context.coordinator
        v.onFirstFrame = { coord.markRendered() }
        v.clipboardEnabled = clipboardEnabled   // connect 전에 설정(엔진 생성 시 반영)
        v.micEnabled = micEnabled
        v.printerEnabled = printerEnabled
        var usedNames = Set<String>()           // 게스트 드라이브 라벨(폴더명, 충돌 시 번호)
        for folder in mappedFolders {
            let base = (folder.hostPath as NSString).lastPathComponent
            var name = base.isEmpty ? "share" : base
            var i = 2
            while usedNames.contains(name) { name = "\(base)\(i)"; i += 1 }
            usedNames.insert(name)
            v.addMappedFolder(folder.hostPath, name: name, readOnly: folder.readOnly)
        }
        v.connect(toHost: host, port: Int32(port), username: username, password: password)
        return v
    }

    func updateNSView(_ nsView: RDPView, context: Context) {}

    static func dismantleNSView(_ nsView: RDPView, coordinator: Coordinator) {
        nsView.disconnect()
    }

    final class Coordinator {
        let rendered: Binding<Bool>
        init(rendered: Binding<Bool>) { self.rendered = rendered }
        func markRendered() {
            if !rendered.wrappedValue { rendered.wrappedValue = true }
        }
    }
}

/// `--freerdp-view <host:port>` 격리 테스트 앱.
struct RDPViewTestApp: App {
    var body: some Scene {
        WindowGroup("RDP View Test") {
            RDPViewTestContainer()
                .frame(minWidth: 800, minHeight: 600)
        }
        .defaultSize(width: 1024, height: 700)
    }
}

private struct RDPViewTestContainer: View {
    @State private var rendered = false
    var body: some View {
        RDPHostView(host: RDPViewTest.host, port: RDPViewTest.port,
                    clipboardEnabled: RDPViewTest.clipboard,
                    micEnabled: RDPViewTest.mic,
                    printerEnabled: RDPViewTest.printer,
                    mappedFolders: RDPViewTest.drivePath.isEmpty ? [] :
                        [MappedFolder(hostPath: RDPViewTest.drivePath, readOnly: false)],
                    rendered: $rendered)
    }
}

enum RDPViewTest {
    static var host = "127.0.0.1"
    static var port = 3389
    static var clipboard = true
    static var mic = true
    static var printer = false
    static var drivePath = ""
}
