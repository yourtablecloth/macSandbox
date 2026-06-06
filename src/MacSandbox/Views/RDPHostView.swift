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
    /// 첫 RDP 프레임이 렌더되면 true (부팅 오버레이 → RDP 화면 전환용).
    @Binding var rendered: Bool

    func makeCoordinator() -> Coordinator { Coordinator(rendered: $rendered) }

    func makeNSView(context: Context) -> RDPView {
        let v = RDPView(frame: .zero)
        let coord = context.coordinator
        v.onFirstFrame = { coord.markRendered() }
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
        RDPHostView(host: RDPViewTest.host, port: RDPViewTest.port, rendered: $rendered)
    }
}

enum RDPViewTest {
    static var host = "127.0.0.1"
    static var port = 3389
}
