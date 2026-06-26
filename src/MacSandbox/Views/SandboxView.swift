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
import AppKit
import UniformTypeIdentifiers

/// Sandbox run screen. Once the baseline is ready, the router starts it immediately.
///
/// - While running: the **in-app embedded RDP view** fills the window (no external FreeRDP window). Before the first frame,
///   it shows the boot overlay (status/elapsed time/console/log), and dismisses the overlay once the RDP screen is drawn.
/// - After termination: restart / load `.wsb` / rebuild or destroy the baseline.
struct SandboxView: View {
    @ObservedObject var runner: SandboxRunner
    @ObservedObject var admin: BaselineAdmin
    @Binding var config: SandboxConfig
    @State private var showDetails = false
    @State private var rdpRendered = false

    var body: some View {
        Group {
            if runner.isRunning {
                runningView
            } else if isEnded {
                endedView.padding(28)
            } else {
                startingView.padding(28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: runner.isRunning) { _, running in
            if !running { rdpRendered = false; showDetails = false }
        }
    }

    private var isEnded: Bool {
        if case .failed = runner.state { return true }
        return runner.state == .ended
    }

    private var isFailure: Bool {
        if case .failed = runner.state { return true }
        return false
    }

    // MARK: - Running (embedded RDP view)

    private var runningView: some View {
        ZStack {
            // Fills the content area below the title bar (extending into the title bar with ignoresSafeArea would obscure the top).
            Color.black
            if runner.rdpPort > 0 {
                RDPHostView(host: "127.0.0.1", port: runner.rdpPort,
                            clipboardEnabled: runner.activeConfig.clipboardEnabled,
                            micEnabled: runner.activeConfig.audioInputEnabled,
                            printerEnabled: runner.activeConfig.printerEnabled,
                            mounts: runner.activeConfig.resolvedMounts(),
                            rendered: $rdpRendered)
            }
            if !rdpRendered { bootOverlay }
            // Termination is controlled by the menu (Sandbox › Stop Sandbox ⌘.) · closing the window · ⌘Q (floating button removed).
        }
    }

    /// Boot overlay — shown until the first RDP frame is drawn.
    private var bootOverlay: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Spacer()
                ProgressView().controlSize(.large)
                Text(L("run.boot.title")).font(.title2).fontWeight(.semibold)
                Text(runner.status).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let startedAt = runner.bootStartedAt {
                    BootElapsedLabel(startedAt: startedAt)
                }
                Text(L("run.boot.hint"))
                    .font(.caption).foregroundStyle(.secondary)

                DisclosureGroup(isExpanded: $showDetails) {
                    detailPane.padding(.top, 8)
                } label: {
                    Text(L("run.boot.details")).font(.callout)
                }
                .frame(maxWidth: 640)
                Spacer()
            }
            .padding(28)
        }
    }

    /// Console (boot monitor) + log
    private var detailPane: some View {
        VStack(spacing: 10) {
            if let console = runner.console {
                GroupBox(L("run.console.title")) {
                    VMConsoleView(console: console).padding(6)
                }
            }
            LogPane(buffer: runner.logBuffer)
        }
    }

    // MARK: - Just before start

    private var startingView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(L("run.starting")).font(.title3).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - After termination

    private var endedView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: isFailure ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(isFailure ? .orange : .secondary)
            Text(isFailure ? runner.status : L("run.ended.title")).font(.title3).fontWeight(.medium)
            Text(L("run.ended.discarded")).font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button { Task { await runner.start(config: config) } } label: {
                    Label(L("run.startNew"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button { loadWSB() } label: {
                    Label(L("run.loadWSB"), systemImage: "doc.badge.gearshape")
                }
                .controlSize(.large)
            }

            // Baseline management — rebuild (re-run the install) / destroy (delete the base image)
            HStack(spacing: 10) {
                Button { admin.requestRebuild(runner: runner) } label: {
                    Label(L("ended.rebuild"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(admin.busy)
                Button(role: .destructive) { admin.requestDestroy(runner: runner) } label: {
                    Label(L("ended.destroy"), systemImage: "trash")
                }
                .disabled(admin.busy)
            }
            .controlSize(.small)

            DisclosureGroup(L("common.log")) {
                LogPane(buffer: runner.logBuffer).padding(.top, 6)
            }
            .frame(maxWidth: 640)
            Spacer()
        }
    }

    // MARK: - Loading .wsb

    private func loadWSB() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let wsbType = UTType(filenameExtension: "wsb") {
            panel.allowedContentTypes = [wsbType, .xml]
        }
        panel.message = L("run.wsb.panel")
        if panel.runModal() == .OK, let url = panel.url {
            // Same path as the Finder file association — on successful parse ContentView starts a new sandbox
            // immediately, and on failure it shows an error.
            OpenWSB.shared.open([url])
        }
    }
}

/// Boot elapsed-time label — only the TimelineView updates every second, avoiding a re-render of the whole overlay.
private struct BootElapsedLabel: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
            Text(L("run.boot.elapsed", String(format: "%d:%02d", seconds / 60, seconds % 60)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
