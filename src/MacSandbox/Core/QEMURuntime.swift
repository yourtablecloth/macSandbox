import Foundation

/// QEMU(qemu-system-aarch64) 프로세스 생명주기 + 설치 모드 인자 빌드
///
/// 드라이버리스 설치 구성:
/// - 시스템 디스크: NVMe (Windows ARM 인박스 stornvme 드라이버)
/// - 설치/응답 미디어: USB 매스스토리지 (WinPE 인박스 usbstor 드라이버)
/// - 디스플레이: ramfb (UEFI GOP 프레임버퍼 → Windows 기본 디스플레이, 게스트 드라이버 불필요)
/// - 가속: HVF (Hypervisor.framework)
final class QEMURuntime {

    enum RuntimeError: LocalizedError {
        case qemuNotFound
        case firmwareNotFound

        var errorDescription: String? {
            switch self {
            case .qemuNotFound:
                return "qemu-system-aarch64를 찾을 수 없습니다. vendor/qemu 번들을 확인하세요."
            case .firmwareNotFound:
                return "UEFI 펌웨어(edk2-aarch64-code.fd / edk2-arm-vars.fd)를 찾을 수 없습니다."
            }
        }
    }

    private let lock = NSLock()
    private var process: Process?

    private func storeProcess(_ p: Process?) {
        lock.lock(); process = p; lock.unlock()
    }

    private func currentProcess() -> Process? {
        lock.lock(); defer { lock.unlock() }
        return process
    }

    // MARK: - WinPE DISM 배포 인자

    /// 공통 베이스 인자 (머신/가속/CPU/메모리/UEFI/디스플레이/네트워크/QMP)
    private func baseArguments(
        name: String, efiCodePath: String, efiVarsPath: String,
        cpuCores: Int, memoryMB: Int, qmpSocketPath: String, serialLogPath: String?
    ) -> [String] {
        var args: [String] = []
        args += ["-name", name]
        args += ["-machine", "virt,highmem=on,gic-version=3"]
        args += ["-accel", "hvf"]
        args += ["-cpu", "host"]
        args += ["-smp", "\(cpuCores)"]
        args += ["-m", "\(memoryMB)"]
        args += ["-drive", "if=pflash,format=raw,readonly=on,file=\(efiCodePath)"]
        args += ["-drive", "if=pflash,format=raw,file=\(efiVarsPath)"]
        args += ["-device", "ramfb"]
        args += ["-display", "none"]
        args += ["-vnc", "127.0.0.1:1"]
        if let serialLogPath { args += ["-serial", "file:\(serialLogPath)"] }
        args += ["-nic", "none"]
        args += ["-rtc", "base=localtime,clock=host"]
        args += ["-qmp", "unix:\(qmpSocketPath),server,nowait"]
        return args
    }

    /// Phase 1 (배포): GPT FAT32 WinPE 부트디스크 + Windows ISO(install.wim) + 빈 NVMe 타깃.
    /// WinPE가 프롬프트 없이 부팅해 deploy.cmd로 diskpart+dism+bcdboot 실행 후 shutdown.
    func buildDeployArguments(
        bootDiskPath: String, windowsISOPath: String, nvmePath: String,
        efiCodePath: String, efiVarsPath: String, virtioISOPath: String? = nil,
        cpuCores: Int, memoryMB: Int, qmpSocketPath: String, serialLogPath: String? = nil
    ) -> [String] {
        var args = baseArguments(name: "MacSandbox-Deploy", efiCodePath: efiCodePath, efiVarsPath: efiVarsPath,
                                 cpuCores: cpuCores, memoryMB: memoryMB, qmpSocketPath: qmpSocketPath, serialLogPath: serialLogPath)
        // 타깃 NVMe (diskpart의 disk 0)
        args += ["-drive", "if=none,id=sysdisk,format=qcow2,file=\(nvmePath)"]
        args += ["-device", "nvme,drive=sysdisk,serial=s0"]
        args += ["-device", "qemu-xhci,id=usb"]
        args += ["-device", "usb-kbd"]
        args += ["-device", "usb-tablet"]
        // GPT FAT32 WinPE 부트디스크 (펌웨어 자동 부팅)
        args += ["-drive", "if=none,id=wpe,format=raw,file=\(bootDiskPath)"]
        args += ["-device", "usb-storage,drive=wpe,bootindex=0"]
        // Windows ISO (install.wim 소스)
        args += ["-drive", "if=none,id=iso,media=cdrom,readonly=on,file=\(windowsISOPath)"]
        args += ["-device", "usb-storage,drive=iso"]
        // virtio-win 드라이버 ISO (deploy.cmd가 dism /Add-Driver로 오프라인 주입)
        if let virtioISOPath {
            args += ["-drive", "if=none,id=virtio,media=cdrom,readonly=on,file=\(virtioISOPath)"]
            args += ["-device", "usb-storage,drive=virtio"]
        }
        return args
    }

