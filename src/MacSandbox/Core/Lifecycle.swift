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

/// App lifetime ↔ VM lifetime synchronization hooks.
///
/// - Boot the VM when a window is created (ContentView auto-start).
/// - On window close / app quit attempts, after a **confirmation dialog**, stop + clean up the VM → quit together.
/// - If the app is force-quit/crashes, [QEMURuntime]'s parent-death watchdog destroys the VM (prevents orphans).
final class AppHooks {
    static let shared = AppHooks()
    weak var runner: SandboxRunner?
    private init() {}
}

/// If there is a running sandbox, ask for confirmation, and on approval stop it then proceed to quit.
/// Returns: true = OK to close immediately (not running), false = closing deferred (confirming/cleaning up).
@MainActor
private func confirmStopAndQuit() -> Bool {
    guard let runner = AppHooks.shared.runner, runner.isRunning else { return true }
    // If the terms consent gate is up, don't show a confirmation alert — the gate is a modal sheet,
    // so showing NSAlert.runModal() on top of it deadlocks, and 'close' means refusing consent, so confirmation is unnecessary.
    if ConsentStore.needsConsent {
        stopThenQuit(runner) { NSApp.terminate(nil) }
        return false
    }
    let alert = NSAlert()
    alert.messageText = L("quit.title")
    alert.informativeText = L("quit.message.close")
    alert.alertStyle = .warning
    alert.addButton(withTitle: L("quit.confirm"))   // default (first)
    alert.addButton(withTitle: L("common.cancel"))
    guard alert.runModal() == .alertFirstButtonReturn else { return false }
    stopThenQuit(runner) { NSApp.terminate(nil) }
    return false
}

/// Stops the sandbox and, after waiting (up to ~10s) for the disposable cleanup to finish, calls `finish`.
@MainActor
private func stopThenQuit(_ runner: SandboxRunner, finish: @escaping @MainActor () -> Void) {
    runner.stop()
    Task { @MainActor in
        for _ in 0..<50 {
            if !runner.isRunning { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        finish()
    }
}

/// Intercepts the main window's close (red button / ⌘W) and shows a confirmation dialog.
final class CloseGuard: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { confirmStopAndQuit() }
    }
}

/// Makes it appear and behave like a normal macOS app — shown in the menu bar/Dock (lifetime controlled via ⌘Q / window close).
final class SandboxAppDelegate: NSObject, NSApplicationDelegate {
    // When launching as a GUI rather than CLI (headless/test), become a regular app (.regular) — Dock icon + menu bar.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Called when a `.wsb` is double-clicked/dropped (file association) in Finder. It may arrive together with launch,
    // so this only delegates to the coordinator (parsing/start/error display are handled by ContentView observing it); if
    // the call comes at launch time, ContentView's first update starts immediately with explicitConfig.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { OpenWSB.shared.open(urls) }
    }

    // Closing the single window also quits the app (confirmation dialog in applicationShouldTerminate below).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let runner = AppHooks.shared.runner, runner.isRunning else {
                return NSApplication.TerminateReply.terminateNow
            }
            // If the terms consent gate (not yet consented) is up, stop then quit without a confirmation alert.
            // (NSAlert.runModal() on top of a modal sheet causes a deadlock, and ⌘Q/quit means refusing consent.)
            if ConsentStore.needsConsent {
                stopThenQuit(runner) { NSApp.reply(toApplicationShouldTerminate: true) }
                return NSApplication.TerminateReply.terminateLater
            }
            let alert = NSAlert()
            alert.messageText = L("quit.title")
            alert.informativeText = L("quit.message.quit")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("quit.confirm"))
            alert.addButton(withTitle: L("common.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else {
                return NSApplication.TerminateReply.terminateCancel
            }
            stopThenQuit(runner) { NSApp.reply(toApplicationShouldTerminate: true) }
            return NSApplication.TerminateReply.terminateLater
        }
    }
}
