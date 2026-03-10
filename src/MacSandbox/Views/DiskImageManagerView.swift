import SwiftUI

/// 디스크 이미지 관리 뷰
struct DiskImageManagerView: View {
    @ObservedObject var viewModel: SandboxViewModel
    @State private var newImageName = ""
    @State private var newImageSizeGB = 40
    @State private var showCreateSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("디스크 이미지 관리")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    showCreateSheet = true
                } label: {
                    Label("새 이미지 생성", systemImage: "plus")
                }
                Button {
                    viewModel.refreshData()
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
            }

            if viewModel.availableBaseImages.isEmpty {
                ContentUnavailableView(
                    "베이스 이미지 없음",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("Windows가 설치된 qcow2 이미지를 생성하거나 추가하세요.\n이미지 디렉토리: ~/Library/Application Support/MacSandbox/images/")
                )
            } else {
                List {
                    ForEach(viewModel.availableBaseImages, id: \.self) { url in
                        HStack {
                            Image(systemName: "externaldrive.fill")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading) {
                                Text(url.lastPathComponent)
                                    .fontWeight(.medium)
                                Text(url.deletingLastPathComponent().path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("선택") {
                                viewModel.configuration.baseImagePath = url.path
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(24)
        .navigationTitle("디스크 이미지")
        .sheet(isPresented: $showCreateSheet) {
            createImageSheet
        }
    }

    private var createImageSheet: some View {
        VStack(spacing: 16) {
            Text("새 디스크 이미지 생성")
                .font(.headline)

            TextField("이미지 이름", text: $newImageName)
                .textFieldStyle(.roundedBorder)

            Stepper("크기: \(newImageSizeGB) GB", value: $newImageSizeGB, in: 10...500, step: 10)

            HStack {
                Button("취소") {
                    showCreateSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("생성") {
                    guard !newImageName.isEmpty else { return }
                    viewModel.createNewBaseImage(name: newImageName, sizeGB: newImageSizeGB)
                    showCreateSheet = false
                    newImageName = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newImageName.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 350)
    }
}
