import Foundation

/// 베이스라인 1-round 빌드 오케스트레이터
///
/// 디스크 생성 → UEFI 변수 준비 → 무인 응답 ISO 생성 → QEMU 무인 설치 →
/// (게스트 종료 = 설치 완료) → 메타데이터 저장.
enum BuildError: LocalizedError {
    case installFailed(String)
    var errorDescription: String? {
        switch self {
        case .installFailed(let reason): return reason
        }
    }
}

@MainActor
final class BaselineBuilder: ObservableObject {

    @Published private(set) var phase: BuildPhase = .idle
    @Published private(set) var detail: String = ""
    @Published private(set) var log: String = ""
    @Published private(set) var isRunning = false
    /// 설치가 진행 중일 때의 인터랙티브 콘솔(화면 + 키보드/마우스 개입). 유휴 시 nil.
    @Published var console: VMConsole?

    /// 로그가 추가될 때마다 호출 (헤드리스/CLI에서 stdout 출력용)
    var logHandler: ((String) -> Void)?

    private let disk = DiskService()
    private let unattend = UnattendBuilder()
    private let runtime = QEMURuntime()

    /// 설치 타임아웃 (기본 60분)
    private let installTimeout: TimeInterval = 60 * 60

    // MARK: - 베이스라인 조회

