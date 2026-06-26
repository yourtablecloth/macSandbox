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

/// Keyboard layout option — determines the RDP client keyboard identification (type/subtype/layout).
/// Guest Windows uses this identification to pick the session keyboard driver and map special keys like 한/영 (right Alt).
enum KeyboardLayoutOption: String, CaseIterable, Identifiable {
    case auto, us, korean, japanese
    var id: String { rawValue }

    var label: String { L("options.kbd.\(rawValue)") }

    /// (type, subtype, layout). If 0, use the FreeRDP default.
    /// Korean 101-key Type A (8,3,0x412): right Alt=한/영, right Ctrl=Hanja. Japanese 106-key (7,2,0x411).
    var rdpValues: (type: Int32, subtype: Int32, layout: Int32) {
        switch self {
        case .auto:
            let lang = Locale.preferredLanguages.first ?? ""
            if lang.hasPrefix("ko") { return (8, 3, 0x412) }
            if lang.hasPrefix("ja") { return (7, 2, 0x411) }
            return (0, 0, 0)
        case .us: return (4, 0, 0x409)
        case .korean: return (8, 3, 0x412)
        case .japanese: return (7, 2, 0x411)
        }
    }
}

/// Persistent settings for the 'Options' dialog (Settings). Shares UserDefaults keys with @AppStorage (UI),
/// and here provides read-only access + computing a default SandboxConfig based on the options.
enum AppOptions {
    // General
    static let kLanguage = "general.language"   // AppLanguage rawValue ("auto"=follow OS setting)
    // Input/output
    static let kKeyboardLayout = "input.keyboardLayout"
    static let kAudioPlayback = "audio.playback"
    static let kHiDPI = "display.hidpi"
    // Default sandbox configuration (when not specified by .wsb/CLI)
    static let kNetworking = "sandbox.networking"
    static let kClipboard = "sandbox.clipboard"
    static let kAudioInput = "sandbox.audioInput"
    static let kPrinter = "sandbox.printer"
    static let kVGpu = "sandbox.vgpu"
    static let kMemoryMB = "sandbox.memoryMB"
    static let kCpuCores = "sandbox.cpuCores"

    private static var d: UserDefaults { .standard }
    private static func bool(_ key: String, default def: Bool) -> Bool {
        d.object(forKey: key) == nil ? def : d.bool(forKey: key)
    }
    private static func int(_ key: String, default def: Int) -> Int {
        d.object(forKey: key) == nil ? def : d.integer(forKey: key)
    }

    static var keyboardLayout: KeyboardLayoutOption {
        KeyboardLayoutOption(rawValue: d.string(forKey: kKeyboardLayout) ?? "") ?? .auto
    }
    static var audioPlayback: Bool { bool(kAudioPlayback, default: true) }
    static var hiDPI: Bool { bool(kHiDPI, default: true) }

    /// Default sandbox configuration based on the options. Computed at every sandbox start when no `.wsb`/CLI switch is present.
    static func makeDefaultConfig() -> SandboxConfig {
        var c = SandboxConfig()
        c.networkingEnabled = bool(kNetworking, default: c.networkingEnabled)
        c.clipboardEnabled = bool(kClipboard, default: c.clipboardEnabled)
        c.audioInputEnabled = bool(kAudioInput, default: c.audioInputEnabled)
        c.printerEnabled = bool(kPrinter, default: c.printerEnabled)
        c.vGpuEnabled = bool(kVGpu, default: c.vGpuEnabled)
        c.memoryMB = int(kMemoryMB, default: c.memoryMB)
        c.cpuCores = int(kCpuCores, default: c.cpuCores)
        return c
    }
}
