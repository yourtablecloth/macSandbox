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

/// Throttling log store for the UI.
///
/// QEMU output pours out line by line rapidly during boot, and updating `@Published` per line causes the entire
/// view tree observing it to re-render every time, making the boot overlay stutter.
/// It batches additions and publishes at most at 4Hz, and also caps the display length to bound the Text render cost.
@MainActor
final class LogBuffer: ObservableObject {

    @Published private(set) var text: String = ""

    /// Display cap (character count). When exceeded, the front is trimmed to keep only recent logs (the full log is not kept separately).
    private let maxLength = 64 * 1024
    private let flushInterval: Duration = .milliseconds(250)

    private var pending = ""
    private var flushScheduled = false

    func append(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }
        pending += trimmed + "\n"
        scheduleFlush()
    }

    func clear() {
        pending = ""
        text = ""
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: flushInterval)
            self.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        var merged = text + pending
        pending = ""
        if merged.count > maxLength {
            // Discard the front, aligned to a line boundary.
            let cut = merged.index(merged.endIndex, offsetBy: -maxLength)
            if let nl = merged[cut...].firstIndex(of: "\n") {
                merged = String(merged[merged.index(after: nl)...])
            } else {
                merged = String(merged[cut...])
            }
        }
        text = merged
    }
}
