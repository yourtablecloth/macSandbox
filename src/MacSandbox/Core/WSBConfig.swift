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

/// Windows Sandbox `.wsb` (XML) configuration file → SandboxConfig conversion + command-line switch parsing.
///
/// `.wsb` schema (Windows Sandbox-compatible): under `<Configuration>`,
/// `VGpu`/`Networking`/`AudioInput`/`VideoInput`/`ClipboardRedirection`/`PrinterRedirection`
/// (values: `Enable`|`Disable`|`Default`), `MemoryInMB`, `LogonCommand><Command`,
/// `MappedFolders><MappedFolder><HostFolder`/`ReadOnly`.
/// Starts from the Windows Sandbox standard defaults (`SandboxConfig()`) and overrides only the items specified in the file/switches.
/// (HostFolder is interpreted as a macOS host path.)
enum WSBConfig {

    enum WSBError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let r): return L("error.wsbUnreadable", r)
            }
        }
    }

    /// Read a `.wsb` file and convert it to a SandboxConfig.
    static func load(path: String) throws -> SandboxConfig {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else {
            throw WSBError.unreadable(url.path)
        }
        guard let doc = try? XMLDocument(data: data, options: []) else {
            throw WSBError.unreadable("XML parse failed: \(url.lastPathComponent)")
        }
        return parse(doc: doc)
    }

    /// XMLDocument → SandboxConfig (override only the specified items from the defaults)
    static func parse(doc: XMLDocument) -> SandboxConfig {
        var c = SandboxConfig()
        guard let root = doc.rootElement() else { return c }

        func text(_ name: String, in parent: XMLElement) -> String? {
            parent.elements(forName: name).first?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        /// Enable/Disable/Default tri-state. Default (or unspecified/unrecognized) → nil → keep the default value.
        func tri(_ name: String) -> Bool? {
            guard let v = text(name, in: root)?.lowercased() else { return nil }
            switch v {
            case "enable", "true", "1", "on", "yes": return true
            case "disable", "false", "0", "off", "no": return false
            default: return nil
            }
        }

        if let v = tri("VGpu") { c.vGpuEnabled = v }
        if let v = tri("Networking") { c.networkingEnabled = v }
        if let v = tri("AudioInput") { c.audioInputEnabled = v }
        if let v = tri("VideoInput") { c.videoInputEnabled = v }
        if let v = tri("ClipboardRedirection") { c.clipboardEnabled = v }
        if let v = tri("PrinterRedirection") { c.printerEnabled = v }
        if let m = text("MemoryInMB", in: root), let mb = Int(m) { c.memoryMB = mb }
        if let m = text("CpuCores", in: root), let n = Int(m) { c.cpuCores = n }  // extension (not in WS)

        if let lc = root.elements(forName: "LogonCommand").first,
           let cmd = text("Command", in: lc), !cmd.isEmpty {
            c.logonCommand = cmd
        }
        if let mf = root.elements(forName: "MappedFolders").first {
            for folder in mf.elements(forName: "MappedFolder") {
                guard let host = text("HostFolder", in: folder), !host.isEmpty else { continue }
                let ro = text("ReadOnly", in: folder)?.lowercased() == "true"
                let sandbox = text("SandboxFolder", in: folder) ?? ""  // if empty, auto-mount on the Desktop
                c.mappedFolders.append(MappedFolder(
                    hostPath: (host as NSString).expandingTildeInPath, readOnly: ro, sandboxPath: sandbox))
            }
        }
        return c
    }

    /// Parse a boolean switch value (on/off/true/false/enable/disable/1/0). On failure to recognize, true (present = on).
    static func boolFlag(_ s: String) -> Bool {
        switch s.lowercased() {
        case "off", "false", "0", "disable", "no", "n": return false
        default: return true
        }
    }

    /// Human-readable one-line summary (for UI/logs)
    static func summaryLines(_ c: SandboxConfig) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("Memory", "\(c.memoryMB) MB"),
            ("CPU cores", "\(c.cpuCores)"),
            ("Networking", c.networkingEnabled ? "on" : "off"),
            ("Clipboard", c.clipboardEnabled ? "on" : "off"),
            ("Audio/microphone", c.audioInputEnabled ? "on" : "off"),
            ("Printer", c.printerEnabled ? "on" : "off"),
            ("vGPU (console)", c.vGpuEnabled ? "virtio-gpu" : "ramfb"),
        ]
        if !c.mappedFolders.isEmpty {
            rows.append(("Shared folders", c.mappedFolders.map { ($0.hostPath as NSString).lastPathComponent }.joined(separator: ", ")))
        }
        if !c.logonCommand.isEmpty {
            rows.append(("Logon command", c.logonCommand))
        }
        return rows
    }
}
