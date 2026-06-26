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

/// Router — shows the build screen when there is no baseline (or when entering rebuild), and starts the sandbox immediately when there is one.
/// While running, the in-app embedded RDP view fills the window (single window).
struct ContentView: View {
    @ObservedObject var runner: SandboxRunner   // Owned by the App — shared with menu commands
    @ObservedObject var admin: BaselineAdmin    // Owned by the App — shared with the rebuild/destroy menus
    @ObservedObject private var openWSB = OpenWSB.shared   // Open-.wsb-file (association/button) notifications
    @StateObject private var builder = BaselineBuilder()
    @State private var baselineReady = false
    @State private var config: SandboxConfig = AppLaunch.shared.effectiveConfig()
    @State private var didAutoStart = false
    @State private var closeGuard = CloseGuard()
    @State private var wsbError: String?
    @State private var showConsent = ConsentStore.needsConsent

    var body: some View {
        Group {
            if showConsent {
                // Terms consent gate — a regular view that covers the whole window (not a modal sheet:
                // a sheet together with interactiveDismissDisabled blocks app termination, causing a bug where ⌘Q/quit does not work).
                TermsConsentView {
                    ConsentStore.recordAgreement()   // Record the consent version and timestamp (UserDefaults + audit log)
                    showConsent = false
                    proceedAfterConsent()
                }
            } else if baselineReady && !admin.rebuildMode {
                SandboxView(runner: runner, admin: admin, config: $config)
            } else {
                BuildView(builder: builder, admin: admin, canReturnToSandbox: baselineReady)
            }
        }
        .frame(minWidth: 680, minHeight: 600)
        .background(WindowAccessor { window in
            // Confirmation dialog when the window is closed (terminates together with the VM)
            window?.delegate = closeGuard
        })
        .alert(L("wsb.error.title"), isPresented: Binding(
            get: { wsbError != nil }, set: { if !$0 { wsbError = nil } })
        ) {
            Button(L("common.ok")) { wsbError = nil }
        } message: {
            Text(wsbError ?? "")
        }
        .onAppear {
            AppHooks.shared.runner = runner   // Referenced by the app/window termination hooks
            // Do nothing (e.g. auto-starting the sandbox) before the terms are accepted.
            guard !ConsentStore.needsConsent else { showConsent = true; return }
            proceedAfterConsent()
        }
        .onChange(of: builder.phase) { _, p in
            if p == .completed {
                // Including rebuilds — once the build finishes, enter a new sandbox immediately.
                admin.leaveRebuildMode()
                didAutoStart = false
                refresh()
            }
        }
        .onChange(of: admin.rebuildMode) { _, rebuilding in
            if !rebuilding { didAutoStart = false }
            refresh()
        }
        .onChange(of: runner.isRunning) { _, running in
            // The embedded RDP view renders inside the app window, so the window is not dismissed. Refresh only on termination.
            if !running { refresh() }
        }
        .onChange(of: openWSB.token) { _, _ in handleOpenWSB() }
        .onReceive(NotificationCenter.default.publisher(for: .msbxConsentChanged)) { _ in
            // On consent withdrawal: terminate the running sandbox + delete the base image + re-show the gate
            // (since there is no base image on re-consent, it enters the build screen). On re-consent (record), only the gate is dismissed.
            if ConsentStore.needsConsent {
                didAutoStart = false
                admin.destroyForConsentWithdrawal(runner: runner)
                showConsent = true
            } else {
                showConsent = false
            }
        }
    }

    /// Enter the normal flow after terms acceptance (or when already accepted) — auto-start + show `.wsb` errors at launch.
    private func proceedAfterConsent() {
        refresh()
        if let err = openWSB.errorMessage { wsbError = err }
    }

