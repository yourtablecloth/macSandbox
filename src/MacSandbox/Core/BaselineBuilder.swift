// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Copyright (C) 2026 Nam Jung Hyun (rkttu)
//
// This file is part of MacSandbox, which is dual-licensed:
//   (1) under the GNU Affero General Public License v3.0 or later (see LICENSE), or
//   (2) under a commercial license (see COMMERCIAL-LICENSE.md).
// You may use this file under the terms of either license.
//
// MacSandbox is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.

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
    @Published private(set) var isRunning = false
    /// 설치가 진행 중일 때의 인터랙티브 콘솔(화면 + 키보드/마우스 개입). 유휴 시 nil.
    @Published var console: VMConsole?
    /// 로그는 별도 스로틀링 스토어 — 빌더를 관찰하는 뷰가 로그 줄마다 재렌더되지 않게 분리.
    let logBuffer = LogBuffer()

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
        logBuffer.clear()
        defer { isRunning = false }

        // 백그라운드 단계(미디어 빌드/다운로드)가 메인 액터로 로그를 넘기는 공용 싱크.
        let logSink: @Sendable (String) -> Void = { [weak self] msg in
            Task { @MainActor in self?.appendLog(msg) }
        }

        do {
            try SandboxPaths.ensureBaseDirectories()

            // 0. 사전 점검 — 늦게(설치 수십 분 후) 터질 실패를 앞당겨 명확히 알린다.
            //    배포 중 qcow2 실사용이 10~20GB까지 커지고 부트디스크 1.3GB + virtio ISO 0.7GB가 추가된다.
            try checkFreeDiskSpace(minimumBytes: 24_000_000_000)
            guard FileManager.default.isReadableFile(atPath: config.isoPath) else {
                throw BuildError.installFailed("ISO is not readable: \(config.isoPath)")
            }

            // 1. 베이스라인 디렉토리 초기화 (단일 베이스라인 정책: 기존 교체)
            updatePhase(.preparingDisk, L("build.detail.cleanup"))
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

            // 2. qcow2 NVMe 타깃 디스크 생성 (qemu-img 프로세스 — 메인 스레드 밖에서)
            updatePhase(.preparingDisk, L("build.detail.disk", config.diskSizeGB))
            let diskService = disk
            try await Task.detached(priority: .userInitiated) {
                try diskService.createQcow2(at: diskPath, sizeGB: config.diskSizeGB)
            }.value
            appendLog("Disk created: \(diskPath)")

            // 3. UEFI 펌웨어 확인
            updatePhase(.preparingFirmware, L("build.detail.firmware"))
            guard let efiCode = SandboxPaths.edk2CodeFirmware(),
                  let varsTemplate = SandboxPaths.edk2VarsTemplate() else {
                throw QEMURuntime.RuntimeError.firmwareNotFound
            }

            // 4. WinPE DISM 배포 매체 생성 (GPT FAT32 부트디스크 — boot.wim 편집)
            //    hdiutil/wimlib/diskutil 동기 작업으로 수 분 걸린다 — 메인 스레드를 막으면
            //    런루프 정지(IMK mach port 오류·응답 없음)로 이어지므로 반드시 백그라운드에서.
            updatePhase(.generatingUnattend, L("build.detail.media"))
            let bootDisk = baselineDir.appendingPathComponent("wpe-boot.img").path
            let mediaInputs = WinPEDeployMediaBuilder.Inputs(
                isoPath: config.isoPath, imageEdition: config.imageEdition,
                pantherUnattendXML: unattend.generatePantherXML(config: config),
                bootDiskPath: bootDisk)
            try await Task.detached(priority: .userInitiated) {
                try WinPEDeployMediaBuilder.build(mediaInputs, onLog: logSink)
            }.value
            appendLog("Deployment media: \(bootDisk)")

            let serialLog = headless ? baselineDir.appendingPathComponent("uefi-serial.log").path : nil

            // 4.5 virtio-win 드라이버 ISO 확보 — 캐시 없으면 ~700MB 다운로드(역시 백그라운드).
            updatePhase(.generatingUnattend, L("build.detail.drivers"))
            let virtioISO = try await Task.detached(priority: .userInitiated) {
                try GuestDrivers.ensureVirtioWinISO(onLog: logSink)
            }.value

            // 5. Phase 1 — WinPE 배포 (프롬프트·키 입력 0, 완전 결정론적)
            updatePhase(.installing, L("build.detail.phase1"))
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
                throw BuildError.installFailed("Deploy phase exited abnormally (exit=\(deployExit)).")
            }
            let deployedSize = ((try? FileManager.default.attributesOfItem(atPath: diskPath))?[.size] as? Int64) ?? 0
            appendLog("Disk after deploy: \(deployedSize / 1_000_000)MB")
            guard deployedSize >= 3_000_000_000 else {
                throw BuildError.installFailed("Disk after deploy is only \(deployedSize / 1_000_000)MB — DISM apply may have failed.")
            }

            // 6. Phase 2 — 첫 부팅 구성 (specialize/oobe → 첫 로그온 후 shutdown)
            updatePhase(.installing, L("build.detail.phase2"))
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
                throw BuildError.installFailed("OOBE phase exited abnormally (exit=\(oobeExit)).")
            }

            // 7. 마무리
            updatePhase(.finalizing, L("build.detail.finalize"))
            try? FileManager.default.removeItem(atPath: bootDisk)
            try? FileManager.default.removeItem(atPath: efiVarsDeploy)
            meta.status = .ready
            meta.createdAt = Date()
            try saveMetadata(meta)

            updatePhase(.completed, L("build.detail.done"))
            appendLog("✅ Baseline created (fully deterministic WinPE DISM deployment)")
        } catch {
            console?.stop()
            console = nil
            updatePhase(.failed(error.localizedDescription), error.localizedDescription)
            appendLog("❌ Failed: \(error.localizedDescription)")
            if var meta = currentBaseline() {
                meta.status = .error
                try? saveMetadata(meta)
            }
        }
    }

    func cancel() {
        runtime.forceStop()
        appendLog("Cancelled by user — VM stop requested")
    }

    // MARK: - Private

    /// 한 QEMU 단계를 실행한다. 인터랙티브 콘솔(화면 모니터링 + 사용자 개입)을 띄우고
    /// 프로세스 종료까지 대기한다. (배포/OOBE 모두 부팅 프롬프트가 없어 키 주입 불필요)
    private func runPhase(name: String, headless: Bool,
                          argsBuilder: (String) -> [String]) async throws -> Int32 {
        let qmpSocket = "/tmp/msbx-\(UUID().uuidString.prefix(8)).sock"
        let args = argsBuilder(qmpSocket)
        appendLog("[\(name)] QEMU started")
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
        appendLog("[\(name)] QEMU exited (exit=\(exit))")
        return exit
    }

    private func updatePhase(_ phase: BuildPhase, _ detail: String) {
        self.phase = phase
        self.detail = detail
    }

    /// 베이스라인 저장 볼륨의 여유 공간 점검(측정 실패 시 통과 — 설치 단계에서 자연 실패).
    private func checkFreeDiskSpace(minimumBytes: Int64) throws {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return }
        if free < minimumBytes {
            let fmt = ByteCountFormatter()
            throw BuildError.installFailed(L("error.lowDiskSpace",
                fmt.string(fromByteCount: free), fmt.string(fromByteCount: minimumBytes)))
        }
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
        logBuffer.append(trimmed)
        logHandler?(trimmed)
    }
}
