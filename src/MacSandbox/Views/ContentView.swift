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

/// 라우터 — 베이스라인이 없으면(또는 재구축 진입 시) 빌드 화면, 있으면 곧바로 샌드박스를 시작한다.
/// 실행 중에는 인앱 임베드 RDP 뷰가 창을 채운다(단일 창).
struct ContentView: View {
    @ObservedObject var runner: SandboxRunner   // 앱(App) 소유 — 메뉴 커맨드와 공유
    @ObservedObject var admin: BaselineAdmin    // 앱(App) 소유 — 재구축/파기 메뉴와 공유
    @ObservedObject private var openWSB = OpenWSB.shared   // .wsb 파일 열기(연결/버튼) 통지
    @StateObject private var builder = BaselineBuilder()
    @State private var baselineReady = false
    @State private var config: SandboxConfig = AppLaunch.shared.effectiveConfig()
    @State private var didAutoStart = false
    @State private var closeGuard = CloseGuard()
    @State private var wsbError: String?
    @State private var showConsent = ConsentStore.needsConsent

    var body: some View {
        Group {
            if baselineReady && !admin.rebuildMode {
                SandboxView(runner: runner, admin: admin, config: $config)
            } else {
                BuildView(builder: builder, admin: admin, canReturnToSandbox: baselineReady)
            }
        }
        .frame(minWidth: 680, minHeight: 600)
        .background(WindowAccessor { window in
            // 창 닫기 시 확인 다이얼로그(VM과 함께 종료)
            window?.delegate = closeGuard
        })
        .alert(L("wsb.error.title"), isPresented: Binding(
            get: { wsbError != nil }, set: { if !$0 { wsbError = nil } })
        ) {
            Button(L("common.ok")) { wsbError = nil }
        } message: {
            Text(wsbError ?? "")
        }
        .sheet(isPresented: $showConsent) {
            TermsConsentView {
                ConsentStore.recordAgreement()   // 동의 버전·시점 기록(UserDefaults + 감사 로그)
                showConsent = false
                proceedAfterConsent()
            }
        }
        .onAppear {
            AppHooks.shared.runner = runner   // 앱/창 종료 훅이 참조
            // 약관 동의 전엔 어떤 동작(샌드박스 자동 시작 등)도 하지 않는다.
            guard !ConsentStore.needsConsent else { showConsent = true; return }
            proceedAfterConsent()
        }
        .onChange(of: builder.phase) { _, p in
            if p == .completed {
                // 재구축 포함 — 빌드가 끝나면 곧바로 새 샌드박스로 진입한다.
                admin.leaveRebuildMode()
                didAutoStart = false
                refresh()
            }
        }
        .onChange(of: admin.rebuildMode) { _, rebuilding in
            if !rebuilding { didAutoStart = false }
            refresh()
        }
        .onChange(of: runner.isRunning) { _, running in
            // 임베드 RDP 뷰는 앱 창 안에서 렌더하므로 창을 내리지 않는다. 종료 시에만 갱신.
            if !running { refresh() }
        }
        .onChange(of: openWSB.token) { _, _ in handleOpenWSB() }
    }

    /// 약관 동의 후(또는 이미 동의된 상태) 정상 흐름 진입 — 자동 시작 + 런치 시 `.wsb` 오류 표시.
    private func proceedAfterConsent() {
        refresh()
        if let err = openWSB.errorMessage { wsbError = err }
    }

    /// 베이스라인이 준비돼 있으면 곧바로 샌드박스를 시작한다(최초 1회). 없으면 빌드 화면.
    /// 시작 구성은 effectiveConfig() — `.wsb`/CLI 명시 구성이 있으면 그것, 없으면 옵션 기본값.
    private func refresh() {
        guard !ConsentStore.needsConsent else { return }   // 동의 전엔 자동 시작 금지
        baselineReady = runner.hasBaseline()
        if !runner.isRunning {
            config = AppLaunch.shared.effectiveConfig()
        }
        if baselineReady, !admin.rebuildMode, !didAutoStart, !runner.isRunning {
            didAutoStart = true
            Task { await runner.start(config: config) }
        }
    }