    /// If the baseline is ready, start the sandbox immediately (once, the first time). Otherwise the build screen.
    /// The startup configuration is effectiveConfig() — the explicit `.wsb`/CLI configuration if present, otherwise the options defaults.
    private func refresh() {
        guard !ConsentStore.needsConsent else { return }   // No auto-start before consent
        baselineReady = runner.hasBaseline()
        if !runner.isRunning {
            config = AppLaunch.shared.effectiveConfig()
        }
        if baselineReady, !admin.rebuildMode, !didAutoStart, !runner.isRunning {
            didAutoStart = true
            Task { await runner.start(config: config) }
        }
    }

    /// When a `.wsb` is opened while running (at runtime): an error on parse failure, or on success start a new sandbox immediately
    /// (when not running). If there is no baseline or a rebuild is in progress, only the configuration is applied and it auto-starts after the build completes.
    /// If already running, the current session is preserved and only the configuration is updated (applied on the next start).
    private func handleOpenWSB() {
        guard !ConsentStore.needsConsent else { return }   // After consent, proceedAfterConsent handles it
        if let err = openWSB.errorMessage { wsbError = err; return }
        guard let cfg = openWSB.pendingConfig else { return }
        config = cfg
        if baselineReady, !admin.rebuildMode, !runner.isRunning {
            Task { await runner.start(config: cfg) }
        }
    }
}

/// Captures a reference to the NSWindow that hosts the SwiftUI view (in order to dismiss or re-present the window).
/// The coordinator calls back only when the window actually changes, preventing a re-render loop.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { context.coordinator.update(v.window, onWindow) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.update(nsView.window, onWindow) }
    }
    final class Coordinator {
        weak var last: NSWindow?
        func update(_ w: NSWindow?, _ cb: (NSWindow?) -> Void) {
            guard w !== last else { return }
            last = w
            cb(w)
        }
    }
}

/// Automatic baseline build screen (shown when there is no baseline or when entering a rebuild)
///
/// Two modes keep the screen simple:
/// - **Setup mode** (before build): only the ISO/edition selection cards + the build button.
/// - **Install mode** (during build): hides the input form and shows only the progress card + boot monitor + log.
/// Before starting a build, the Windows license confirmation checklist sheet is shown every time.
struct BuildView: View {
    @ObservedObject var builder: BaselineBuilder
    @ObservedObject var admin: BaselineAdmin
    /// If true, this is rebuild mode with a ready baseline — shows the return-to-sandbox button.
    var canReturnToSandbox = false

    @State private var isoPath: String = ""
    @State private var imageEdition: String = "Windows 11 Pro"
    @State private var editions: [String] = []
    @State private var loadingEditions = false
    @State private var existing: BaselineMetadata?
    @State private var showLicenseChecklist = false

    private var canBuild: Bool {
        !builder.isRunning && !isoPath.isEmpty && FileManager.default.fileExists(atPath: isoPath)
            && !imageEdition.isEmpty && !loadingEditions
    }

