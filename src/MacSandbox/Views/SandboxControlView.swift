import SwiftUI

/// 샌드박스 실행/중지 제어 뷰
struct SandboxControlView: View {
    @ObservedObject var viewModel: SandboxViewModel

    var body: some View {
        VStack(spacing: 24) {
            // 상태 표시
            statusHeader

            Divider()

            // 빠른 정보
            quickInfo

            Spacer()

            // 컨트롤 버튼
            controlButtons
        }
        .padding(24)
        .navigationTitle("Windows Sandbox")
    }

    // MARK: - Subviews

    private var statusHeader: some View {
        HStack(spacing: 16) {
            Image(systemName: statusIcon)
                .font(.system(size: 48))
                .foregroundColor(statusColor)
                .symbolEffect(.pulse, isActive: viewModel.vmState.isTransitioning)

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.vmState.displayName)
                    .font(.title)
                    .fontWeight(.semibold)

                if !viewModel.isQEMUInstalled {
                    Label("QEMU가 설치되지 않았습니다", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
                if viewModel.configuration.baseImagePath.isEmpty {
                    Label("베이스 이미지를 선택해주세요", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
            }

            Spacer()
        }
    }

    private var quickInfo: some View {
        GroupBox("현재 설정") {
            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("이름").foregroundColor(.secondary)
                    Text(viewModel.configuration.name)
                }
                GridRow {
                    Text("CPU").foregroundColor(.secondary)
                    Text("\(viewModel.configuration.cpuCores)코어")
                }
                GridRow {
                    Text("메모리").foregroundColor(.secondary)
                    Text("\(viewModel.configuration.memoryMB) MB")
                }
                GridRow {
                    Text("네트워크").foregroundColor(.secondary)
                    Text(viewModel.configuration.networkMode.displayName)
                }
                GridRow {
                    Text("일회성").foregroundColor(.secondary)
                    Text(viewModel.configuration.disposable ? "예 (종료 시 초기화)" : "아니오")
                }
                GridRow {
                    Text("베이스 이미지").foregroundColor(.secondary)
                    Text(viewModel.configuration.baseImagePath.isEmpty
                         ? "(선택 안 됨)"
                         : URL(fileURLWithPath: viewModel.configuration.baseImagePath).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(8)
        }
    }

    private var controlButtons: some View {
        HStack(spacing: 16) {
            switch viewModel.vmState {
            case .stopped, .error:
                Button {
                    viewModel.startSandbox()
                } label: {
                    Label("샌드박스 시작", systemImage: "play.fill")
                        .frame(minWidth: 140)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!viewModel.isQEMUInstalled || viewModel.configuration.baseImagePath.isEmpty)

            case .running:
                Button {
                    viewModel.stopSandbox()
                } label: {
                    Label("정상 종료", systemImage: "stop.fill")
                        .frame(minWidth: 120)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button {
                    viewModel.forceStopSandbox()
                } label: {
                    Label("강제 종료", systemImage: "xmark.octagon.fill")
                        .frame(minWidth: 120)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .tint(.red)

            case .starting, .stopping:
                ProgressView()
                    .controlSize(.small)
                Text(viewModel.vmState.displayName)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.bottom, 16)
    }

    // MARK: - Helpers

    private var statusIcon: String {
        switch viewModel.vmState {
        case .stopped: return "desktopcomputer"
        case .starting: return "arrow.clockwise.circle"
        case .running: return "desktopcomputer.and.arrow.down"
        case .stopping: return "arrow.clockwise.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch viewModel.vmState {
        case .stopped: return .secondary
        case .starting: return .blue
        case .running: return .green
        case .stopping: return .orange
        case .error: return .red
        }
    }
}