    func currentBaseline() -> BaselineMetadata? {
        guard let data = try? Data(contentsOf: SandboxPaths.baselineMetadataPath) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BaselineMetadata.self, from: data)
    }

    // MARK: - 빌드

    func build(config: InstallConfig, headless: Bool = false) async {
        guard !isRunning else { return }
        isRunning = true
        log = ""
        defer { isRunning = false }

        do {
            try SandboxPaths.ensureBaseDirectories()

            // 1. 베이스라인 디렉토리 초기화 (단일 베이스라인 정책: 기존 교체)
            updatePhase(.preparingDisk, "기존 베이스라인 정리...")
            let baselineDir = SandboxPaths.baselineDir
            if FileManager.default.fileExists(atPath: baselineDir.path) {
                try FileManager.default.removeItem(at: baselineDir)
            }
            try FileManager.default.createDirectory(at: baselineDir, withIntermediateDirectories: true)

            let diskPath = SandboxPaths.baselineDiskPath.path
            let efiVarsPath = SandboxPaths.baselineEfiVarsPath.path

            var meta = BaselineMetadata(
                name: "Windows 11 ARM64",
                diskPath: diskPath,
                efiVarsPath: efiVarsPath,
                createdAt: Date(),
                diskSizeGB: config.diskSizeGB,
                locale: config.locale,
                status: .creating
            )
            try saveMetadata(meta)

            // 2. qcow2 NVMe 타깃 디스크 생성
            updatePhase(.preparingDisk, "\(config.diskSizeGB)GB qcow2 디스크 생성...")
            try disk.createQcow2(at: diskPath, sizeGB: config.diskSizeGB)
            appendLog("디스크 생성 완료: \(diskPath)")

            // 3. UEFI 펌웨어 확인
            updatePhase(.preparingFirmware, "UEFI 펌웨어 확인...")
            guard let efiCode = SandboxPaths.edk2CodeFirmware(),
                  let varsTemplate = SandboxPaths.edk2VarsTemplate() else {
                throw QEMURuntime.RuntimeError.firmwareNotFound
            }

            // 4. WinPE DISM 배포 매체 생성 (GPT FAT32 부트디스크 — boot.wim 편집)
            updatePhase(.generatingUnattend, "WinPE 배포 매체 생성 (boot.wim 편집 + GPT 디스크)...")
            let bootDisk = baselineDir.appendingPathComponent("wpe-boot.img").path
            let pantherXML = unattend.generatePantherXML(config: config)
            try WinPEDeployMediaBuilder.build(
                .init(isoPath: config.isoPath, imageEdition: config.imageEdition,
                      pantherUnattendXML: pantherXML, bootDiskPath: bootDisk),
                onLog: { [weak self] msg in Task { @MainActor in self?.appendLog(msg) } }
            )
            appendLog("배포 매체: \(bootDisk)")

            let serialLog = headless ? baselineDir.appendingPathComponent("uefi-serial.log").path : nil

            // 4.5 virtio-win 드라이버 ISO 확보 (네트워킹/vGPU 등 virtio 장치 동작 + RDP 전제)
            updatePhase(.generatingUnattend, "virtio-win 드라이버 준비...")
            let virtioISO = try GuestDrivers.ensureVirtioWinISO { [weak self] msg in
                Task { @MainActor in self?.appendLog(msg) }
            }

            // 5. Phase 1 — WinPE 배포 (프롬프트·키 입력 0, 완전 결정론적)
            updatePhase(.installing, "Phase 1/2: WinPE에서 Windows 배포 중 (DISM /Apply-Image)...")
            let efiVarsDeploy = baselineDir.appendingPathComponent("efi-vars-deploy.fd").path
            try FileManager.default.copyItem(atPath: varsTemplate.path, toPath: efiVarsDeploy)
            let deployExit = try await runPhase(name: "deploy", headless: headless) { sock in
                self.runtime.buildDeployArguments(
                    bootDiskPath: bootDisk, windowsISOPath: config.isoPath, nvmePath: diskPath,
                    efiCodePath: efiCode.path, efiVarsPath: efiVarsDeploy, virtioISOPath: virtioISO,
                    cpuCores: config.cpuCores, memoryMB: config.memoryMB,
                    qmpSocketPath: sock, serialLogPath: serialLog)
            }
            guard deployExit == 0 else {
                throw BuildError.installFailed("배포 단계가 비정상 종료했습니다 (exit=\(deployExit)).")
            }
            let deployedSize = ((try? FileManager.default.attributesOfItem(atPath: diskPath))?[.size] as? Int64) ?? 0
            appendLog("배포 후 디스크: \(deployedSize / 1_000_000)MB")
            guard deployedSize >= 3_000_000_000 else {
                throw BuildError.installFailed("배포 후 디스크가 \(deployedSize / 1_000_000)MB로 너무 작습니다 — DISM 적용 실패 가능.")
            }

            // 6. Phase 2 — 첫 부팅 구성 (specialize/oobe → 첫 로그온 후 shutdown)
            updatePhase(.installing, "Phase 2/2: Windows 첫 부팅 구성 중 (OOBE)...")
            let efiVarsOobe = SandboxPaths.baselineEfiVarsPath.path
            if FileManager.default.fileExists(atPath: efiVarsOobe) { try FileManager.default.removeItem(atPath: efiVarsOobe) }
            try FileManager.default.copyItem(atPath: varsTemplate.path, toPath: efiVarsOobe)
            let oobeExit = try await runPhase(name: "oobe", headless: headless) { sock in
                self.runtime.buildOobeArguments(
                    nvmePath: diskPath, efiCodePath: efiCode.path, efiVarsPath: efiVarsOobe,
                    cpuCores: config.cpuCores, memoryMB: config.memoryMB,
                    qmpSocketPath: sock, serialLogPath: serialLog)
            }
            guard oobeExit == 0 else {
                throw BuildError.installFailed("OOBE 단계가 비정상 종료했습니다 (exit=\(oobeExit)).")
            }

            // 7. 마무리
            updatePhase(.finalizing, "베이스라인 마무리...")
            try? FileManager.default.removeItem(atPath: bootDisk)
            try? FileManager.default.removeItem(atPath: efiVarsDeploy)
            meta.status = .ready
            meta.createdAt = Date()
            try saveMetadata(meta)

            updatePhase(.completed, "베이스라인 생성 완료!")
            appendLog("✅ 베이스라인 생성 완료 (완전 결정론적 WinPE DISM 배포)")
        } catch {
            console?.stop()
            console = nil
            updatePhase(.failed(error.localizedDescription), error.localizedDescription)
            appendLog("❌ 실패: \(error.localizedDescription)")
            if var meta = currentBaseline() {
                meta.status = .error
                try? saveMetadata(meta)
            }
        }
    }

    func cancel() {
        runtime.forceStop()
        appendLog("사용자 취소 — VM 종료 요청")
    }

    // MARK: - Private

    /// 한 QEMU 단계를 실행한다. 인터랙티브 콘솔(화면 모니터링 + 사용자 개입)을 띄우고
    /// 프로세스 종료까지 대기한다. (배포/OOBE 모두 부팅 프롬프트가 없어 키 주입 불필요)
    private func runPhase(name: String, headless: Bool,
                          argsBuilder: (String) -> [String]) async throws -> Int32 {
        let qmpSocket = "/tmp/msbx-\(UUID().uuidString.prefix(8)).sock"
        let args = argsBuilder(qmpSocket)
        appendLog("[\(name)] QEMU 시작")
        let console = VMConsole(socketPath: qmpSocket, capturesFrames: !headless)
        self.console = console
        console.start()
        let exit = try await runtime.runUntilExit(
            arguments: args, qmpSocketPath: qmpSocket, timeoutSeconds: installTimeout
        ) { [weak self] out in
            Task { @MainActor in self?.appendLog(out) }
        }
        console.stop()
        self.console = nil
        appendLog("[\(name)] QEMU 종료 (exit=\(exit))")
        return exit
    }

    private func updatePhase(_ phase: BuildPhase, _ detail: String) {
        self.phase = phase
        self.detail = detail
    }

    private func saveMetadata(_ meta: BaselineMetadata) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: SandboxPaths.baselineMetadataPath, options: .atomic)
    }

    private func appendLog(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }
        log += trimmed + "\n"
        logHandler?(trimmed)
    }
}
