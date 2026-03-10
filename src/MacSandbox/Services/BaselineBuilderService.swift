import Foundation

/// 베이스라인 이미지 생성 및 관리 서비스
///
/// Setup Mode에서 Windows ISO로부터 단일 베이스라인 qcow2 이미지를 생성하고 관리합니다.
/// 시스템에는 항상 하나의 베이스라인만 존재합니다 (단일 베이스라인 정책).
@MainActor
final class BaselineBuilderService: ObservableObject {

    // MARK: - Published State

    @Published var setupProgress: SetupProgress = .idle
    @Published var progressDetail: String = ""
    @Published var isRunning: Bool = false
    @Published var currentBaseline: BaselineImage?

    // MARK: - Services

    private let diskImageService = DiskImageService()
    private let qemuService = QEMUService()
    private let unattendGenerator = UnattendGenerator()
    private let virtioDriverService = VirtioDriverService()

    // MARK: - Private

    /// 단일 베이스라인 고정 경로
    private let baselineDirectory: URL
    private let fm = FileManager.default
    /// 설치 타임아웃 (기본 60분)
    private let installTimeoutSeconds: TimeInterval = 3600

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.baselineDirectory = appSupport.appendingPathComponent("MacSandbox/baseline", isDirectory: true)
    }

    // MARK: - Baseline Creation

    /// 베이스라인 이미지 생성 (전체 플로우)
    ///
    /// 단일 베이스라인 정책: 기존 베이스라인이 있으면 삭제 후 새로 생성합니다.
    /// - Parameters:
    ///   - isoPath: Windows ISO/ESD 파일 경로
    ///   - diskSizeGB: 디스크 크기 (GB)
    ///   - cpuCores: 설치 시 CPU 코어 수
    ///   - memoryMB: 설치 시 메모리 크기 (MB)
    ///   - locale: Windows 로케일
    ///   - architecture: 게스트 아키텍처
    ///   - onOutput: QEMU 로그 출력 콜백
    func createBaseline(
        isoPath: String,
        diskSizeGB: Int = 64,
        cpuCores: Int = 4,
        memoryMB: Int = 8192,
        locale: String = "ko-KR",
        architecture: SandboxConfiguration.GuestArchitecture = .aarch64,
        onOutput: @escaping (String) -> Void
    ) async throws {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        do {
            // Step 1 — 디렉토리 준비 (고정 경로, 기존 베이스라인 교체)
            updateProgress(.preparingDisk, detail: "베이스라인 디렉토리 준비 중...")
            if fm.fileExists(atPath: baselineDirectory.path) {
                try fm.removeItem(at: baselineDirectory)
                onOutput("기존 베이스라인 삭제됨")
            }
            try fm.createDirectory(at: baselineDirectory, withIntermediateDirectories: true)

            let diskPath = baselineDirectory.appendingPathComponent("baseline.qcow2").path
            let efiVarsPath = baselineDirectory.appendingPathComponent("efi-vars.fd").path

            // 초기 메타데이터 (creating 상태)
            var baseline = BaselineImage(
                name: "Windows 11 \(architecture == .aarch64 ? "ARM64" : "x86_64")",
                diskPath: diskPath,
                efiVarsPath: efiVarsPath,
                windowsVersion: "Windows 11 \(architecture == .aarch64 ? "ARM64" : "x86_64")",
                diskSizeGB: diskSizeGB,
                architecture: architecture,
                status: .creating
            )
            try saveMetadata(baseline, to: baselineDirectory)
            currentBaseline = baseline

            // Step 2 — 빈 qcow2 디스크 생성
            updateProgress(.preparingDisk, detail: "\(diskSizeGB)GB qcow2 디스크 생성 중...")
            try createBlankDisk(at: diskPath, sizeGB: diskSizeGB)
            onOutput("디스크 생성 완료: \(diskPath)")

            // Step 3 — UEFI 변수 파일 준비
            updateProgress(.preparingDisk, detail: "UEFI 변수 파일 준비 중...")
            try createEfiVarsFile(at: efiVarsPath)
            onOutput("EFI 변수 파일 준비 완료")

            // Step 4 — Unattend 미디어 생성
            updateProgress(.generatingUnattend, detail: "autounattend.xml 생성 및 ISO 패키징...")
            let unattendISOPath = baselineDirectory.appendingPathComponent("autounattend.iso").path
            let unattendParams = UnattendGenerator.Parameters(
                locale: locale,
                architecture: architecture
            )
            let createdISOPath = try unattendGenerator.generateISO(
                parameters: unattendParams,
                outputPath: unattendISOPath
            )
            onOutput("Unattend ISO 생성 완료: \(createdISOPath)")

            // Step 5 — Virtio 드라이버 확인
            updateProgress(.preparingDrivers, detail: "드라이버 전략 확인 중...")
            let diskStrategy = virtioDriverService.recommendedDiskDevice(for: architecture)
            let virtioISOPath: String?
            if architecture == .x86_64, virtioDriverService.isVirtioWinAvailable {
                virtioISOPath = virtioDriverService.virtioWinISOPath
            } else {
                virtioISOPath = nil
            }
            onOutput("디스크 디바이스 전략: \(diskStrategy == .nvme ? "NVMe" : "virtio-blk")")

            // Step 6 — QEMU VM 시작 (설치 모드)
            updateProgress(.installingWindows, detail: "QEMU VM 시작 (Windows 설치)...")
            let setupArgs = qemuService.buildSetupModeArguments(
                architecture: architecture,
                baselineDiskPath: diskPath,
                efiVarsPath: efiVarsPath,
                windowsISOPath: isoPath,
                unattendISOPath: createdISOPath,
                virtioISOPath: virtioISOPath,
                cpuCores: cpuCores,
                memoryMB: memoryMB,
                diskStrategy: diskStrategy
            )

            // Step 7 — 설치 완료 대기
            updateProgress(.waitingForCompletion, detail: "Windows 설치 진행 중 (최대 60분)...")
            let exitCode = try await qemuService.runSetupVM(
                architecture: architecture,
                arguments: setupArgs,
                timeoutSeconds: installTimeoutSeconds,
                onOutput: onOutput
            )

            // 설치 결과 확인
            if exitCode != 0 {
                throw BaselineBuilderError.installationFailed("QEMU 비정상 종료 (exit code: \(exitCode))")
            }

            // 디스크 크기 검증 (설치가 실제로 수행되었는지)
            let diskAttrs = try fm.attributesOfItem(atPath: diskPath)
            let diskFileSize = (diskAttrs[.size] as? Int64) ?? 0
            if diskFileSize < 500_000_000 { // 500MB 미만이면 설치 미완료 가능성
                onOutput("경고: 디스크 이미지 크기가 예상보다 작습니다 (\(diskFileSize / 1_000_000)MB)")
            }

            // Step 8 — 베이스라인 마무리
            updateProgress(.finalizingBaseline, detail: "메타데이터 저장 및 임시 파일 정리...")
            baseline.status = .ready
            baseline.createdAt = Date()
            try saveMetadata(baseline, to: baselineDirectory)
            currentBaseline = baseline

            // 임시 파일 정리
            try? fm.removeItem(atPath: createdISOPath)

            updateProgress(.completed, detail: "베이스라인 생성 완료!")
            onOutput("베이스라인 생성 완료")

        } catch {
            setupProgress = .failed(error.localizedDescription)
            progressDetail = error.localizedDescription

            // 에러 시 메타데이터 업데이트
            if var baseline = currentBaseline {
                baseline.status = .error
                try? saveMetadata(baseline, to: baselineDirectory)
                currentBaseline = baseline
            }
            throw error
        }
    }

    /// 베이스라인 생성 취소 (VM 강제 종료)
    func cancelCreation() {
        qemuService.forceStopVM()
        setupProgress = .failed("사용자에 의해 취소됨")
        progressDetail = "베이스라인 생성이 취소되었습니다."
        isRunning = false
    }

    // MARK: - Baseline Management (단일 베이스라인)

    /// 단일 베이스라인 로드
    func loadBaseline() -> BaselineImage? {
        return loadBaseline(from: baselineDirectory)
    }

    /// 단일 베이스라인 삭제
    func deleteBaseline() throws {
        guard fm.fileExists(atPath: baselineDirectory.path) else {
            throw BaselineBuilderError.baselineNotFound
        }
        try fm.removeItem(at: baselineDirectory)
        currentBaseline = nil
    }

    /// 단일 베이스라인 유효성 검증
    func validateBaseline() -> Bool {
        guard let baseline = loadBaseline() else { return false }
        return fm.fileExists(atPath: baseline.diskPath)
            && fm.fileExists(atPath: baseline.efiVarsPath)
            && baseline.status == .ready
    }

    // MARK: - Private Helpers

    private func updateProgress(_ progress: SetupProgress, detail: String) {
        setupProgress = progress
        progressDetail = detail
    }

    private func createBlankDisk(at path: String, sizeGB: Int) throws {
        guard let qemuImg = findQEMUImg() else {
            throw DiskImageError.qemuImgNotFound
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qemuImg)
        process.arguments = ["create", "-f", "qcow2", path, "\(sizeGB)G"]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let msg = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw DiskImageError.imageCreationFailed(msg)
        }
    }

    private func createEfiVarsFile(at path: String) throws {
        // 64MB 빈 파일 생성 (AAVMF 표준 크기)
        let emptyData = Data(count: 64 * 1024 * 1024)
        try emptyData.write(to: URL(fileURLWithPath: path))
    }

    private func saveMetadata(_ baseline: BaselineImage, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(baseline)
        let metadataPath = directory.appendingPathComponent("metadata.json")
        try data.write(to: metadataPath, options: .atomic)
    }

    private func loadBaseline(from directory: URL) -> BaselineImage? {
        let metadataPath = directory.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataPath) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BaselineImage.self, from: data)
    }

    private func findQEMUImg() -> String? {
        // 번들 내장 탐색
        if let resourcePath = Bundle.main.resourcePath {
            let path = (resourcePath as NSString).appendingPathComponent("vendor/qemu/bin/qemu-img")
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let execURL = Bundle.main.executableURL
        var searchDir = execURL?.deletingLastPathComponent()
        for _ in 0..<6 {
            guard let dir = searchDir else { break }
            let path = dir.appendingPathComponent("vendor/qemu/bin/qemu-img").path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
            searchDir = dir.deletingLastPathComponent()
        }
        let candidates = ["/opt/homebrew/bin/qemu-img", "/usr/local/bin/qemu-img"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}

// MARK: - Errors

enum BaselineBuilderError: LocalizedError {
    case baselineNotFound
    case installationFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .baselineNotFound:
            return "베이스라인을 찾을 수 없습니다."
        case .installationFailed(let detail):
            return "Windows 설치 실패: \(detail)"
        case .timeout:
            return "설치 타임아웃이 초과되었습니다."
        }
    }
}
