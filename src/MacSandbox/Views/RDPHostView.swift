// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Nam Jung Hyun (rkttu)
//
// This file is part of MacSandbox, which is dual-licensed:
//   (1) under the GNU Affero General Public License v3.0 or later (see LICENSE), or
//   (2) under a commercial license (see COMMERCIAL-LICENSE.md).
// You may use this file under the terms of either license.
//
// MacSandbox is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

import SwiftUI
import CFreeRDP

/// Wrapper that hosts the libfreerdp embedded RDP view in SwiftUI.
/// Renders the RDP screen in-app without a separate FreeRDP window (render + input + clipboard/files).
struct RDPHostView: NSViewRepresentable {
    let host: String
    let port: Int
    var username: String = SandboxCreds.username
    var password: String = SandboxCreds.password
    /// Redirection features (reflecting .wsb). Speaker playback is always on (no .wsb toggle).
    var clipboardEnabled: Bool = true
    var micEnabled: Bool = true
    var printerEnabled: Bool = false
    /// Resolved result of shared folders (.wsb MappedFolders). The drive name is derived from
    /// SandboxConfig.resolvedMounts() and matches the logon mount (\\tsclient\<driveName>).
    var mounts: [ResolvedMount] = []
    /// True once the first RDP frame is rendered (for the boot overlay → RDP screen transition).
    @Binding var rendered: Bool

    func makeCoordinator() -> Coordinator { Coordinator(rendered: $rendered) }

    func makeNSView(context: Context) -> RDPView {
        let v = RDPView(frame: .zero)
        let coord = context.coordinator
        v.onFirstFrame = { coord.markRendered() }
        v.clipboardEnabled = clipboardEnabled   // Set before connect (applied when the engine is created)
        v.micEnabled = micEnabled
        v.printerEnabled = printerEnabled
        // Options-dialog settings (applied from the next connection): audio playback / HiDPI / keyboard identification (Korean/English, etc.)
        v.audioPlaybackEnabled = AppOptions.audioPlayback
        v.hiDPIEnabled = AppOptions.hiDPI
        let kb = AppOptions.keyboardLayout.rdpValues
        if kb.type > 0 || kb.layout > 0 {
            v.setKeyboardType(kb.type, subtype: kb.subtype, layout: kb.layout)
        }
        for m in mounts {                        // rdpdr drive name = resolvedMounts' driveName
            v.addMappedFolder(m.hostPath, name: m.driveName, readOnly: m.readOnly)
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

/// `--freerdp-view <host:port>` isolated test app.
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
    private var testMounts: [ResolvedMount] {
        guard !RDPViewTest.drivePath.isEmpty else { return [] }
        var c = SandboxConfig()
        c.mappedFolders = [MappedFolder(hostPath: RDPViewTest.drivePath)]
        return c.resolvedMounts()
    }
    var body: some View {
        RDPHostView(host: RDPViewTest.host, port: RDPViewTest.port,
                    clipboardEnabled: RDPViewTest.clipboard,
                    micEnabled: RDPViewTest.mic,
                    printerEnabled: RDPViewTest.printer,
                    mounts: testMounts,
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