    private var isFailed: Bool {
        if case .failed = builder.phase { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if builder.isRunning {
                    progressCard
                    if let console = builder.console { consoleCard(console) }
                    LogPane(buffer: builder.logBuffer, height: 150)
                } else {
                    if let existing { baselineCapsule(existing) }
                    setupCard
                    if isFailed { failureBanner }
                    buildButton
                    if isFailed { LogPane(buffer: builder.logBuffer, height: 150) }
                }
            }
            .padding(26)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)   // Center-aligned column
        }
        .sheet(isPresented: $showLicenseChecklist) {
            LicenseChecklistView {
                let config = InstallConfig(isoPath: isoPath, imageEdition: imageEdition)
                Task { await builder.build(config: config) }
            }
        }
        .onAppear {
            if isoPath.isEmpty {
                let def = SandboxPaths.defaultISO
                if FileManager.default.fileExists(atPath: def.path) { isoPath = def.path }
            }
            existing = builder.currentBaseline()
            loadEditions()
        }
        .onChange(of: builder.phase) { _, newPhase in
            if newPhase == .completed { existing = builder.currentBaseline() }
        }
    }

    // MARK: - Common header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("build.header.title"))
                    .font(.title).fontWeight(.semibold)
                Spacer()
                if canReturnToSandbox && !builder.isRunning {
                    Button(L("build.returnToSandbox")) { admin.leaveRebuildMode() }
                }
            }
            Text(L("build.header.desc"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Setup mode

    /// Summary of the existing baseline — in a single small capsule line (to check the status when entering a rebuild).
    private func baselineCapsule(_ meta: BaselineMetadata) -> some View {
        HStack(spacing: 8) {
            Image(systemName: meta.status == .ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(meta.status == .ready ? .green : .orange)
            Text(L("build.baseline.current", meta.name, meta.status.label))
                .font(.callout).fontWeight(.medium)
            Spacer()
            Text("\(meta.diskSizeGB)GB · \(meta.locale)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .help(meta.diskPath)
    }

    /// Setup form bundling ISO + edition into a single card.
    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ISO selection row
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "opticaldisc")
                    .font(.title2).foregroundStyle(.secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isoPath.isEmpty ? L("build.iso.none") : (isoPath as NSString).lastPathComponent)
                        .fontWeight(.medium)
                    if isoPath.isEmpty {
                        Text(L("build.iso.title")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(isoPath).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    if !isoPath.isEmpty, !FileManager.default.fileExists(atPath: isoPath) {
                        Label(L("build.iso.missing"), systemImage: "xmark.octagon")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                Spacer()
                Button(L("build.iso.choose")) { selectISO() }
            }
            .padding(14)

            Divider().padding(.horizontal, 14)

            // Edition row
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "square.stack.3d.up")
                    .font(.title2).foregroundStyle(.secondary).frame(width: 28)
                if loadingEditions {
                    ProgressView().controlSize(.small)
                    Text(L("build.edition.loading")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                } else if editions.isEmpty {
                    Text(isoPath.isEmpty ? L("build.edition.selectISOFirst") : L("build.edition.failed"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    Picker(L("build.edition.picker"), selection: $imageEdition) {
                        ForEach(editions, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }
            .padding(14)

            Divider().padding(.horizontal, 14)

            // Default specs notice
            Label(L("build.edition.defaults"), systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var failureBanner: some View {
        Label(builder.phase.label, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var buildButton: some View {
        Button {
            showLicenseChecklist = true   // License confirmation on every build
        } label: {
            Label(L("build.action.build"), systemImage: "hammer")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canBuild)
    }

    // MARK: - Install mode

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(builder.phase.label).font(.headline)
                Spacer()
                Button(role: .destructive) { builder.cancel() } label: {
                    Label(L("common.cancel"), systemImage: "stop.circle")
                }
                .controlSize(.regular)
            }
            ProgressView(value: builder.phase.fraction)
            if !builder.detail.isEmpty {
                Text(builder.detail).font(.caption).foregroundStyle(.secondary)
            }
            Text((isoPath as NSString).lastPathComponent + " · " + imageEdition)
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func consoleCard(_ console: VMConsole) -> some View {
        GroupBox(L("build.console.title")) {
            VMConsoleView(console: console)
                .padding(6)
        }
    }

    // MARK: - Actions

    private func loadEditions() {
        guard !isoPath.isEmpty, FileManager.default.fileExists(atPath: isoPath) else {
            editions = []
            return
        }
        loadingEditions = true
        let path = isoPath
        Task.detached {
            let result = (try? WinPEDeployMediaBuilder.listImageEditions(isoPath: path)) ?? []
            await MainActor.run {
                editions = result
                if result.contains("Windows 11 Pro") { imageEdition = "Windows 11 Pro" }
                else if let first = result.first { imageEdition = first }
                loadingEditions = false
            }
        }
    }

    private func selectISO() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let isoType = UTType(filenameExtension: "iso") {
            panel.allowedContentTypes = [isoType]
        }
        panel.message = L("build.iso.panel")
        panel.directoryURL = SandboxPaths.fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
        if panel.runModal() == .OK, let url = panel.url {
            isoPath = url.path
            loadEditions()
        }
    }
}