    /// Phase 2 (OOBE): 배포된 NVMe만으로 부팅 → specialize/oobe → 첫 로그온 후 shutdown.
    /// 펌웨어가 NVMe ESP의 \\EFI\\BOOT\\BOOTAA64.EFI(=bootmgfw, 배포 시 복사됨)를 자동 부팅.
    func buildOobeArguments(
        nvmePath: String, efiCodePath: String, efiVarsPath: String,
        cpuCores: Int, memoryMB: Int, qmpSocketPath: String, serialLogPath: String? = nil
    ) -> [String] {
        var args = baseArguments(name: "MacSandbox-OOBE", efiCodePath: efiCodePath, efiVarsPath: efiVarsPath,
                                 cpuCores: cpuCores, memoryMB: memoryMB, qmpSocketPath: qmpSocketPath, serialLogPath: serialLogPath)
        args += ["-drive", "if=none,id=sysdisk,format=qcow2,file=\(nvmePath)"]
        args += ["-device", "nvme,drive=sysdisk,serial=s0"]
        args += ["-device", "qemu-xhci,id=usb"]
        args += ["-device", "usb-kbd"]
        args += ["-device", "usb-tablet"]
        return args
    }

    /// 일회용 샌드박스 실행 인자. 베이스라인 COW 오버레이를 부팅하고 SandboxConfig를 장치로 번역.
    func buildSandboxArguments(
        overlayPath: String, efiCodePath: String, efiVarsPath: String,
        config: SandboxConfig, configDiskPath: String?, rdpHostPort: Int,
        qmpSocketPath: String, serialLogPath: String? = nil
    ) -> [String] {
        var args: [String] = []
        args += ["-name", "MacSandbox-Run"]
        args += ["-machine", "virt,highmem=on,gic-version=3"]
        args += ["-accel", "hvf"]
        args += ["-cpu", "host"]
        args += ["-smp", "\(max(1, config.cpuCores))"]
        args += ["-m", "\(max(1024, config.memoryMB))"]

        args += ["-drive", "if=pflash,format=raw,readonly=on,file=\(efiCodePath)"]
        args += ["-drive", "if=pflash,format=raw,file=\(efiVarsPath)"]

        // 시스템 디스크 — 베이스라인 위 COW 오버레이 (NVMe)
        args += ["-drive", "if=none,id=sysdisk,format=qcow2,file=\(overlayPath)"]
        args += ["-device", "nvme,drive=sysdisk,serial=s0"]

        // USB 컨트롤러 + 입력
        args += ["-device", "qemu-xhci,id=usb"]
        args += ["-device", "usb-kbd"]
        args += ["-device", "usb-tablet"]

        // 디스플레이 — vGPU(virtio-gpu, 드라이버 필요) 또는 ramfb(드라이버리스). VNC 프레임버퍼.
        args += ["-device", config.vGpuEnabled ? "virtio-gpu-pci" : "ramfb"]
        args += ["-display", "none"]
        args += ["-vnc", "127.0.0.1:1"]

        // 네트워킹 — user-mode NAT + 호스트 RDP 포트포워딩(127.0.0.1:rdpHostPort → 게스트 3389).
        // RDP 하이브리드: 콘솔(VNC)로 부팅을 보고, FreeRDP로 상호작용(폴더/클립보드/마이크/프린터).
        // networking 비활성 시 restrict=on으로 인터넷은 차단하되 RDP 포워딩은 유지한다.
        // 게스트 측 동작은 NetKVM(virtio-net) 드라이버 필요 — 베이스라인에 주입됨.
        var netdev = "user,id=net0,hostfwd=tcp:127.0.0.1:\(rdpHostPort)-:3389"
        if !config.networkingEnabled { netdev += ",restrict=on" }
        args += ["-netdev", netdev]
        args += ["-device", "virtio-net-pci,netdev=net0"]

        // 오디오(마이크) — coreaudio 백엔드 + HDA(게스트 드라이버 필요, best-effort)
        if config.audioInputEnabled {
            args += ["-audiodev", "coreaudio,id=snd0"]
            args += ["-device", "intel-hda"]
            args += ["-device", "hda-duplex,audiodev=snd0"]
        }

        // 설정 디스크(LogonCommand/매핑 정보 전달용 FAT) — 베이스라인 로그온 에이전트가 읽음
        if let configDiskPath {
            args += ["-drive", "if=none,id=cfg,format=raw,file=\(configDiskPath)"]
            args += ["-device", "usb-storage,drive=cfg,removable=on"]
        }

        if let serialLogPath { args += ["-serial", "file:\(serialLogPath)"] }
        args += ["-rtc", "base=localtime,clock=host"]
        args += ["-qmp", "unix:\(qmpSocketPath),server,nowait"]
        return args
    }

