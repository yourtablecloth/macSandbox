// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (C) 2026 Nam Jung Hyun (rkttu) <rkttu.official@gmail.com>
//
// This file is part of MacSandbox, which is dual-licensed:
//   (1) under the GNU General Public License v3.0 or later (see LICENSE), or
//   (2) under a commercial license (see COMMERCIAL-LICENSE.md).
// You may use this file under the terms of either license.
//
// MacSandbox is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 샌드박스 실행 화면. 베이스라인이 준비되면 라우터가 곧바로 시작한다.
///
/// - 실행 중: **인앱 임베드 RDP 뷰**가 창을 채운다(외부 FreeRDP 창 없음). 첫 프레임 전엔
///   부팅 오버레이(상태/콘솔/로그)를 보여주고, RDP 화면이 그려지면 오버레이를 내린다.
/// - 종료 후: 다시 시작 / `.wsb` 불러오기.
struct SandboxView: View {
    @ObservedObject var runner: SandboxRunner
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
        runner.status == "종료됨" || runner.status.hasPrefix("실패")
    }

    // MARK: - 실행 중 (임베드 RDP 뷰)

    private var runningView: some View {
        ZStack {
            // 타이틀바 아래 콘텐츠 영역을 채운다(ignoresSafeArea로 타이틀바까지 확장하면 상단이 가려짐).
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
            // 종료는 메뉴(샌드박스 › 샌드박스 종료 ⌘.) · 창 닫기 · ⌘Q로 제어한다(플로팅 버튼 제거).
        }
    }

    /// 부팅 오버레이 — 첫 RDP 프레임이 그려질 때까지 표시.
    private var bootOverlay: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Spacer()
                ProgressView().controlSize(.large)
                Text("샌드박스 부팅 중").font(.title2).fontWeight(.semibold)
                Text(runner.status).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Windows 부팅 후 인앱 화면에 RDP가 연결됩니다.")
                    .font(.caption).foregroundStyle(.secondary)

                DisclosureGroup(isExpanded: $showDetails) {
                    detailPane.padding(.top, 8)
                } label: {
                    Text("더 보기 (부팅 모니터·로그)").font(.callout)
                }
                .frame(maxWidth: 640)
                Spacer()
            }
            .padding(28)
        }
    }

    /// 콘솔(부팅 모니터) + 로그
    private var detailPane: some View {
        VStack(spacing: 10) {
            if let console = runner.console {
                GroupBox("VM 콘솔 (부팅 모니터)") {
                    VMConsoleView(console: console).padding(6)
                }
            }
            logView
        }
    }

    // MARK: - 시작 직전

    private var startingView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("샌드박스를 시작합니다...").font(.title3).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - 종료 후

    private var endedView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: isFailure ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(isFailure ? .orange : .secondary)
            Text(isFailure ? runner.status : "샌드박스 종료됨").font(.title3).fontWeight(.medium)
            Text("일회용 환경의 변경사항은 폐기되었습니다.").font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button { Task { await runner.start(config: config) } } label: {
                    Label("새 샌드박스 시작", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button { loadWSB() } label: {
                    Label("구성(.wsb)...", systemImage: "doc.badge.gearshape")
                }
                .controlSize(.large)
            }

            DisclosureGroup("로그") { logView.padding(.top, 6) }
                .frame(maxWidth: 640)
            Spacer()
        }
    }

    private var isFailure: Bool { runner.status.hasPrefix("실패") }

    // MARK: - 공통

    private var logView: some View {
        GroupBox("로그") {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(runner.log.isEmpty ? "(출력 없음)" : runner.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("logbottom")
                }
                .frame(height: 160)
                .onChange(of: runner.log) { _, _ in proxy.scrollTo("logbottom", anchor: .bottom) }
            }
            .padding(6)
        }
    }

    // MARK: - .wsb 불러오기

    private func loadWSB() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let wsbType = UTType(filenameExtension: "wsb") {
            panel.allowedContentTypes = [wsbType, .xml]
        }
        panel.message = "샌드박스 구성(.wsb) 파일을 선택하세요"
        if panel.runModal() == .OK, let url = panel.url,
           let parsed = try? WSBConfig.load(path: url.path) {
            config = parsed
        }
    }
}
