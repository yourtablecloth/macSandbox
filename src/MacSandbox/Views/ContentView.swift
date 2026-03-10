import SwiftUI

/// 메인 콘텐츠 뷰 - 사이드바 + 상세 구성
struct ContentView: View {
    @StateObject private var viewModel = SandboxViewModel()
    @State private var selectedTab: SidebarTab = .sandbox

    enum SidebarTab: String, CaseIterable {
        case sandbox = "샌드박스"
        case configuration = "설정"
        case images = "디스크 이미지"
        case log = "로그"

        var icon: String {
            switch self {
            case .sandbox: return "desktopcomputer"
            case .configuration: return "gearshape"
            case .images: return "externaldrive"
            case .log: return "doc.text"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch selectedTab {
            case .sandbox:
                SandboxControlView(viewModel: viewModel)
            case .configuration:
                SandboxConfigView(viewModel: viewModel)
            case .images:
                DiskImageManagerView(viewModel: viewModel)
            case .log:
                LogView(viewModel: viewModel)
            }
        }
        .frame(minWidth: 800, minHeight: 550)
        .alert("오류", isPresented: $viewModel.showError) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "알 수 없는 오류")
        }
    }
}
