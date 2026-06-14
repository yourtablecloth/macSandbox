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

/// '옵션' 대화상자 (메뉴: macSandbox for Windows › Settings…, ⌘,).
/// UserDefaults(@AppStorage) 영속 — AppOptions와 키를 공유한다.
/// 샌드박스 기본 구성은 **다음 샌드박스 시작**, 입력/출력은 **다음 RDP 연결**부터 적용.
struct OptionsView: View {
    var body: some View {
        TabView {
            GeneralOptionsTab()
                .tabItem { Label(L("options.tab.general"), systemImage: "gearshape") }
            SandboxOptionsTab()
                .tabItem { Label(L("options.tab.sandbox"), systemImage: "shippingbox") }
            InputOutputOptionsTab()
                .tabItem { Label(L("options.tab.io"), systemImage: "keyboard") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

/// 일반 — 앱 표시 언어 + 사용 약관 동의(상태 표시 / 약관 보기 / 철회).
private struct GeneralOptionsTab: View {
    @AppStorage(AppOptions.kLanguage) private var language = AppLanguage.auto.rawValue
    @Environment(\.openWindow) private var openWindow
    @State private var agreedVersion: String? = ConsentStore.agreedVersion
    @State private var agreedAt: Date? = ConsentStore.agreedAtDate
    @State private var confirmWithdraw = false

    var body: some View {
        Form {
            Section {
                Picker(L("options.language"), selection: $language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.label).tag(lang.rawValue)
                    }
                }
            } footer: {
                Text(L("options.language.note")).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text(statusText).foregroundStyle(.secondary)
                Button(L("menu.terms")) { openWindow(id: "terms") }
                Button(L("options.terms.withdraw"), role: .destructive) { confirmWithdraw = true }
                    .disabled(agreedVersion == nil)
            } header: {
                Text(L("consent.title"))
            } footer: {
                Text(L("options.terms.note")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshConsent)
        .alert(L("options.terms.withdraw.title"), isPresented: $confirmWithdraw) {
            Button(L("common.cancel"), role: .cancel) { }
            Button(L("options.terms.withdraw.confirm"), role: .destructive) {
                ConsentStore.withdraw()
                refreshConsent()
            }
        } message: {
            Text(L("options.terms.withdraw.message"))
        }
    }

    private func refreshConsent() {
        agreedVersion = ConsentStore.agreedVersion
        agreedAt = ConsentStore.agreedAtDate
    }

    private var statusText: String {
        guard let v = agreedVersion else { return L("options.terms.notAgreed") }
        let date = agreedAt?.formatted(date: .abbreviated, time: .shortened) ?? ""
        return L("options.terms.agreed", v, date)
    }
}

/// 기본 샌드박스 구성 — `.wsb`/CLI 미지정 시 새 샌드박스에 적용되는 기본값.
private struct SandboxOptionsTab: View {
    @AppStorage(AppOptions.kMemoryMB) private var memoryMB = SandboxConfig.defaultMemoryMB
    @AppStorage(AppOptions.kCpuCores) private var cpuCores = SandboxConfig.defaultCPUCores
    @AppStorage(AppOptions.kNetworking) private var networking = true
    @AppStorage(AppOptions.kClipboard) private var clipboard = true
    @AppStorage(AppOptions.kAudioInput) private var audioInput = true
    @AppStorage(AppOptions.kPrinter) private var printer = false
    @AppStorage(AppOptions.kVGpu) private var vgpu = false

    private var hostMemoryMB: Int { Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024)) }
    private var maxMemoryMB: Int { max(4096, hostMemoryMB - 4096) }
    private var maxCores: Int { max(2, ProcessInfo.processInfo.activeProcessorCount - 2) }

    var body: some View {
        Form {
            Section {
                Stepper(value: $memoryMB, in: 4096...maxMemoryMB, step: 1024) {
                    HStack {
                        Text(L("options.memory"))
                        Spacer()
                        Text(String(format: "%.0f GB", Double(memoryMB) / 1024))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Stepper(value: $cpuCores, in: 2...maxCores) {
                    HStack {
                        Text(L("options.cpus"))
                        Spacer()
                        Text("\(cpuCores)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            Section {
                Toggle(L("options.networking"), isOn: $networking)
                Toggle(L("options.clipboard"), isOn: $clipboard)
                Toggle(L("options.audioInput"), isOn: $audioInput)
                Toggle(L("options.printer"), isOn: $printer)
                Toggle(L("options.vgpu"), isOn: $vgpu)
            } footer: {
                Text(L("options.sandbox.note")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// 입력/출력 — 키보드 식별(한/영 전환), 오디오 재생, HiDPI.
private struct InputOutputOptionsTab: View {
    @AppStorage(AppOptions.kKeyboardLayout) private var keyboardLayout =
        KeyboardLayoutOption.auto.rawValue
    @AppStorage(AppOptions.kAudioPlayback) private var audioPlayback = true
    @AppStorage(AppOptions.kHiDPI) private var hidpi = true

    var body: some View {
        Form {
            Section {
                Picker(L("options.kbdLayout"), selection: $keyboardLayout) {
                    ForEach(KeyboardLayoutOption.allCases) { opt in
                        Text(opt.label).tag(opt.rawValue)
                    }
                }
            } footer: {
                Text(L("options.kbd.note")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("options.audioPlayback"), isOn: $audioPlayback)
                Toggle(L("options.hidpi"), isOn: $hidpi)
            } footer: {
                Text(L("options.io.note")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
