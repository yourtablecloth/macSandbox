import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 미니멀 단일 창 — 1-round 베이스라인 자동 빌드
struct ContentView: View {
    @StateObject private var builder = BaselineBuilder()

    @State private var isoPath: String = ""
    @State private var imageEdition: String = "Windows 11 Pro"
    @State private var editions: [String] = []
    @State private var loadingEditions = false
    @State private var existing: BaselineMetadata?

    private var canBuild: Bool {
        !builder.isRunning && !isoPath.isEmpty && FileManager.default.fileExists(atPath: isoPath)
            && !imageEdition.isEmpty && !loadingEditions
    }

    var body: some View {
        TabView {
            buildTab
                .tabItem { Label("설치", systemImage: "square.and.arrow.down") }
            SandboxView()
                .tabItem { Label("샌드박스", systemImage: "play.rectangle") }
        }
        .frame(minWidth: 660, minHeight: 600)
    }

    private var buildTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let existing { baselineStatus(existing) }
                isoSection
                editionSection
                actionSection
                progressSection
                if let console = builder.console {
                    consoleSection(console)
                }
                logSection
            }
            .padding(22)
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

    // MARK: - 섹션

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MacSandbox — 베이스라인 자동 구축")
                .font(.title2).fontWeight(.semibold)
            Text("준비한 Windows 11 ARM64 ISO로 무인 설치를 1-round 실행해 단일 베이스라인을 만듭니다. (QEMU + HVF)")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func baselineStatus(_ meta: BaselineMetadata) -> some View {
        GroupBox {
            HStack(spacing: 10) {
                Image(systemName: meta.status == .ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(meta.status == .ready ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("현재 베이스라인: \(meta.name) — \(meta.status.rawValue)")
                        .fontWeight(.medium)
                    Text("\(meta.diskSizeGB)GB · \(meta.locale) · \(meta.diskPath)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var isoSection: some View {
        GroupBox("설치 미디어 (Windows 11 ARM64 ISO)") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(isoPath.isEmpty ? "선택 안 됨" : (isoPath as NSString).lastPathComponent)
                        .fontWeight(.medium)
                    Spacer()
                    Button("ISO 선택...") { selectISO() }.disabled(builder.isRunning)
                }
                if !isoPath.isEmpty {
                    Text(isoPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if !FileManager.default.fileExists(atPath: isoPath) {
                        Label("파일을 찾을 수 없습니다.", systemImage: "xmark.octagon")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var editionSection: some View {
        GroupBox("Windows 에디션 (install.wim)") {
            VStack(alignment: .leading, spacing: 8) {
                if loadingEditions {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("ISO에서 에디션 목록 읽는 중...").font(.caption).foregroundStyle(.secondary)
                    }
                } else if editions.isEmpty {
                    Text(isoPath.isEmpty ? "먼저 ISO를 선택하세요." : "에디션을 읽지 못했습니다 (wimlib 설치 필요).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("설치할 에디션", selection: $imageEdition) {
                        ForEach(editions, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 360)
                    .disabled(builder.isRunning)
                    Text("디스크 256GB · 8코어 · 16GB (표준 맥북 에어 사양) 기본값으로 빌드합니다.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

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

    private var actionSection: some View {
        HStack {
            Button {
                let config = InstallConfig(isoPath: isoPath, imageEdition: imageEdition)
                Task { await builder.build(config: config) }
            } label: {
                Label(builder.isRunning ? "설치 진행 중..." : "베이스라인 빌드", systemImage: "hammer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canBuild)

            if builder.isRunning {
                Button(role: .destructive) { builder.cancel() } label: {
                    Label("취소", systemImage: "stop.circle").frame(maxWidth: 120)
                }
                .controlSize(.large)
            }
        }
    }

    private func consoleSection(_ console: VMConsole) -> some View {
        GroupBox("VM 콘솔 (모니터링 · 개입)") {
            VMConsoleView(console: console)
                .padding(6)
        }
    }

    private var progressSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: builder.phase.fraction)
                HStack {
                    Text(builder.phase.label).fontWeight(.medium)
                    Spacer()
                    if builder.isRunning { ProgressView().controlSize(.small) }
                }
                if !builder.detail.isEmpty {
                    Text(builder.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var logSection: some View {
        GroupBox("로그") {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(builder.log.isEmpty ? "(아직 출력 없음)" : builder.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("logbottom")
                }
                .frame(height: 180)
                .onChange(of: builder.log) { _, _ in
                    proxy.scrollTo("logbottom", anchor: .bottom)
                }
            }
            .padding(6)
        }
    }

    // MARK: - 액션

    private func selectISO() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let isoType = UTType(filenameExtension: "iso") {
            panel.allowedContentTypes = [isoType]
        }
        panel.message = "Windows 11 ARM64 ISO 파일을 선택하세요"
        panel.directoryURL = SandboxPaths.fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
        if panel.runModal() == .OK, let url = panel.url {
            isoPath = url.path
            loadEditions()
        }
    }
}
