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

import AppKit

/// Baseline management (rebuild/destroy) orchestrator.
///
/// - Rebuild: confirm → (if running) wait for the sandbox to stop → switch to the build screen (`rebuildMode`).
///   The actual replacement is performed by BaselineBuilder.build (delete the existing baseline directory, then install anew).
/// - Destroy: confirm → wait for stop → delete the baseline directory → the router naturally shows the build screen.
@MainActor
final class BaselineAdmin: ObservableObject {

    /// If true, show the build screen even when a baseline is ready (entering rebuild).
    @Published var rebuildMode = false
    /// Stop-wait/delete in progress — prevents duplicate menu invocations.
    @Published private(set) var busy = false

    func hasBaseline() -> Bool {
        FileManager.default.fileExists(atPath: SandboxPaths.baselineMetadataPath.path)
    }

    /// Menu/button: rebuild the baseline. After confirmation, stop the sandbox and switch to the build screen.
    func requestRebuild(runner: SandboxRunner) {
        guard !busy, !rebuildMode else { return }
        guard confirm(title: L("admin.rebuild.title"),
                      message: L("admin.rebuild.message"),
                      confirmTitle: L("admin.rebuild.confirm")) else { return }
        busy = true
        Task { @MainActor in
            await self.stopAndWait(runner: runner)
            self.rebuildMode = true
            self.busy = false
        }
    }

    /// Menu/button: destroy the base image. After confirmation, stop the sandbox and delete the baseline directory.
    func requestDestroy(runner: SandboxRunner) {
        guard !busy else { return }
        guard confirm(title: L("admin.destroy.title"),
                      message: L("admin.destroy.message"),
                      confirmTitle: L("admin.destroy.confirm"),
                      destructive: true) else { return }
        busy = true
        Task { @MainActor in
            await self.performDestroy(runner: runner)
            self.busy = false
        }
    }

    /// Terms consent withdrawal: **immediately, without confirmation**, stops the sandbox and deletes the base image.
    /// (The withdrawal confirmation step already warns about this destructive outcome, so no additional confirmation is taken.)
    func destroyForConsentWithdrawal(runner: SandboxRunner) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            await self.performDestroy(runner: runner)
            self.busy = false
        }
    }

    /// Stop-wait + base image deletion (shared). The caller is responsible for user confirmation.
    private func performDestroy(runner: SandboxRunner) async {
        await stopAndWait(runner: runner)
        if let data = try? Data(contentsOf: SandboxPaths.baselineMetadataPath),
           let meta = try? JSONDecoder.iso8601.decode(BaselineMetadata.self, from: data) {
            BaselineCredentialStore.delete(id: meta.credentialID)
        }
        try? FileManager.default.removeItem(at: SandboxPaths.baselineDir)
        rebuildMode = true   // Trigger router refresh (no baseline, so the build screen)
    }

    /// Build complete / go back — return to normal routing (sandbox auto-start).
    func leaveRebuildMode() {
        rebuildMode = false
    }

    private func stopAndWait(runner: SandboxRunner) async {
        guard runner.isRunning else { return }
        runner.stop()
        for _ in 0..<50 {              // up to ~10s (same as Lifecycle's shutdown wait)
            if !runner.isRunning { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func confirm(title: String, message: String, confirmTitle: String,
                         destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .critical : .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: L("common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
