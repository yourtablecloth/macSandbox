import SwiftUI

/// VM 설정 편집 뷰
struct SandboxConfigView: View {
    @ObservedObject var viewModel: SandboxViewModel
    @State private var newImageName = ""
    @State private var newImageSizeGB = 40
    @State private var showCreateImage = false

    var body: some View {
        Form {
            // 기본 설정
            Section("기본") {
                TextField("샌드박스 이름", text: $viewModel.configuration.name)

                HStack {
                    Text("베이스 이미지")
                    Spacer()
                    Text(viewModel.configuration.baseImagePath.isEmpty
                         ? "선택 안 됨"
                         : URL(fileURLWithPath: viewModel.configuration.baseImagePath).lastPathComponent)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Button("선택...") {
                        viewModel.selectBaseImage()
                    }
                }
            }

            // 하드웨어 설정
            Section("하드웨어") {
                Picker("CPU 코어", selection: $viewModel.configuration.cpuCores) {
                    ForEach([1, 2, 4, 6, 8], id: \.self) { count in
                        Text("\(count)코어").tag(count)
                    }
                }

                Picker("메모리", selection: $viewModel.configuration.memoryMB) {
                    ForEach([1024, 2048, 4096, 8192, 16384], id: \.self) { mb in
                        Text(memoryLabel(mb)).tag(mb)
                    }
                }

                Picker("해상도", selection: $viewModel.configuration.displayResolution) {
                    ForEach(SandboxConfiguration.DisplayResolution.allCases, id: \.self) { res in
                        Text(res.displayName).tag(res)
                    }
                }
            }

            // 네트워크 설정
            Section("네트워크") {
                Toggle("네트워크 활성화", isOn: $viewModel.configuration.networkingEnabled)

                if viewModel.configuration.networkingEnabled {
                    Picker("네트워크 모드", selection: $viewModel.configuration.networkMode) {
                        ForEach(SandboxConfiguration.NetworkMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }
            }

            // 가속기
            Section("가속기") {
                Toggle("Apple HVF (권장)", isOn: $viewModel.configuration.enableHVF)
                    .onChange(of: viewModel.configuration.enableHVF) { _, newValue in
                        if newValue { viewModel.configuration.enableKVM = false }
                    }
            }

            // 공유 폴더
            Section("공유 폴더") {
                ForEach(viewModel.configuration.sharedFolders) { folder in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(URL(fileURLWithPath: folder.hostPath).lastPathComponent)
                                .fontWeight(.medium)
                            Text(folder.hostPath)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if folder.readOnly {
                            Text("읽기 전용")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                }
                .onDelete { offsets in
                    viewModel.removeSharedFolder(at: offsets)
                }

                Button {
                    viewModel.addSharedFolder()
                } label: {
                    Label("공유 폴더 추가", systemImage: "folder.badge.plus")
                }
            }

            // 샌드박스 동작
            Section("동작") {
                Toggle("일회성 모드 (종료 시 변경사항 폐기)", isOn: $viewModel.configuration.disposable)
            }

            // 저장/불러오기
            Section {
                HStack {
                    Button("설정 저장") {
                        viewModel.saveConfiguration()
                    }
                    Button("설정 불러오기...") {
                        viewModel.openConfigurationFile()
                    }
                }

                if !viewModel.savedConfigurations.isEmpty {
                    Divider()
                    Text("저장된 설정").font(.caption).foregroundColor(.secondary)
                    ForEach(viewModel.savedConfigurations, id: \.url) { item in
                        Button {
                            viewModel.loadConfiguration(from: item.url)
                        } label: {
                            Label(item.config.name, systemImage: "doc")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("설정")
        .disabled(viewModel.vmState != .stopped)
    }

    private func memoryLabel(_ mb: Int) -> String {
        if mb >= 1024 {
            return "\(mb / 1024) GB"
        }
        return "\(mb) MB"
    }
}
