import Foundation

/// 일회용 샌드박스 실행 오케스트레이터.
///
/// 베이스라인 → COW 오버레이 + 신선한 UEFI 변수 → (설정 디스크) → QEMU 부팅 →
/// 사용자 사용 → 종료 시 disposable이면 오버레이/변수/설정디스크 폐기.
@MainActor
final class SandboxRunner: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var status: String = "대기"
    @Published private(set) var log: String = ""
    @Published var console: VMConsole?
    /// 현재 RDP 포워딩 포트(127.0.0.1:rdpPort → 게스트 3389). 0이면 미설정.
    @Published private(set) var rdpPort: Int = 0

    private let disk = DiskService()
    private let runtime = QEMURuntime()
    private let fm = FileManager.default
    private var rdp: RDPSession?

    func hasBaseline() -> Bool {
        guard let data = try? Data(contentsOf: SandboxPaths.baselineMetadataPath),
              let meta = try? JSONDecoder.iso8601.decode(BaselineMetadata.self, from: data) else { return false }
        return meta.status == .ready && fm.fileExists(atPath: meta.diskPath)
    }

    // MARK: - 실행

    func start(config: SandboxConfig) async {
        guard !isRunning else { return }
        guard let data = try? Data(contentsOf: SandboxPaths.baselineMetadataPath),
              let meta = try? JSONDecoder.iso8601.decode(BaselineMetadata.self, from: data),
              meta.status == .ready else {
            status = "사용 가능한 베이스라인이 없습니다."
            return
        }
        isRunning = true
        log = ""
        defer { isRunning = false }

        let id = String(UUID().uuidString.prefix(8))
        let overlayPath = SandboxPaths.overlaysDir.appendingPathComponent("\(id).qcow2").path
        let efiVarsPath = SandboxPaths.overlaysDir.appendingPathComponent("\(id)-efi.fd").path
        var configDiskPath: String?

        do {
            try SandboxPaths.ensureBaseDirectories()

            // 1. COW 오버레이 + 신선한 UEFI 변수
            status = "샌드박스 디스크 준비..."
            try disk.createOverlay(basePath: meta.diskPath, overlayPath: overlayPath)
            guard let efiCode = SandboxPaths.edk2CodeFirmware(),
                  let varsTemplate = SandboxPaths.edk2VarsTemplate() else {
                throw BuildError.installFailed("UEFI 펌웨어를 찾을 수 없습니다.")
            }
            try fm.copyItem(atPath: varsTemplate.path, toPath: efiVarsPath)
            appendLog("COW 오버레이: \(overlayPath)")

            // 2. (선택) 설정 디스크 — LogonCommand 전달
            if !config.logonCommand.isEmpty {
                let path = SandboxPaths.overlaysDir.appendingPathComponent("\(id)-cfg.img").path
                try makeConfigDisk(logonCommand: config.logonCommand, at: path)
                configDiskPath = path
                appendLog("설정 디스크(LogonCommand): \(path)")
            }

            // 3. QEMU 실행 (부팅 모니터링용 VNC 콘솔) + RDP 포트포워딩
            status = "샌드박스 부팅 중"
            let qmpSocket = "/tmp/msbx-run-\(id).sock"
            let port = RDPSession.reserveLocalPort()
            self.rdpPort = port
            let args = runtime.buildSandboxArguments(
                overlayPath: overlayPath, efiCodePath: efiCode.path, efiVarsPath: efiVarsPath,
                config: config, configDiskPath: configDiskPath, rdpHostPort: port, qmpSocketPath: qmpSocket)
            appendLog("RDP 포워딩: 127.0.0.1:\(port) → 게스트 3389")

            let console = VMConsole(socketPath: qmpSocket, capturesFrames: true)
            self.console = console
            console.start()

            // QEMU를 백그라운드로 실행하고, 동시에 게스트 RDP가 뜨면 FreeRDP 창을 띄운다.
            let qemuTask = Task { () -> Int32 in
                try await self.runtime.runUntilExit(
                    arguments: args, qmpSocketPath: qmpSocket, timeoutSeconds: 24 * 60 * 60
                ) { [weak self] out in
                    Task { @MainActor in self?.appendLog(out) }
                }
            }
            launchRDPWhenReady(config: config, port: port)

            // 샌드박스는 사용자가 FreeRDP 창을 닫거나 게스트가 종료될 때까지 실행
            let exit = (try? await qemuTask.value) ?? -1
            console.stop()
            self.console = nil
            rdp?.stop()
            rdp = nil
            self.rdpPort = 0
            appendLog("QEMU 종료 (exit=\(exit))")
            status = "종료됨"
        } catch {
            console?.stop()
            console = nil
            status = "실패: \(error.localizedDescription)"
            appendLog("❌ \(error.localizedDescription)")
        }

        // 4. 일회용 정리
        if config.disposable {
            try? fm.removeItem(atPath: overlayPath)
            try? fm.removeItem(atPath: efiVarsPath)
            if let configDiskPath { try? fm.removeItem(atPath: configDiskPath) }
            appendLog("일회용: 오버레이/변수/설정 디스크 삭제됨")
        }
    }

    /// 샌드박스 종료 (disposable이므로 강제 종료해도 무방)
    func stop() {
        rdp?.stop()
        runtime.forceStop()
        appendLog("종료 요청")
    }

    // MARK: - Private

    /// 게스트 RDP 서버가 뜰 때까지 FreeRDP를 재시도하며 띄운다.
    ///
    /// QEMU user-mode hostfwd는 게스트 RDP 준비 전에도 호스트측 connect를 즉시 수락하므로
    /// 포트 폴링으로는 준비를 판정할 수 없다. 대신 FreeRDP를 실제로 실행해 보고,
    /// 짧게 실패하면(=게스트 RDP 미준비) 잠시 후 재시도한다. 오래 살아있다 종료되면
    /// 사용자가 창을 닫은 것으로 보고 QEMU를 종료한다.
    private func launchRDPWhenReady(config: SandboxConfig, port: Int) {
        Task { @MainActor in
            // 부팅 그레이스 — 첫 시도 전 잠깐 대기
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            self.status = "게스트 RDP 연결 대기..."

            let session = RDPSession()
            self.rdp = session
            let maxAttempts = 40            // 약 5분 범위
            for attempt in 1...maxAttempts {
                guard self.isRunning, !session.isStopped else { return }
                let start = Date()
                let code: Int32
                do {
                    code = try await session.run(config: config, port: port) { [weak self] m in
                        Task { @MainActor in self?.appendLog(m) }
                    }
                } catch {
                    self.appendLog("⚠️ FreeRDP 실행 실패: \(error.localizedDescription)")
                    return
                }
                if session.isStopped { return }
                let lived = Date().timeIntervalSince(start)
                if code == 0 {
                    // 정상 종료 = 사용자가 RDP 창을 닫음 → 샌드박스 종료
                    self.appendLog("FreeRDP 세션 종료 — 샌드박스를 종료합니다")
                    self.runtime.forceStop()
                    return
                }
                if lived > 20 {
                    // 한참 살아있다가 끊김 → 세션 종료로 간주
                    self.appendLog("FreeRDP 연결 종료(코드 \(code)) — 샌드박스를 종료합니다")
                    self.runtime.forceStop()
                    return
                }
                // 짧게 실패 = 게스트 RDP 아직 미준비 → 재시도
                if attempt == 1 { self.status = "게스트 부팅 중 (RDP 준비 대기)..." }
                self.appendLog("RDP 연결 시도 \(attempt)/\(maxAttempts) 실패 — 게스트 준비 대기")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            self.appendLog("⚠️ RDP 연결을 확립하지 못했습니다 — VNC 콘솔로 진행하세요")
        }
    }

    /// LogonCommand를 담은 작은 FAT16 설정 디스크 생성 (베이스라인 로그온 에이전트가 읽음)
    private func makeConfigDisk(logonCommand: String, at path: String) throws {
        if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        guard fm.createFile(atPath: path, contents: nil) else {
            throw BuildError.installFailed("설정 디스크 생성 실패")
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: 8 * 1024 * 1024)
        try handle.close()

        let dev = try shellCapture("/usr/bin/hdiutil",
            ["attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", path])
            .split(separator: "\n").first.flatMap { $0.split(separator: " ").first.map(String.init) } ?? ""
        guard dev.hasPrefix("/dev/") else { throw BuildError.installFailed("설정 디스크 attach 실패") }
        defer { _ = try? shell("/usr/bin/hdiutil", ["detach", "-force", dev]) }

        try shell("/sbin/newfs_msdos", ["-F", "16", "-v", "MSBXCFG", dev])
        _ = try shellCapture("/usr/sbin/diskutil", ["mount", dev])
        let info = try shellCapture("/usr/sbin/diskutil", ["info", dev])
        guard let mp = info.split(separator: "\n").first(where: { $0.contains("Mount Point") })?
            .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces), !mp.isEmpty else {
            throw BuildError.installFailed("설정 디스크 마운트 실패")
        }
        let script = "@echo off\r\n\(logonCommand)\r\n"
        try script.write(toFile: (mp as NSString).appendingPathComponent("macsandbox-logon.cmd"),
                         atomically: true, encoding: .utf8)
        _ = try? shellCapture("/usr/sbin/diskutil", ["unmount", dev])
    }

    private func shell(_ path: String, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardError = Pipe(); p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
    }

    private func shellCapture(_ path: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func appendLog(_ m: String) {
        let t = m.trimmingCharacters(in: .newlines)
        guard !t.isEmpty else { return }
        log += t + "\n"
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}
