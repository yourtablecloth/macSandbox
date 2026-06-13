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

/// 샌드박스 실행 화면. 베이스라인이 준비되면 라우터가 곧바로 시작한다.
///
/// - 실행 중: **인앱 임베드 RDP 뷰**가 창을 채운다(외부 FreeRDP 창 없음). 첫 프레임 전엔
///   부팅 오버레이(상태/경과 시간/콘솔/로그)를 보여주고, RDP 화면이 그려지면 오버레이를 내린다.
/// - 종료 후: 다시 시작 / `.wsb` 불러오기 / 베이스라인 재구축·파기.
struct SandboxView: View {
    @ObservedObject var runner: SandboxRunner
    @ObservedObject var admin: BaselineAdmin
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
        if case .failed = runner.state { return true }
        return runner.state == .ended
    }

    private var isFailure: Bool {
        if case .failed = runner.state { return true }
        return false
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
                Text(L("run.boot.title")).font(.title2).fontWeight(.semibold)
                Text(runner.status).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let startedAt = runner.bootStartedAt {
                    BootElapsedLabel(startedAt: startedAt)
                }
                Text(L("run.boot.hint"))
                    .font(.caption).foregroundStyle(.secondary)

                DisclosureGroup(isExpanded: $showDetails) {
                    detailPane.padding(.top, 8)
                } label: {
                    Text(L("run.boot.details")).font(.callout)
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
                GroupBox(L("run.console.title")) {
                    VMConsoleView(console: console).padding(6)
                }
            }
            LogPane(buffer: runner.logBuffer)
        }
    }

    // MARK: - 시작 직전

    private var startingView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(L("run.starting")).font(.title3).foregroundStyle(.secondary)
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
            Text(isFailure ? runner.status : L("run.ended.title")).font(.title3).fontWeight(.medium)
            Text(L("run.ended.discarded")).font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button { Task { await runner.start(config: config) } } label: {
                    Label(L("run.startNew"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button { loadWSB() } label: {
                    Label(L("run.loadWSB"), systemImage: "doc.badge.gearshape")
                }
                .controlSize(.large)
            }

            // 베이스라인 관리 — 재구축(설치 다시 실행) / 파기(베이스 이미지 삭제)
            HStack(spacing: 10) {
                Button { admin.requestRebuild(runner: runner) } label: {
                    Label(L("ended.rebuild"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(admin.busy)
                Button(role: .destructive) { admin.requestDestroy(runner: runner) } label: {
                    Label(L("ended.destroy"), systemImage: "trash")
                }
                .disabled(admin.busy)
            }
            .controlSize(.small)

            DisclosureGroup(L("common.log")) {
                LogPane(buffer: runner.logBuffer).padding(.top, 6)
            }
            .frame(maxWidth: 640)
            Spacer()
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
        panel.message = L("run.wsb.panel")
        if panel.runModal() == .OK, let url = panel.url {
            // Finder 파일 연결과 동일 경로 — 파싱 성공 시 ContentView가 곧바로 새 샌드박스를
            // 시작하고, 실패 시 오류를 표시한다.
            OpenWSB.shared.open([url])
        }
    }
}

/// 부팅 경과 시간 라벨 — 1초마다 TimelineView만 갱신돼 오버레이 전체 재렌더를 피한다.
private struct BootElapsedLabel: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
            Text(L("run.boot.elapsed", String(format: "%d:%02d", seconds / 60, seconds % 60)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
