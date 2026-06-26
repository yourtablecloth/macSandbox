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
import CFreeRDP

/// Entry point.
/// - GUI (default): the build screen if there is no baseline, otherwise the sandbox start screen.
/// - Headless build: `MacSandbox --headless-build [ISO path]` → a 1-round build without a GUI, then exit.
/// - Sandbox run options (detailed settings): specified via a `.wsb` file or command-line switches. If the baseline is
///   ready, the GUI **starts the sandbox immediately** (no start button).
///   - `MacSandbox <config.wsb>` or `MacSandbox --wsb <config.wsb>` → start as configured
///   - Switches: `--memory <MB>` `--cpus <N>` `--networking on|off` `--vgpu on|off`
///            `--clipboard on|off` `--audio on|off` `--printer on|off`
///            `--folder <path>[:ro]` (repeatable) `--logon "<command>"` (`--run` is a compatibility no-op)
///   - When no switches/`.wsb` are specified, start with the Windows Sandbox standard defaults.
@main
enum AppEntry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--freerdp-link-test") {
            if let c = cfreerdp_link_test() {
                print("[MacSandbox] FreeRDP link test: \(String(cString: c))")
            }
            exit(0)
        }
        if args.contains("--freerdp-fliptest") {
            exit(cfreerdp_fliptest())
        }
        if let idx = args.firstIndex(of: "--freerdp-view"), idx + 1 < args.count {
            let parts = args[idx + 1].split(separator: ":")
            RDPViewTest.host = String(parts[0])
            RDPViewTest.port = parts.count > 1 ? Int(parts[1]) ?? 3389 : 3389
            // env for verifying feature gating (defaults if unset): MSBX_CLIPBOARD/MSBX_MIC/MSBX_PRINTER = 0|1
            let env = ProcessInfo.processInfo.environment
            if let v = env["MSBX_CLIPBOARD"] { RDPViewTest.clipboard = (v != "0") }
            if let v = env["MSBX_MIC"] { RDPViewTest.mic = (v != "0") }
            if let v = env["MSBX_PRINTER"] { RDPViewTest.printer = (v != "0") }
            if let v = env["MSBX_DRIVE"], !v.isEmpty { RDPViewTest.drivePath = v }
            RDPViewTestApp.main()
            return
        }
        if let idx = args.firstIndex(of: "--freerdp-cliptest"), idx + 1 < args.count {
            let parts = args[idx + 1].split(separator: ":")
            let host = String(parts[0])
            let port = parts.count > 1 ? Int(parts[1]) ?? 3389 : 3389
            let rc = cfreerdp_cliptest(host, Int32(port))
            exit(rc)
        }
        if let idx = args.firstIndex(of: "--freerdp-filetest"), idx + 1 < args.count {
            let parts = args[idx + 1].split(separator: ":")
            let host = String(parts[0])
            let port = parts.count > 1 ? Int(parts[1]) ?? 3389 : 3389
            let rc = cfreerdp_filetest(host, Int32(port))
            exit(rc)
        }
        if let idx = args.firstIndex(of: "--freerdp-filetest3"), idx + 1 < args.count {
            let parts = args[idx + 1].split(separator: ":")
            let host = String(parts[0])
            let port = parts.count > 1 ? Int(parts[1]) ?? 3389 : 3389
            let rc = cfreerdp_filetest3(host, Int32(port))
            exit(rc)
        }
        if let idx = args.firstIndex(of: "--freerdp-restest"), idx + 1 < args.count {
            let parts = args[idx + 1].split(separator: ":")
            let host = String(parts[0])
            let port = parts.count > 1 ? Int(parts[1]) ?? 3389 : 3389
            let rc = cfreerdp_restest(host, Int32(port))
            exit(rc)
        }
        if let idx = args.firstIndex(of: "--freerdp-filetest2"), idx + 1 < args.count {
            let parts = args[idx + 1].split(separator: ":")
            let host = String(parts[0])
            let port = parts.count > 1 ? Int(parts[1]) ?? 3389 : 3389
            let rc = cfreerdp_filetest2(host, Int32(port))
            exit(rc)
        }
        if let idx = args.firstIndex(of: "--freerdp-capture"), idx + 2 < args.count {
            let hostport = args[idx + 1]
            let out = args[idx + 2]
            let parts = hostport.split(separator: ":")
            let host = String(parts[0])
            let port = parts.count > 1 ? Int(parts[1]) ?? 3389 : 3389
            print("[MacSandbox] FreeRDP capture: \(host):\(port) → \(out)")
            let rc = cfreerdp_capture(host, Int32(port), out)
            print("[MacSandbox] result: rc=\(rc) (0=success)")
            exit(rc == 0 ? 0 : 1)
        }
        if let idx = args.firstIndex(of: "--headless-build") {
            let isoArg = (idx + 1 < args.count && !args[idx + 1].hasPrefix("-")) ? args[idx + 1] : nil
            HeadlessRunner.run(isoPathArg: isoArg)   // exit() internally
        } else {
            AppLaunch.shared.configure(from: args)
            MacSandboxGUIApp.main()
        }
    }
}