    /// 실행 중(런타임)에 `.wsb`를 열었을 때: 파싱 실패면 오류, 성공이면 곧바로 새 샌드박스 시작
    /// (미실행 시). 베이스라인이 없거나 재구축 중이면 구성만 반영해 빌드 완료 후 자동 시작한다.
    /// 이미 실행 중이면 현재 세션을 지키고 구성만 갱신(다음 시작에 반영).
    private func handleOpenWSB() {
        guard !ConsentStore.needsConsent else { return }   // 동의 후 proceedAfterConsent가 처리
        if let err = openWSB.errorMessage { wsbError = err; return }
        guard let cfg = openWSB.pendingConfig else { return }
        config = cfg
        if baselineReady, !admin.rebuildMode, !runner.isRunning {
            Task { await runner.start(config: cfg) }
        }
    }
}

/// SwiftUI 뷰가 올라간 NSWindow 참조를 캡처한다(창을 화면에서 내리거나 다시 띄우기 위함).
/// 코디네이터로 창이 실제로 바뀔 때만 콜백해 재렌더 루프를 막는다.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { context.coordinator.update(v.window, onWindow) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.update(nsView.window, onWindow) }
    }
    final class Coordinator {
        weak var last: NSWindow?
        func update(_ w: NSWindow?, _ cb: (NSWindow?) -> Void) {
            guard w !== last else { return }
            last = w
            cb(w)
        }
    }
}

/// 베이스라인 자동 빌드 화면 (베이스라인이 없거나 재구축에 진입했을 때 표시)
///
/// 두 가지 모드로 화면을 단순하게 유지한다:
/// - **설정 모드**(빌드 전): ISO·에디션 선택 카드 + 빌드 버튼만.
/// - **설치 모드**(빌드 중): 입력 폼을 숨기고 진행 카드 + 부팅 모니터 + 로그만.
/// 빌드 시작 전에는 Windows 라이선스 확인 체크리스트 시트를 매번 표시한다.
struct BuildView: View {
    @ObservedObject var builder: BaselineBuilder
    @ObservedObject var admin: BaselineAdmin
    /// true면 준비된 베이스라인이 있는 재구축 모드 — 샌드박스로 돌아가기 버튼 표시.
    var canReturnToSandbox = false

    @State private var isoPath: String = ""
    @State private var imageEdition: String = "Windows 11 Pro"
    @State private var editions: [String] = []
    @State private var loadingEditions = false
    @State private var existing: BaselineMetadata?
    @State private var showLicenseChecklist = false

    private var canBuild: Bool {
        !builder.isRunning && !isoPath.isEmpty && FileManager.default.fileExists(atPath: isoPath)
            && !imageEdition.isEmpty && !loadingEditions
    }