    // MARK: - 실행

    /// QEMU를 실행하고 프로세스가 종료될 때까지 대기.
    /// QEMU는 게스트 재부팅을 in-place로 처리하고 **게스트 전원 종료(shutdown)에서만 프로세스가 종료**되므로,
    /// 반환 = Windows 무인 설치가 완료되어 종료되었음을 의미한다.
    /// - Returns: QEMU 프로세스 exit code
    func runUntilExit(
        arguments: [String],
        qmpSocketPath: String,
        timeoutSeconds: TimeInterval,
        onOutput: @escaping (String) -> Void
    ) async throws -> Int32 {
        guard let qemu = SandboxPaths.qemuSystemBinary() else { throw RuntimeError.qemuNotFound }

        let proc = Process()
        proc.executableURL = qemu
        proc.arguments = arguments
        proc.environment = SandboxPaths.qemuEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty, let s = String(data: d, encoding: .utf8) { onOutput(s) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty, let s = String(data: d, encoding: .utf8) { onOutput("[qemu] \(s)") }
        }

        storeProcess(proc)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            let resumed = OneShotFlag()

            let timeout = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let p = self.currentProcess()
                if p?.isRunning ?? false {
                    onOutput("설치 타임아웃(\(Int(timeoutSeconds))초) 초과 — VM 강제 종료\n")
                    p?.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)

            proc.terminationHandler = { [weak self] finished in
                timeout.cancel()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                try? FileManager.default.removeItem(atPath: qmpSocketPath)
                self?.storeProcess(nil)
                if resumed.set() { cont.resume(returning: finished.terminationStatus) }
            }

            do {
                try proc.run()
                onOutput("QEMU 프로세스 시작됨 (PID \(proc.processIdentifier))\n")
            } catch {
                timeout.cancel()
                if resumed.set() { cont.resume(throwing: error) }
            }
        }
    }

    /// 강제 종료 (사용자 취소). QEMU에 SIGTERM → VM 즉시 종료.
    func forceStop() {
        currentProcess()?.terminate()
    }
}

/// 컨티뉴에이션 1회성 재개 보장용 스레드 세이프 플래그
final class OneShotFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    /// 최초 호출에만 true, 이후 false
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
