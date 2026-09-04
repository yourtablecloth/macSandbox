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

/// Disposable sandbox run orchestrator.
///
/// baseline → COW overlay + fresh UEFI variables → (config disk) → QEMU boot →
/// user usage → on exit, if disposable, discard the overlay/variables/config disk.
/// Sandbox run state. View routing/display is decided by this enum rather than string comparison (i18n-safe).
enum SandboxRunState: Equatable {
    case idle
    case preparing
    case booting
    case ended
    case failed(String)

    var label: String {
        switch self {
        case .idle: return L("run.state.idle")
        case .preparing: return L("run.state.preparing")
        case .booting: return L("run.state.booting")
        case .ended: return L("run.state.ended")
        case .failed(let reason): return L("run.state.failed", reason)
        }
    }
}

@MainActor
final class SandboxRunner: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var state: SandboxRunState = .idle
    /// Boot start time (for elapsed-time display). Set when entering the booting state.
    @Published private(set) var bootStartedAt: Date?
    @Published var console: VMConsole?
    /// Logs go in a separate throttling store — kept apart so views observing the runner don't re-render on every log line.
    let logBuffer = LogBuffer()

    var status: String { state.label }
    /// Current RDP forwarding port (127.0.0.1:rdpPort → guest 3389). 0 means unset.
    /// The in-app embedded RDP view (RDPHostView) connects to this port.
    @Published private(set) var rdpPort: Int = 0
    /// The configuration currently running (reflects the .wsb). Used by the RDP view to gate redirection features.
    @Published private(set) var activeConfig = SandboxConfig()
    @Published private(set) var rdpPassword = ""

    private let disk = DiskService()
    private let runtime = QEMURuntime()
    private let fm = FileManager.default

    func hasBaseline() -> Bool {
        guard let data = try? Data(contentsOf: SandboxPaths.baselineMetadataPath),
              let meta = try? JSONDecoder.iso8601.decode(BaselineMetadata.self, from: data) else { return false }
        return meta.schemaVersion == BaselineMetadata.currentSchemaVersion
            && meta.status == .ready
            && fm.fileExists(atPath: meta.diskPath)
            && (try? BaselineCredentialStore.password(for: meta.credentialID)) != nil
    }

    // MARK: - Execution

    func start(config: SandboxConfig) async {
        guard !isRunning else { return }
        guard let data = try? Data(contentsOf: SandboxPaths.baselineMetadataPath),
              let meta = try? JSONDecoder.iso8601.decode(BaselineMetadata.self, from: data),
              meta.schemaVersion == BaselineMetadata.currentSchemaVersion,
              meta.status == .ready else {
            state = .failed(L("run.state.noBaseline"))
            return
        }
        do {
            rdpPassword = try BaselineCredentialStore.password(for: meta.credentialID)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        activeConfig = config
        isRunning = true
        logBuffer.clear()
        defer {
            rdpPassword = ""
            isRunning = false
        }

        let id = String(UUID().uuidString.prefix(8))
        let overlayPath = SandboxPaths.overlaysDir.appendingPathComponent("\(id).qcow2").path
        let efiVarsPath = SandboxPaths.overlaysDir.appendingPathComponent("\(id)-efi.fd").path
        var configDiskPath: String?

        do {
            try SandboxPaths.ensureBaseDirectories()
            cleanStaleOverlays()   // clean up disposable overlays left over from a previous force-quit (assumes a single instance)

            // 1. COW overlay + fresh UEFI variables (qemu-img — off the main thread)
            state = .preparing
            let diskService = disk
            let basePath = meta.diskPath
            try await Task.detached(priority: .userInitiated) {
                try diskService.createOverlay(basePath: basePath, overlayPath: overlayPath)
            }.value
            guard let efiCode = SandboxPaths.edk2CodeFirmware(),
                  let varsTemplate = SandboxPaths.edk2VarsTemplate() else {
                throw BuildError.installFailed(L("error.firmwareNotFound"))
            }
            try fm.copyItem(atPath: varsTemplate.path, toPath: efiVarsPath)
            appendLog("COW overlay: \(overlayPath)")

            // 2. (Optional) config disk — auto-mount shared folders (mklink) + deliver LogonCommand.
            //    hdiutil/newfs/diskutil synchronous work (a few seconds) — off the main thread.
            if !config.logonCommand.isEmpty || !config.mappedFolders.isEmpty {
                let path = SandboxPaths.overlaysDir.appendingPathComponent("\(id)-cfg.img").path
                let script = buildLogonScript(config: config)
                try await Task.detached(priority: .userInitiated) {
                    try Self.makeConfigDisk(script: script, at: path)
                }.value
                configDiskPath = path
                appendLog("Config disk: \(config.mappedFolders.count) mount(s), logon command \(config.logonCommand.isEmpty ? "absent" : "present")")
            }

            // 3. Run QEMU (VNC console for boot monitoring) + RDP port forwarding
            state = .booting
            bootStartedAt = Date()
            let qmpSocket = "/tmp/msbx-run-\(id).sock"
            let port = RDPSession.reserveLocalPort()
            self.rdpPort = port
            let args = runtime.buildSandboxArguments(
                overlayPath: overlayPath, efiCodePath: efiCode.path, efiVarsPath: efiVarsPath,
                config: config, configDiskPath: configDiskPath, rdpHostPort: port, qmpSocketPath: qmpSocket)
            appendLog("RDP forwarding: 127.0.0.1:\(port) → guest 3389")

            let console = VMConsole(socketPath: qmpSocket, capturesFrames: true)
            self.console = console
            console.start()

            // Run QEMU in the background. Guest RDP is rendered by the in-app embedded view (RDPHostView),
            // which connects via rdpPort (no external FreeRDP window). The embedded engine waits for the guest
            // to boot and retries the connection, so no separate RDP launcher is needed.
            let qemuTask = Task { () -> Int32 in
                try await self.runtime.runUntilExit(
                    arguments: args, qmpSocketPath: qmpSocket, timeoutSeconds: 24 * 60 * 60
                ) { [weak self] out in
                    let me = self
                    Task { @MainActor in me?.appendLog(out) }
                }
            }

            // The sandbox runs until the user quits or the guest shuts down
            let exit = (try? await qemuTask.value) ?? -1
            console.stop()
            self.console = nil
            self.rdpPort = 0
            appendLog("QEMU exited (exit=\(exit))")
            state = .ended
        } catch {
            console?.stop()
            console = nil
            state = .failed(error.localizedDescription)
            appendLog("❌ \(error.localizedDescription)")
        }
        bootStartedAt = nil

        // 4. Disposable cleanup
        if config.disposable {
            try? fm.removeItem(atPath: overlayPath)
            try? fm.removeItem(atPath: efiVarsPath)
            if let configDiskPath { try? fm.removeItem(atPath: configDiskPath) }
            appendLog("Disposable: overlay/vars/config disk removed")
        }
    }

    /// Shut down the sandbox (it's disposable, so force-quitting is fine)
    func stop() {
        runtime.forceStop()
        appendLog("Stop requested")
    }

    // MARK: - Private

    /// Clean up leftover files in the disposable overlay directory. If the app is force-quit/crashes, the normal cleanup code
    /// doesn't run and overlays remain (the watchdog only kills QEMU), so empty it on the next start (assumes a single instance).
    private func cleanStaleOverlays() {
        let dir = SandboxPaths.overlaysDir
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for item in items {
            try? fm.removeItem(atPath: dir.appendingPathComponent(item).path)
        }
    }

    /// Build the body of macsandbox-logon.cmd that the baseline logon agent runs.
    /// Mounts the shared folders in the guest (mklink /D Desktop\leaf or SandboxFolder → \\tsclient\drive), then
    /// runs the user's LogonCommand (same order as Windows Sandbox: folder mapping → logon command).
    private func buildLogonScript(config: SandboxConfig) -> String {
        let mounts = config.resolvedMounts()
        var lines = ["@echo off"]
        for m in mounts {
            lines.append("call :mount \"\(m.driveName)\" \"\(m.guestLinkPath)\"")
        }
        if !config.logonCommand.isEmpty { lines.append(config.logonCommand) }
        if !mounts.isEmpty {
            // Subroutine: wait until the rdpdr drive is ready, then create a symlink (local→remote symlink evaluation is allowed by default).
            lines += [
                "goto :eof", "",
                ":mount", "setlocal",
                "set \"SRC=\\\\tsclient\\%~1\"",
                "set /a n=0",
                ":w",
                "if exist \"%SRC%\\\" goto :l",
                "set /a n+=1",
                "if %n% geq 20 goto :e",
                "ping -n 2 127.0.0.1 >nul",
                "goto :w",
                ":l",
                // Prefer a symlink (possible without elevation in Developer Mode → mounts like a folder). Fall back to a shortcut (.lnk) on failure.
                "if not exist \"%~2\" if not exist \"%~2.lnk\" mklink /D \"%~2\" \"%SRC%\" >nul 2>&1",
                "if not exist \"%~2\" if not exist \"%~2.lnk\" powershell -NoProfile -Command \"$s=(New-Object -ComObject WScript.Shell).CreateShortcut('%~2.lnk');$s.TargetPath='%SRC%';$s.Save()\"",
                ":e", "endlocal", "goto :eof",
            ]
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// VBScript launcher that runs the logon cmd in a hidden console (SW_HIDE).
    /// When the registry Run entry launches this vbs with wscript, it runs macsandbox-logon.cmd from its own drive
    /// windowlessly (0) and waits until it finishes (True) → the console stays hidden, like Windows Sandbox.
    nonisolated private static let logonVBS =
        "Dim p, d\r\n" +
        "p = WScript.ScriptFullName\r\n" +
        "d = Left(p, InStrRev(p, \"\\\"))\r\n" +
        "CreateObject(\"WScript.Shell\").Run \"cmd /c \"\"\" & d & \"macsandbox-logon.cmd\"\"\", 0, True\r\n"

    /// Create a small FAT16 config disk holding the logon script (read by the baseline logon agent).
    /// A pure function that only uses shell tools (hdiutil/newfs/diskutil) — called from a background task.
    nonisolated private static func makeConfigDisk(script: String, at path: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        guard fm.createFile(atPath: path, contents: nil) else {
            throw BuildError.installFailed("Failed to create config disk")
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: 8 * 1024 * 1024)
        try handle.close()

        let dev = try shellCapture("/usr/bin/hdiutil",
            ["attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", path])
            .split(separator: "\n").first.flatMap { $0.split(separator: " ").first.map(String.init) } ?? ""
        guard dev.hasPrefix("/dev/") else { throw BuildError.installFailed("Failed to attach config disk") }
        defer { _ = try? shell("/usr/bin/hdiutil", ["detach", "-force", dev]) }

        try shell("/sbin/newfs_msdos", ["-F", "16", "-v", "MSBXCFG", dev])
        _ = try shellCapture("/usr/sbin/diskutil", ["mount", dev])
        let info = try shellCapture("/usr/sbin/diskutil", ["info", dev])
        guard let mp = info.split(separator: "\n").first(where: { $0.contains("Mount Point") })?
            .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces), !mp.isEmpty else {
            throw BuildError.installFailed("Failed to mount config disk")
        }
        try script.write(toFile: (mp as NSString).appendingPathComponent("macsandbox-logon.cmd"),
                         atomically: true, encoding: .utf8)
        // Hidden console launcher — the registry Run entry launches this vbs with wscript to run the .cmd windowlessly.
        try logonVBS.write(toFile: (mp as NSString).appendingPathComponent("macsandbox-logon.vbs"),
                           atomically: true, encoding: .utf8)
        _ = try? shellCapture("/usr/sbin/diskutil", ["unmount", dev])
    }

    nonisolated private static func shell(_ path: String, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardError = Pipe(); p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
    }

    nonisolated private static func shellCapture(_ path: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func appendLog(_ m: String) {
        logBuffer.append(m)
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}
