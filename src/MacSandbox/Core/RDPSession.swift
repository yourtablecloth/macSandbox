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
import Darwin

/// FreeRDP(sdl-freerdp)-based sandbox interaction session.
///
/// RDP hybrid: boot monitoring is done via the VNC console, and user interaction via the FreeRDP window.
/// FreeRDP provides shared-folder (`/drive`), clipboard (`+clipboard`), microphone (`/microphone`),
/// printer (`/printer`), and audio output (`/sound`) redirection.
/// (Webcam redirection is unsupported in this FreeRDP build — no RDPECAM channel.)
@MainActor
final class RDPSession {

    private var process: Process?
    private(set) var port: Int = 0

    /// Guest RDP server logon account (the baseline is configured with WDAGUtilityAccount auto-logon / RDP allowed)
    static let user = "WDAGUtilityAccount"

    // MARK: - Port reservation

    /// Find a bindable (available) TCP port on 127.0.0.1. Search starting from 13389 by default.
    static func reserveLocalPort(preferred: Int = 13389) -> Int {
        for candidate in preferred..<(preferred + 64) {
            if isPortFree(candidate) { return candidate }
        }
        return preferred
    }

    private static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    // MARK: - Argument build

    /// SandboxConfig → FreeRDP arguments. Auto-logs on via blank-password RDP (NLA off).
    static func buildArgs(config: SandboxConfig, port: Int) -> [String] {
        var args: [String] = []
        args.append("/v:127.0.0.1:\(port)")
        args.append("/u:\(SandboxCreds.username)")
        args.append("/p:\(SandboxCreds.password)")  // fixed internal password — reliable credential auto-logon
        args.append("/sec:tls")             // TLS security — the server rejects RDP-only with SSL_REQUIRED, and this bypasses NLA
        args.append("/cert:ignore")
        // Open in a fixed-size window. Avoid /dynamic-resolution because on the SDL client it triggers a
        // fullscreen transition that opens at the full display size and then shrinks. Use +smart-sizing to scale on window resize.
        args.append("/w:1440")
        args.append("/h:900")
        args.append("+smart-sizing")
        args.append("/title:MacSandbox")

        // Clipboard
        if config.clipboardEnabled { args.append("+clipboard") } else { args.append("-clipboard") }

        // Shared folders — each mapping as a named drive. Appears in the guest as \\tsclient\<name> or a redirected drive.
        for (idx, folder) in config.mappedFolders.enumerated() where !folder.hostPath.isEmpty {
            let name = shareName(for: folder, index: idx)
            args.append("/drive:\(name),\(folder.hostPath)")
        }

        // Microphone (audio input) + audio output
        if config.audioInputEnabled {
            args.append("/microphone")
            args.append("/sound")
        }

        // Printer redirection
        if config.printerEnabled { args.append("/printer") }

        return args
    }

    /// RDP share name for a mapped folder (the name shown in the guest). Based on the host folder name, with an index appended on collision.
    private static func shareName(for folder: MappedFolder, index: Int) -> String {
        let base = (folder.hostPath as NSString).lastPathComponent
        let cleaned = base.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        return cleaned.isEmpty ? "Shared\(index + 1)" : cleaned
    }

    // MARK: - Execution

    private var stopped = false

    /// Run FreeRDP once and return its exit code (awaits until the process terminates).
    /// - onConnected: Called once when the actual RDP session is established (dynamic channel load). Signals the boot-screen → RDP transition.
    func run(config: SandboxConfig, port: Int,
             onLog: @escaping (String) -> Void,
             onConnected: (() -> Void)? = nil) async throws -> Int32 {
        guard let bin = SandboxPaths.freerdpBinary() else {
            throw BuildError.installFailed("FreeRDP (sdl-freerdp) not found. Run `brew install freerdp` and try again.")
        }
        self.port = port
        let args = Self.buildArgs(config: config, port: port)
        onLog("FreeRDP: \(bin.lastPathComponent) \(args.joined(separator: " "))")

        let proc = Process()
        proc.executableURL = bin
        proc.arguments = args
        let out = Pipe(); let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        // Session-established detection: when a dynamic virtual channel load line (rdpgfx, etc.) appears, treat it as connected.
        let connected = OneShotFlag()
        let sink: (String) -> Void = { t in
            onLog("[rdp] \(t)")
            if let onConnected,
               t.contains("Loading Dynamic Virtual Channel") || t.contains("rdpgfx") {
                if connected.set() { onConnected() }
            }
        }
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty, let s = String(data: d, encoding: .utf8) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { sink(t) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty, let s = String(data: d, encoding: .utf8) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { sink(t) }
            }
        }

        self.process = proc
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            let once = OneShotFlag()
            proc.terminationHandler = { p in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                if once.set() { cont.resume(returning: p.terminationStatus) }
            }
            do {
                try proc.run()
            } catch {
                if once.set() { cont.resume(throwing: error) }
            }
        }
    }

    /// Force-quit the FreeRDP window. Sets the stopped flag so any subsequent retry loop halts.
    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    var isStopped: Bool { stopped }
    var isRunning: Bool { process?.isRunning ?? false }
}