struct MacSandboxGUIApp: App {
    // Menu bar/Dock display + lifecycle control (⌘Q · window-close confirmation). The app delegate activates .regular.
    @NSApplicationDelegateAdaptor(SandboxAppDelegate.self) private var appDelegate
    // The sandbox runner/baseline admin are owned by the App — shared by ContentView and the menu commands.
    @StateObject private var runner = SandboxRunner()
    @StateObject private var admin = BaselineAdmin()

    var body: some Scene {
        // Single window (Window) — unlike WindowGroup, a new window (⌘N) is not possible, constraining the sandbox to a single window.
        Window(Brand.appName, id: "sandbox") {
            ContentView(runner: runner, admin: admin)
        }
        .defaultSize(width: 1024, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }   // Remove "New Window" (single-window constraint)
            CommandGroup(replacing: .appInfo) { AboutMenuItem() }   // Custom 'About' window
            CommandGroup(replacing: .help) {        // Default help → online help (GitHub Pages)
                Button(L("menu.help")) {
                    if let url = URL(string: HelpLinks.help) { NSWorkspace.shared.open(url) }
                }
                .keyboardShortcut("?", modifiers: [.command])
                Divider()
                TermsMenuItem()   // View terms of use (a language-switchable read-only viewer)
            }
            CommandMenu(L("menu.sandbox")) {
                Button(L("menu.stop")) { runner.stop() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!runner.isRunning)
                Divider()
                Button(L("menu.rebuild")) { admin.requestRebuild(runner: runner) }
                    .disabled(admin.busy || admin.rebuildMode)
                Button(L("menu.destroy")) { admin.requestDestroy(runner: runner) }
                    .disabled(admin.busy || !admin.hasBaseline())
            }
        }

        // 'About' dialog (App menu › About macSandbox for Windows)
        Window(L("about.windowTitle"), id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()   // Not exposed in the Window menu list

        // 'Terms of Use' viewer (opened from the Help menu — language-switchable)
        Window(L("consent.title"), id: "terms") {
            TermsViewerView()
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
        .commandsRemoved()

        // 'Options' dialog (App menu › Settings…, ⌘,)
        Settings {
            OptionsView()
        }
    }
}

/// The '… Info' item in the App menu — opens the custom AboutView window instead of the standard About panel.
private struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(L("about.menu")) { openWindow(id: "about") }
    }
}

/// The 'View Terms of Use' item in the Help menu — opens the language-switchable terms viewer window.
private struct TermsMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(L("menu.terms")) { openWindow(id: "terms") }
    }
}

/// The sandbox configuration determined at launch time (parsed from CLI/`.wsb`, read by the GUI).
/// If the baseline is ready, the GUI starts the sandbox immediately with this configuration.
final class AppLaunch {
    static let shared = AppLaunch()

    /// Sandbox configuration (default = options-based). Overridden by CLI/`.wsb`.
    private(set) var config = SandboxConfig()
    /// The configuration **explicitly specified** via CLI/`.wsb` (or loading a .wsb while running). If nil, the options defaults are used.
    private(set) var explicitConfig: SandboxConfig?
    /// A note to show the user during parsing (errors, etc.).
    private(set) var note: String?

    /// Loading a `.wsb` while running switches to an explicit configuration (keeps this configuration instead of the options defaults).
    func markExplicit(_ c: SandboxConfig) { explicitConfig = c }

    /// The configuration to use for the next sandbox start. If there is no explicit configuration, it is recomputed from the options each time
    /// (changes in the options dialog apply from the next start).
    func effectiveConfig() -> SandboxConfig { explicitConfig ?? AppOptions.makeDefaultConfig() }

