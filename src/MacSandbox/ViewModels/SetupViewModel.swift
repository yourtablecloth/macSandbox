import Foundation
import SwiftUI

/// 베이스라인 생성 마법사를 위한 ViewModel
@MainActor
final class SetupViewModel: ObservableObject {

    // MARK: - Published State (바인딩 프로퍼티)

    @Published var baselineName: String = ""
    @Published var selectedISOPath: String?
    @Published var diskSizeGB: Int = 64
    @Published var cpuCores: Int = 4
    @Published var memoryMB: Int = 8192
    @Published var locale: String = "ko-KR"
    @Published var architecture: SandboxConfiguration.GuestArchitecture = .aarch64

    @Published var progress: SetupProgress = .idle
    @Published var progressDetail: String = ""
    @Published var logOutput: String = ""

    @Published var existingBaselines: [BaselineImage] = []

    @Published var errorMessage: String?
    @Published var showError: Bool = false

    // MARK: - Services

    private let baselineService = BaselineBuilderService()

    // MARK: - Init

    init() {
        refreshBaselines()
    }

    // MARK: - Computed

    var isSetupRunning: Bool {
        baselineService.isRunning
    }

    var canStartSetup: Bool {
        !baselineName.isEmpty
            && selectedISOPath != nil
            && !isSetupRunning
    }

    var progressPercent: Double {
        switch progress {
        case .idle: return 0
        case .downloadingISO: return 0.05
        case .preparingDisk: return 0.10
        case .preparingDrivers: return 0.15
        case .generatingUnattend: return 0.20
        case .installingWindows: return 0.30
        case .waitingForCompletion: return 0.50
        case .finalizingBaseline: return 0.90
        case .completed: return 1.0
        case .failed: return 0
        }
    }

    // MARK: - Actions

    /// 베이스라인 목록 새로고침
    func refreshBaselines() {
        existingBaselines = baselineService.listBaselines()
    }

    /// 베이스라인 생성 시작
    func startSetup() {
        guard canStartSetup, let isoPath = selectedISOPath else { return }

        logOutput = ""
        progress = .idle

        Task {
            // baselineService의 progress를 관찰
            let observation = Task { @MainActor [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    self.progress = self.baselineService.setupProgress
                    self.progressDetail = self.baselineService.progressDetail
                    try? await Task.sleep(nanoseconds: 200_000_000) // 0.2초
                }
            }

            do {
                try await baselineService.createBaseline(
                    name: baselineName,
                    isoPath: isoPath,
                    diskSizeGB: diskSizeGB,
                    cpuCores: cpuCores,
                    memoryMB: memoryMB,
                    locale: locale,
                    architecture: architecture,
                    onOutput: { [weak self] output in
                        Task { @MainActor in
                            self?.appendLog(output)
                        }
                    }
                )
                progress = .completed
                progressDetail = "베이스라인 '\(baselineName)' 생성 완료!"
                refreshBaselines()
            } catch {
                progress = .failed(error.localizedDescription)
                showError(error.localizedDescription)
            }

            observation.cancel()
        }
    }

    /// 베이스라인 생성 중단
    func cancelSetup() {
        baselineService.cancelCreation()
        progress = .failed("사용자에 의해 취소됨")
    }

    /// ISO 파일 선택 (NSOpenPanel)
    func selectISO() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "iso")!,
            .init(filenameExtension: "esd")!
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Windows 11 ARM64 ISO 또는 ESD 파일을 선택하세요"
        if panel.runModal() == .OK, let url = panel.url {
            selectedISOPath = url.path
        }
    }

    /// 베이스라인 삭제
    func deleteBaseline(id: UUID) {
        do {
            try baselineService.deleteBaseline(id: id)
            refreshBaselines()
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// 베이스라인 복제
    func duplicateBaseline(id: UUID, newName: String) {
        do {
            try baselineService.duplicateBaseline(id: id, newName: newName)
            refreshBaselines()
        } catch {
            showError(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func appendLog(_ message: String) {
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        logOutput += "[\(timestamp)] \(message)\n"
    }

    private func showError(_ message: String) {
        errorMessage = message
        showError = true
    }
}

// MARK: - DateFormatter

private extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