    private var isFailed: Bool {
        if case .failed = builder.phase { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if builder.isRunning {
                    progressCard
                    if let console = builder.console { consoleCard(console) }
                    LogPane(buffer: builder.logBuffer, height: 150)
                } else {
                    if let existing { baselineCapsule(existing) }
                    setupCard
                    if isFailed { failureBanner }
                    buildButton
                    if isFailed { LogPane(buffer: builder.logBuffer, height: 150) }
                }
            }
            .padding(26)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)   // 중앙 정렬 컬럼
        }
        .sheet(isPresented: $showLicenseChecklist) {
            LicenseChecklistView {
                let config = InstallConfig(isoPath: isoPath, imageEdition: imageEdition)
                Task { await builder.build(config: config) }
            }
        }
        .onAppear {
            if isoPath.isEmpty {
                let def = SandboxPaths.defaultISO
                if FileManager.default.fileExists(atPath: def.path) { isoPath = def.path }
            }
            existing = builder.currentBaseline()
            loadEditions()
        }
        .onChange(of: builder.phase) { _, newPhase in
            if newPhase == .completed { existing = builder.currentBaseline() }
        }
    }

    // MARK: - 공통 헤더

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("build.header.title"))
                    .font(.title).fontWeight(.semibold)
                Spacer()
                if canReturnToSandbox && !builder.isRunning {
                    Button(L("build.returnToSandbox")) { admin.leaveRebuildMode() }
                }
            }
            Text(L("build.header.desc"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 설정 모드

    /// 기존 베이스라인 요약 — 작은 캡슐 한 줄로(재구축 진입 시 현황 확인용).
    private func baselineCapsule(_ meta: BaselineMetadata) -> some View {
        HStack(spacing: 8) {
            Image(systemName: meta.status == .ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(meta.status == .ready ? .green : .orange)
            Text(L("build.baseline.current", meta.name, meta.status.label))
                .font(.callout).fontWeight(.medium)
            Spacer()
            Text("\(meta.diskSizeGB)GB · \(meta.locale)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .help(meta.diskPath)
    }

    /// ISO + 에디션을 한 카드로 묶은 설정 폼.
    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ISO 선택 행
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "opticaldisc")
                    .font(.title2).foregroundStyle(.secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isoPath.isEmpty ? L("build.iso.none") : (isoPath as NSString).lastPathComponent)
                        .fontWeight(.medium)
                    if isoPath.isEmpty {
                        Text(L("build.iso.title")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(isoPath).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    if !isoPath.isEmpty, !FileManager.default.fileExists(atPath: isoPath) {
                        Label(L("build.iso.missing"), systemImage: "xmark.octagon")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                Spacer()
                Button(L("build.iso.choose")) { selectISO() }
            }
            .padding(14)

            Divider().padding(.horizontal, 14)

            // 에디션 행
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "square.stack.3d.up")
                    .font(.title2).foregroundStyle(.secondary).frame(width: 28)
                if loadingEditions {
                    ProgressView().controlSize(.small)
                    Text(L("build.edition.loading")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                } else if editions.isEmpty {
                    Text(isoPath.isEmpty ? L("build.edition.selectISOFirst") : L("build.edition.failed"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    Picker(L("build.edition.picker"), selection: $imageEdition) {
                        ForEach(editions, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }
            .padding(14)

            Divider().padding(.horizontal, 14)

            // 기본 사양 안내
            Label(L("build.edition.defaults"), systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var failureBanner: some View {
        Label(builder.phase.label, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var buildButton: some View {
        Button {
            showLicenseChecklist = true   // 매 빌드마다 라이선스 확인
        } label: {
            Label(L("build.action.build"), systemImage: "hammer")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canBuild)
    }

    // MARK: - 설치 모드

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(builder.phase.label).font(.headline)
                Spacer()
                Button(role: .destructive) { builder.cancel() } label: {
                    Label(L("common.cancel"), systemImage: "stop.circle")
                }
                .controlSize(.regular)
            }
            ProgressView(value: builder.phase.fraction)
            if !builder.detail.isEmpty {
                Text(builder.detail).font(.caption).foregroundStyle(.secondary)
            }
            Text((isoPath as NSString).lastPathComponent + " · " + imageEdition)
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func consoleCard(_ console: VMConsole) -> some View {
        GroupBox(L("build.console.title")) {
            VMConsoleView(console: console)
                .padding(6)
        }
    }

    // MARK: - 액션

    private func loadEditions() {
        guard !isoPath.isEmpty, FileManager.default.fileExists(atPath: isoPath) else {
            editions = []
            return
        }
        loadingEditions = true
        let path = isoPath
        Task.detached {
            let result = (try? WinPEDeployMediaBuilder.listImageEditions(isoPath: path)) ?? []
            await MainActor.run {
                editions = result
                if result.contains("Windows 11 Pro") { imageEdition = "Windows 11 Pro" }
                else if let first = result.first { imageEdition = first }
                loadingEditions = false
            }
        }
    }

    private func selectISO() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let isoType = UTType(filenameExtension: "iso") {
            panel.allowedContentTypes = [isoType]
        }
        panel.message = L("build.iso.panel")
        panel.directoryURL = SandboxPaths.fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
        if panel.runModal() == .OK, let url = panel.url {
            isoPath = url.path
            loadEditions()
        }
    }
}