    func configure(from args: [String]) {
        var c = AppOptions.makeDefaultConfig()   // Unspecified items follow the options defaults
        var explicit = false
        var notes: [String] = []

        func loadWSB(_ path: String) {
            do { c = try WSBConfig.load(path: path); explicit = true }
            catch { notes.append(error.localizedDescription) }
        }

        var i = 1
        while i < args.count {
            let a = args[i]
            let next: String? = (i + 1 < args.count) ? args[i + 1] : nil
            func consume() { i += 1 }   // Consume one value
            switch a {
            case "--run":
                break   // For compatibility — the GUI always starts immediately
            case "--wsb":
                if let p = next { loadWSB(p); consume() }
            case "--memory", "--memory-mb":
                if let v = next, let m = Int(v) { c.memoryMB = m; explicit = true; consume() }
            case "--cpus", "--cpu", "--cores":
                if let v = next, let n = Int(v) { c.cpuCores = n; explicit = true; consume() }
            case "--networking", "--network", "--net":
                if let v = next { c.networkingEnabled = WSBConfig.boolFlag(v); explicit = true; consume() }
            case "--vgpu", "--gpu":
                if let v = next { c.vGpuEnabled = WSBConfig.boolFlag(v); explicit = true; consume() }
            case "--clipboard":
                if let v = next { c.clipboardEnabled = WSBConfig.boolFlag(v); explicit = true; consume() }
            case "--audio", "--microphone", "--mic":
                if let v = next { c.audioInputEnabled = WSBConfig.boolFlag(v); explicit = true; consume() }
            case "--printer":
                if let v = next { c.printerEnabled = WSBConfig.boolFlag(v); explicit = true; consume() }
            case "--folder", "--map":
                if let v = next { c.mappedFolders.append(Self.parseFolder(v)); explicit = true; consume() }
            case "--logon", "--logon-command":
                if let v = next { c.logonCommand = v; explicit = true; consume() }
            default:
                if a.lowercased().hasSuffix(".wsb") { loadWSB(a) }
            }
            i += 1
        }

        self.config = c
        self.explicitConfig = explicit ? c : nil
        self.note = notes.isEmpty ? nil : notes.joined(separator: "\n")

        // If the configuration was specified via CLI/.wsb, print summary feedback to the terminal (the GUI shows it separately).
        if args.count > 1 {
            var out = "[MacSandbox] Sandbox configuration (starts immediately once the baseline is ready):\n"
            for (k, v) in WSBConfig.summaryLines(c) { out += "  \(k): \(v)\n" }
            if let n = self.note { out += "  ⚠️ \(n)\n" }
            FileHandle.standardError.write(Data(out.utf8))
        }
    }

    /// `--folder <path>[:ro]` → MappedFolder
    private static func parseFolder(_ spec: String) -> MappedFolder {
        var path = spec
        var readOnly = false
        if spec.lowercased().hasSuffix(":ro") {
            path = String(spec.dropLast(3)); readOnly = true
        } else if spec.lowercased().hasSuffix(":rw") {
            path = String(spec.dropLast(3))
        }
        return MappedFolder(hostPath: (path as NSString).expandingTildeInPath, readOnly: readOnly)
    }
}

/// Headless 1-round build runner (for CLI/verification)
enum HeadlessRunner {
    static func run(isoPathArg: String?) {
        let isoPath = isoPathArg ?? SandboxPaths.defaultISO.path
        guard FileManager.default.fileExists(atPath: isoPath) else {
            FileHandle.standardError.write(Data("ISO not found: \(isoPath)\n".utf8))
            exit(2)
        }
        // A CLI notice corresponding to the GUI's license checklist (the automation path only notices, without a consent step).
        print("""
        [MacSandbox] NOTICE: This tool does not provide Windows, a product key, or any usage \
        rights. One Windows license covers one instance on one device (physical or virtual); \
        OEM licenses are generally not usable in a VM. You are solely responsible for EULA \
        and activation compliance.
        """)
        print("[MacSandbox] Headless baseline build started — ISO: \(isoPath)")

        // Run the build on a main-actor Task. Keep the main thread alive with a RunLoop
        // so @MainActor work and QEMU output callbacks are processed. On completion, the Task calls exit().
        Task { @MainActor in
            let builder = BaselineBuilder()
            builder.logHandler = { line in print("  \(line)") }
            let config = InstallConfig(isoPath: isoPath)
            await builder.build(config: config, headless: true)
            if case .completed = builder.phase {
                print("[MacSandbox] ✅ Done")
                exit(0)
            } else {
                print("[MacSandbox] ❌ \(builder.phase.label)")
                exit(1)
            }
        }

        RunLoop.main.run()
    }
}
