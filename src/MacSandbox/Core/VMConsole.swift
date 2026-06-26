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

import Foundation
import AppKit

/// Interactive console for a running VM.
///
/// Handles a single QMP connection on a serial queue and:
/// - Periodically captures the guest screen and publishes it as `frame` (in-app monitoring)
/// - Forwards the user's keyboard/mouse input to the guest (intervention)
final class VMConsole: ObservableObject {

    @Published private(set) var frame: NSImage?
    @Published private(set) var isConnected = false

    private let injector: QMPInputInjector
    private let qmpQueue = DispatchQueue(label: "MacSandbox.qmp")
    private let framePath: String
    private let capturesFrames: Bool

    // qmpQueue-only state
    private var running = false
    private var lastFrameData: Data?

    init(socketPath: String, capturesFrames: Bool) {
        self.injector = QMPInputInjector(socketPath: socketPath)
        self.capturesFrames = capturesFrames
        self.framePath = "/tmp/msbx-frame-\(UUID().uuidString.prefix(8)).png"
    }

    // MARK: - Lifecycle

    /// Start connecting + screen polling.
    func start() {
        qmpQueue.async { [weak self] in
            guard let self else { return }
            self.running = true
            let ok = self.injector.connect()
            DispatchQueue.main.async { self.isConnected = ok }
            if ok { self.tick() }
        }
    }

    func stop() {
        qmpQueue.async { [weak self] in
            self?.running = false
            self?.injector.close()
        }
        DispatchQueue.main.async { [weak self] in self?.isConnected = false }
    }

    // MARK: - Input (called from the UI)

    func sendKey(_ qcode: String) {
        qmpQueue.async { [weak self] in self?.injector.sendKey(qcode) }
    }

    func sendKeyCombo(_ qcodes: [String]) {
        qmpQueue.async { [weak self] in self?.injector.sendKeyCombo(qcodes) }
    }

    /// Click using fractional screen coordinates (0...1)
    func click(fractionX: Double, fractionY: Double, button: String = "left") {
        let x = Int((max(0, min(1, fractionX))) * 32767)
        let y = Int((max(0, min(1, fractionY))) * 32767)
        qmpQueue.async { [weak self] in
            self?.injector.moveAbsolute(x: x, y: y)
            self?.injector.click(button: button)
        }
    }

    // MARK: - Private (qmpQueue)

    private func tick() {
        guard running else { return }

        // Screen capture → publish. If identical to the previous frame, skip publishing
        // to avoid unnecessary view re-renders on static screens (e.g. the boot stage).
        if capturesFrames {
            injector.screendump(to: framePath)
            if let data = try? Data(contentsOf: URL(fileURLWithPath: framePath)),
               data != lastFrameData,
               let image = NSImage(data: data) {
                lastFrameData = data
                DispatchQueue.main.async { [weak self] in self?.frame = image }
            }
        }

        qmpQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.tick() }
    }
}
