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

/// Sandbox RDP account. Its per-baseline password is stored in macOS Keychain.
enum SandboxCreds {
    static let username = "WDAGUtilityAccount"
}

/// Disposable sandbox run settings. Corresponds to the Windows Sandbox `.wsb` schema.
///
/// **The defaults match the Windows Sandbox standard** (networking/clipboard/audio on, webcam/printer off).
/// They apply at the **sandbox runtime (every run)**, and redirection is handled by FreeRDP (RDP hybrid).
/// Detailed options are specified via the `.wsb` file / command-line switches rather than a GUI ([[WSBConfig]] / AppLaunch).
struct SandboxConfig: Codable, Equatable {

    /// Virtual GPU display device. **For the QEMU console (VNC boot monitor) only** — the user-facing screen is RDP (rdpgfx), so it has no effect there.
    /// on = virtio-gpu (2D, viogpudo), off = ramfb (driverless, stable default). The WS default is on, but here it is for the console, so off.
    var vGpuEnabled: Bool = false

    /// NAT networking (WS default on). on = virtio-net (NAT). The guest NetKVM driver is injected into the baseline.
    var networkingEnabled: Bool = true

    /// Host folder mappings (`.wsb` MappedFolders). Via RDP rdpdr drive redirection, only the specified folders are
    /// exposed to the guest as `\\tsclient\<folderName>` (read/write). readOnly is unsupported by FreeRDP drive (not enforced).
    var mappedFolders: [MappedFolder] = []

    /// Command to run in the guest right after logon (`.wsb` LogonCommand). Delivered by having the baseline logon agent
    /// run `macsandbox-logon.cmd` from the config disk.
    var logonCommand: String = ""

    /// Microphone input sharing (`.wsb` AudioInput, WS default on). Gates the embedded engine's `AudioCapture` (audin).
    /// Speaker playback (rdpsnd) has no `.wsb` toggle, so it is always on (same as Windows Sandbox).
    var audioInputEnabled: Bool = true

    /// Host webcam input sharing (WS default off). Unsupported because the current FreeRDP build has no RDPECAM channel.
    var videoInputEnabled: Bool = false

    /// Clipboard copy/sharing (`.wsb` ClipboardRedirection, WS default on). Gates the embedded engine's `RedirectClipboard`.
    var clipboardEnabled: Bool = true

    /// Printer redirection (`.wsb` PrinterRedirection, WS default off). Gates the embedded engine's `RedirectPrinters` (rdpdr+CUPS).
    var printerEnabled: Bool = false

    /// Memory size (MB). Proportional to host RAM but **at least 4GB** (Windows 11 ARM minimum).
    /// Clamped to [4GB, host-4GB] at runtime ([QEMURuntime]).
    var memoryMB: Int = SandboxConfig.defaultMemoryMB

    /// Number of CPU cores (an item not present in `.wsb`). Proportional to host cores but **at least 2** (MacBook Air baseline).
    /// Clamped to [2, host-2] at runtime ([QEMURuntime]). The user adjusts it via the CLI `--cpus`.
    var cpuCores: Int = SandboxConfig.defaultCPUCores

    /// Discard changes on exit (disposable). Defaults to true, same as Windows Sandbox.
    var disposable: Bool = true

    /// About half of host cores, [2, 8]. MacBook Air (8 cores) → 4, 16 cores → 8.
    /// Software DWM compositing needs cores, so allocate half (clamped to host-2 at runtime),
    /// but since this is a disposable sandbox the default cap is 8 (the user can raise it with --cpus if more is needed).
    static var defaultCPUCores: Int {
        max(2, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    /// About half of host RAM, [4GB, host-4GB]. 8GB Mac → 4GB, 16GB → 8GB, 32GB → 16GB.
    /// Always leaves at least 4GB for the host and guarantees the Windows 11 ARM minimum of 4GB.
    static var defaultMemoryMB: Int {
        let hostMB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        let cap = max(4096, hostMB - 4096)   // leave at least 4GB for the host
        return min(max(4096, hostMB / 2), cap)
    }

    /// Shared folder → guest exposure info. Drive name = folder leaf (a number on collision). The link path is
    /// the SandboxFolder absolute path if present, otherwise WDAGUtilityAccount's Desktop\leaf.
    /// A single computation point so the RDP rdpdr drive name and the logon mount use the same name.
    func resolvedMounts() -> [ResolvedMount] {
        var used = Set<String>()
        var result: [ResolvedMount] = []
        for f in mappedFolders where !f.hostPath.isEmpty {
            let leaf = (f.hostPath as NSString).lastPathComponent
            let base = leaf.isEmpty ? "share" : leaf
            var name = base
            var i = 2
            while used.contains(name.lowercased()) { name = "\(base)\(i)"; i += 1 }
            used.insert(name.lowercased())
            let link = f.sandboxPath.isEmpty
                ? "C:\\Users\\\(SandboxCreds.username)\\Desktop\\\(name)"
                : f.sandboxPath
            result.append(ResolvedMount(hostPath: f.hostPath, driveName: name,
                                        guestLinkPath: link, readOnly: f.readOnly))
        }
        return result
    }
}

/// Host ↔ guest folder mapping (`.wsb` MappedFolder)
struct MappedFolder: Codable, Equatable, Identifiable {
    var id = UUID()
    var hostPath: String
    var readOnly: Bool = false
    /// `.wsb` SandboxFolder (absolute path inside the guest). If empty, auto-mounts on WDAGUtilityAccount's Desktop
    /// under the folder leaf name. (Runtime only — not persistently serialized.)
    var sandboxPath: String = ""

    private enum CodingKeys: String, CodingKey { case hostPath, readOnly }
}

/// Guest exposure info for a shared folder (drive name / link path). Computed in one place so the RDP rdpdr drive name
/// and the logon mount use the same name.
struct ResolvedMount: Equatable {
    let hostPath: String       // host absolute path
    let driveName: String      // guest rdpdr drive name → \\tsclient\<driveName>
    let guestLinkPath: String  // symlink path to create in the guest (SandboxFolder or Desktop\leaf)
    let readOnly: Bool
}
