import SwiftUI
import AppKit

/// 일회용 샌드박스 실행 화면 (.wsb 대응 설정 + 실행 + 콘솔)
struct SandboxView: View {
    @StateObject private var runner = SandboxRunner()
    @State private var config = SandboxConfig()
    @State private var hasBaseline = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if hasBaseline {
                    configSection
                    actionSection
                    if let console = runner.console { consoleSection(console) }
                    logSection
                } else {
                    noBaselineNotice
                }
            }
            .padding(22)
        }
        .frame(minWidth: 640, minHeight: 560)
        .onAppear { hasBaseline = runner.hasBaseline() }
        .onChange(of: runner.isRunning) { _, _ in hasBaseline = runner.hasBaseline() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("샌드박스 실행")
                .font(.title2).fontWeight(.semibold)
            Text("베이스라인 위에 일회용 COW 환경을 띄웁니다. 종료 시 변경사항은 폐기됩니다.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var noBaselineNotice: some View {
        GroupBox {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("준비된 베이스라인이 없습니다. ‘설치’ 탭에서 먼저 베이스라인을 구축하세요.")
                Spacer()
            }
            .padding(6)
        }
    }

    private var configSection: some View {
        GroupBox("샌드박스 설정 (.wsb)") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("메모리"); Spacer()
                    Picker("", selection: $config.memoryMB) {
                        ForEach([2048, 4096, 8192, 16384], id: \.self) { Text("\($0) MB").tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 280).labelsHidden()
                }
                HStack {
                    Text("CPU 코어"); Spacer()
                    Picker("", selection: $config.cpuCores) {
                        ForEach([2, 4, 6, 8], id: \.self) { Text("\($0)").tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 220).labelsHidden()
                }
                Toggle("네트워킹 (NAT)", isOn: $config.networkingEnabled)
                Toggle("vGPU (virtio-gpu 2D)", isOn: $config.vGpuEnabled)
                HStack {
                    Text("로그온 명령"); Spacer()
                    TextField("logon 시 실행할 명령", text: $config.logonCommand)
                        .frame(maxWidth: 320).textFieldStyle(.roundedBorder)
                }
                Divider()
                Text("RDP 리다이렉션 (FreeRDP 창으로 상호작용)")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("클립보드 공유", isOn: $config.clipboardEnabled)
                Toggle("마이크/오디오 공유", isOn: $config.audioInputEnabled)
                Toggle("프린터 리다이렉트", isOn: $config.printerEnabled)
                Toggle("웹캠 입력 공유", isOn: $config.videoInputEnabled)
                    .disabled(true)
                Text("웹캠은 현재 FreeRDP 빌드에서 미지원(RDPECAM 채널 없음)입니다.")
                    .font(.caption2).foregroundStyle(.secondary)
                Divider()
                mappedFoldersSection
            }
            .disabled(runner.isRunning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var mappedFoldersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("공유 폴더 (RDP drive)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { addMappedFolder() } label: { Label("추가", systemImage: "plus") }
                    .controlSize(.small)
            }
            if config.mappedFolders.isEmpty {
                Text("공유 폴더 없음 — 게스트에서 \\\\tsclient\\<이름> 으로 접근")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(config.mappedFolders) { folder in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                        Text((folder.hostPath as NSString).lastPathComponent)
                            .font(.caption).lineLimit(1).truncationMode(.middle)
                        Text(folder.hostPath)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { removeMappedFolder(folder) } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.borderless).controlSize(.small)
                    }
                }
            }
        }
    }

    private func addMappedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "공유"
        if panel.runModal() == .OK, let url = panel.url {
            config.mappedFolders.append(MappedFolder(hostPath: url.path))
        }
    }

    private func removeMappedFolder(_ folder: MappedFolder) {
        config.mappedFolders.removeAll { $0.id == folder.id }
    }

    private var actionSection: some View {
        HStack {
            Button {
                Task { await runner.start(config: config) }
            } label: {
                Label(runner.isRunning ? "실행 중..." : "샌드박스 시작", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(runner.isRunning)

            if runner.isRunning {
                Button(role: .destructive) { runner.stop() } label: {
                    Label("종료", systemImage: "stop.fill").frame(maxWidth: 120)
                }
                .controlSize(.large)
            }
            Spacer()
            Text(runner.status).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func consoleSection(_ console: VMConsole) -> some View {
        GroupBox("VM 콘솔") {
            VMConsoleView(console: console).padding(6)
        }
    }

    private var logSection: some View {
        GroupBox("로그") {
            ScrollView {
                Text(runner.log.isEmpty ? "(출력 없음)" : runner.log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
            .padding(6)
        }
    }
}
