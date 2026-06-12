// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Nam Jung Hyun (rkttu) <rkttu.official@gmail.com>
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

/// 키보드 레이아웃 옵션 — RDP 클라이언트 키보드 식별(타입/서브타입/레이아웃)을 결정한다.
/// 게스트 Windows는 이 식별로 세션 키보드 드라이버를 골라 한/영(오른쪽 Alt) 등 특수 키를 매핑한다.
enum KeyboardLayoutOption: String, CaseIterable, Identifiable {
    case auto, us, korean, japanese
    var id: String { rawValue }

    var label: String { L("options.kbd.\(rawValue)") }

    /// (type, subtype, layout). 0이면 FreeRDP 기본값 사용.
    /// 한국어 101키 Type A(8,3,0x412): 오른쪽 Alt=한/영, 오른쪽 Ctrl=한자. 일본어 106키(7,2,0x411).
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

/// '옵션' 대화상자(Settings)의 영속 설정. UserDefaults 키를 @AppStorage(UI)와 공유하고,
/// 여기서는 읽기 전용 접근 + 옵션 기반 기본 SandboxConfig 산출을 제공한다.
enum AppOptions {
    // 일반
    static let kLanguage = "general.language"   // AppLanguage rawValue ("auto"=OS 설정 따름)
    // 입력/출력
    static let kKeyboardLayout = "input.keyboardLayout"
    static let kAudioPlayback = "audio.playback"
    static let kHiDPI = "display.hidpi"
    // 샌드박스 기본 구성(.wsb/CLI 미지정 시)
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

    /// 옵션 기반 기본 샌드박스 구성. `.wsb`/CLI 스위치가 없을 때 매 샌드박스 시작 시 산출된다.
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
