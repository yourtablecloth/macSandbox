import Foundation
import Combine
import SwiftUI

/// 앱의 메인 ViewModel - 샌드박스 생명주기를 관리
@MainActor
final class SandboxViewModel: ObservableObject {
    // MARK: - Published State

    @Published var configuration = SandboxConfiguration()
    @Published var vmState: VMState = .stopped
    @Published var logOutput: String = ""
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var savedConfigurations: [(url: URL, config: SandboxConfiguration)] = []
    @Published var availableBaseImages: [URL] = []
    @Published var currentSandboxId: String?

    // MARK: - Services

    private let qemuService = QEMUService()
    private let diskImageService = DiskImageService()
    private lazy var configService = ConfigurationService(diskImageService: diskImageService)

    // MARK: - Init

    init() {
        refreshData()
    }

    // MARK: - Actions

    /// 데이터 새로고침
    func refreshData() {
        do {
            availableBaseImages = try diskImageService.listBaseImages()
            savedConfigurations = try configService.listSavedConfigurations()
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// 샌드박스 시작
    func startSandbox() {
        guard vmState == .stopped else { return }
        guard !configuration.baseImagePath.isEmpty else {
            showError("베이스 이미지를 선택해주세요.")
            return
        }

        vmState = .starting
        logOutput = ""
        let sandboxId = UUID().uuidString
        currentSandboxId = sandboxId

        Task {
            do {
                let overlayPath = try diskImageService.createOverlay(
                    baseImagePath: configuration.baseImagePath,
                    sandboxId: sandboxId
                )
                appendLog("오버레이 디스크 생성: \(overlayPath)")

                _ = try qemuService.startVM(
                    configuration: configuration,
                    overlayDiskPath: overlayPath,
                    onStateChange: { [weak self] state in
                        Task { @MainActor in
                            self?.vmState = state
                            if state == .stopped || state == .error {
                                self?.onVMStopped()
                            }
                        }
                    },
                    onOutput: { [weak self] output in
                        Task { @MainActor in
                            self?.appendLog(output)
                        }
                    }
                )
                appendLog("VM 시작됨 (PID: \(qemuService.isRunning ? "활성" : "비활성"))")
            } catch {
                vmState = .error
                showError(error.localizedDescription)
                appendLog("오류: \(error.localizedDescription)")
            }
        }
    }

    /// 샌드박스 정상 종료
    func stopSandbox() {
        guard vmState == .running else { return }
        vmState = .stopping
        appendLog("VM 종료 요청 (ACPI shutdown)...")
        qemuService.stopVM()
    }

    /// 강제 종료
    func forceStopSandbox() {
        appendLog("VM 강제 종료...")
        qemuService.forceStopVM()
        vmState = .stopped
        onVMStopped()
    }

    /// 새 빈 디스크 이미지 생성
    func createNewBaseImage(name: String, sizeGB: Int) {
        Task {
            do {
                let path = try diskImageService.createBlankImage(name: name, sizeGB: sizeGB)
                appendLog("새 디스크 이미지 생성: \(path)")
                refreshData()
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    /// 설정 저장
    func saveConfiguration() {
        do {
            let url = try configService.saveToConfigsDirectory(configuration)
            appendLog("설정 저장: \(url.lastPathComponent)")
            refreshData()
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// 설정 불러오기
    func loadConfiguration(from url: URL) {
        do {
            configuration = try configService.load(from: url)
            appendLog("설정 로드: \(url.lastPathComponent)")
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// .msb 파일 열기
    func openConfigurationFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "msb")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            loadConfiguration(from: url)
        }
    }

    /// 베이스 이미지 선택
    func selectBaseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "qcow2")!,
            .init(filenameExtension: "img")!,
            .init(filenameExtension: "iso")!
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            configuration.baseImagePath = url.path
        }
    }

    /// 공유 폴더 추가
    func addSharedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            let folder = SharedFolder(
                hostPath: url.path,
                guestMountTag: "share\(configuration.sharedFolders.count)",
                readOnly: false
            )
            configuration.sharedFolders.append(folder)
        }
    }

    /// 공유 폴더 제거
    func removeSharedFolder(at offsets: IndexSet) {
        configuration.sharedFolders.remove(atOffsets: offsets)
    }

    /// QEMU 설치 확인
    var isQEMUInstalled: Bool {
        qemuService.findQEMUExecutable() != nil
    }

    // MARK: - Private

    private func onVMStopped() {
        if configuration.disposable, let sandboxId = currentSandboxId {
            diskImageService.removeOverlay(sandboxId: sandboxId)
            appendLog("일회성 샌드박스: 오버레이 디스크 삭제됨")
        }
        currentSandboxId = nil
    }

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
